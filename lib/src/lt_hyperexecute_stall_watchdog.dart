import 'dart:async';
import 'dart:convert';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_dashboard_links.dart';
import 'package:mplatrol/src/lt_http.dart';

/// Detects a HyperExecute job whose remaining task group(s) never get a
/// LambdaTest device session.
///
/// LambdaTest sometimes leaves one task group "running" without ever
/// allocating a device; the HyperExecute CLI then waits for the job-level
/// timeout (90 min). Each task runs one test and normally finishes within a
/// minute of starting (53 s was the longest of 29 observed), so a job where no
/// task has started or finished for [stallAfter] while a started task is still
/// unfinished is stalled infrastructure, not a slow test — unless a device
/// session of an unfinished task is still running, which is a long test. A
/// task with no start time is still waiting for a device (concurrency queue)
/// and never counts as a stall.
class HyperexecuteStallWatchdog {
  /// Creates a watchdog polling every [pollEvery] that reports a stall after
  /// [stallAfter] without a finished task; [clock] is injectable for tests.
  HyperexecuteStallWatchdog({
    this.stallAfter = const Duration(minutes: 5),
    this.runningSessionLimit = const Duration(minutes: 30),
    this.pollEvery = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long a running job may go without any task starting or finishing.
  final Duration stallAfter;

  /// How long a still-running device session keeps an idle job alive. A long
  /// test is progress; a session that runs past this is hung (umbrella lt-ios
  /// 2026-10-02 sat in one for five hours).
  final Duration runningSessionLimit;

  /// Delay between HyperExecute job API polls.
  final Duration pollEvery;

  final DateTime Function() _clock;

  /// Polls the job named in the HyperExecute CLI log at [cliLogPath] (only
  /// text after byte [cliLogOffset], i.e. this run) until [done] completes.
  ///
  /// Returns a diagnostic when the job stalled, or null when [done] completed
  /// first.
  Future<String?> watch({
    required String cliLogPath,
    required int cliLogOffset,
    required Map<String, String> headers,
    required Future<void> done,
  }) async {
    var finished = false;
    unawaited(done.whenComplete(() => finished = true));
    while (true) {
      await _sleepUnless(done);
      if (finished) {
        return null;
      }
      final jobId = hyperexecuteJobIdInLog(cliLogPath, cliLogOffset);
      if (jobId == null) {
        continue;
      }
      final stall = await _stallDiagnostic(jobId, headers);
      if (stall != null) {
        return stall;
      }
    }
  }

  Future<void> _sleepUnless(Future<void> done) {
    final wake = Completer<void>();
    final timer = Timer(pollEvery, wake.complete);
    return Future.any([wake.future, done]).whenComplete(timer.cancel);
  }

  Future<String?> _stallDiagnostic(String jobId, Map<String, String> headers) async {
    final response = await getDep<LtHttp>().get(
      'https://api.hyperexecute.cloud/v2.0/job/$jobId',
      headers: headers,
    );
    final data = response.statusCode == 200 ? _data(response.body) : null;
    if (data == null) {
      getDep<MplatrolLogger>().detail(
        '[hyperexecute-watchdog] job $jobId status poll returned HTTP '
        '${response.statusCode}; retrying in ${pollEvery.inSeconds}s.',
      );
      return null;
    }
    if (data['status'] != 'running') {
      return null;
    }
    final tasks = (data['tasks'] as List? ?? const []).whereType<Map>();
    final pending = tasks.where((task) => _time(task, 'endTime') == null).toList();
    final ends = tasks.map((task) => _time(task, 'endTime')).whereType<DateTime>().toList();
    if (pending.isEmpty || ends.isEmpty || pending.any((task) => _time(task, 'startTime') == null)) {
      return null;
    }
    final events = [...ends, ...tasks.map((task) => _time(task, 'startTime')).whereType<DateTime>()];
    final lastProgress = events.reduce((a, b) => a.isAfter(b) ? a : b);
    final idle = _clock().toUtc().difference(lastProgress);
    if (idle < stallAfter || (idle < runningSessionLimit && await _sessionStillRunning(jobId, headers, pending))) {
      return null;
    }
    final groups = [
      for (final task in pending) '#${task['groupNumber']} (${task['status']})',
    ].join(', ');
    return 'HyperExecute job $jobId task group(s) $groups never finished: no '
        'task started or finished for ${idle.inMinutes} min (limit ${stallAfter.inMinutes} '
        'min) — LambdaTest did not run a device session for them';
  }

  /// Whether a device session of one of the [pending] tasks is still running.
  ///
  /// A stalled task group never gets a device session, while a long test (a
  /// DepositSdk journey ran 414 s) has one that is running: that is progress. When
  /// the sessions cannot be read this returns false, so a real stall is still
  /// stopped.
  Future<bool> _sessionStillRunning(String jobId, Map<String, String> headers, List<Map> pending) async {
    final response = await getDep<LtHttp>().get(
      'https://api.hyperexecute.cloud/v2.0/job/$jobId/sessions?limit=100',
      headers: headers,
    );
    final sessions = response.statusCode == 200 ? _sessions(response.body) : null;
    if (sessions == null) {
      getDep<MplatrolLogger>().detail(
        '[hyperexecute-watchdog] job $jobId sessions poll returned HTTP '
        '${response.statusCode}; treating its idle task group(s) as stalled.',
      );
      return false;
    }
    final taskIds = {for (final task in pending) task['id']};
    final running = [
      for (final session in sessions)
        if (taskIds.contains(session['taskID']) && !_finishedSession(session)) session['sessionID'],
    ];
    if (running.isEmpty) {
      return false;
    }
    getDep<MplatrolLogger>().detail(
      '[hyperexecute-watchdog] job $jobId: no task started or finished within '
      '${stallAfter.inMinutes} min, but session(s) ${running.join(', ')} still running; '
      'not a stall.',
    );
    return true;
  }

  static const _finishedSessionStatuses = {
    'passed',
    'failed',
    'error',
    'skipped',
    'completed',
    'cancelled',
    'aborted',
    'stopped',
    'timeout',
    'idle_timeout',
    'queue_timeout',
    'lambda_error',
    'ignored',
  };

  bool _finishedSession(Map session) => _finishedSessionStatuses.contains('${session['status']}'.trim().toLowerCase());

  List<Map>? _sessions(String body) {
    try {
      final decoded = jsonDecode(body);
      final data = decoded is Map ? decoded['data'] : null;
      return data is List ? data.whereType<Map>().toList() : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic>? _data(String body) {
    try {
      final decoded = jsonDecode(body);
      final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
      return data is Map<String, dynamic> ? data : null;
    } on FormatException {
      return null;
    }
  }

  DateTime? _time(Map task, String field) {
    final value = task[field];
    return value is String && value.isNotEmpty ? DateTime.tryParse(value)?.toUtc() : null;
  }
}
