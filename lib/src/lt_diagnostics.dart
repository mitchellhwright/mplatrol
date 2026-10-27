import 'dart:convert';

import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/lt_dashboard_links.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_instrumentation_log.dart';
import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:mplatrol/src/test_lessons.dart';

/// Secret values shorter than this are not redacted: they match ordinary
/// words (a test key `k` would mangle every "k" in the log).
const _minRedactedSecretLength = 6;

/// [text] with the value of every secret-looking variable in [env] (password,
/// token, secret, access key, MFA) replaced by `<redacted>`.
String redactE2eSecrets(String text, Map<String, String> env) {
  final secretKey = RegExp('PASSWORD|TOKEN|SECRET|ACCESS_KEY|MFA', caseSensitive: false);
  var safe = text;
  for (final entry in env.entries) {
    if (secretKey.hasMatch(entry.key) && entry.value.length >= _minRedactedSecretLength) {
      safe = safe.replaceAll(entry.value, '<redacted>');
    }
  }
  return safe;
}

/// Network-egress summary for a LambdaTest session: how many of the device's
/// captured requests actually completed (status > 0).

/// How long, in seconds, an iOS session may last and still count as ending before any Dart test ran when its log
/// shows none (see [ltIosLogShowsNoDartTest]). Across rounds 1-11 every such session lasted 1-2 s, and the
/// quickest real test result (a skip before login) took 9 s.
const ltNoDartTestMaxSeconds = 5;

/// The reason a session that ended before any Dart test ran starts with: NOT RUN, LambdaTest infrastructure.
const ltNoDartTestReason = 'NOT RUN (infrastructure): the session ended before any Dart test ran';

/// Whether an iOS instrumentation [log] shows no sign that a Dart test started: no Patrol phase, no Dart
/// result, no runtime skip and no XCTest assertion error.
bool ltIosLogShowsNoDartTest(String log) =>
    !RegExp('PATROL_PHASE phase=|PATROL_RESULT |MPLATROL_TEST_SKIPPED|: error:').hasMatch(log);

class LtEgress {
  const LtEgress({required this.total, required this.completed});

  final int total;
  final int completed;

  /// True when the device issued requests but none completed — a dead data path.
  bool get noneCompleted => total > 0 && completed == 0;
}

/// Fetches a failed LambdaTest run's session + logs and prints a self-contained
/// diagnosis — status, device, video/log URLs, a network-egress summary, and a
/// best-guess reason — so a failed `mplatrol run lt-*` explains itself instead of
/// requiring a hand-query of the LambdaTest API. Best-effort: never throws.
class LtDiagnostics {
  /// Waits briefly for LambdaTest to publish instrumentation after a job ends.
  LtDiagnostics({this.logRetryDelay = const Duration(seconds: 2)});

  final Duration logRetryDelay;

  static const _sessionsUrl = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/sessions';

  static const _reportUrlBase = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/framework/builds';

  LtHttp get _http => getDep<LtHttp>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Reports why [buildId] (a [platform] run, e.g. 'iOS'/'Android') did not pass:
  /// the per-test breakdown, then for every session that did not pass its
  /// info, log/video links and a likely reason (the first session when none
  /// failed), so one failure never hides another in the same build.
  Future<void> report({required String buildId, required String platform, required Map<String, String> env}) async {
    final headers = _http.basicAuth(env['LT_USERNAME'] ?? '', env['LT_ACCESS_KEY'] ?? '');
    _logger.info('── LambdaTest $platform diagnosis (build $buildId) ──');

    final sessions = await _fetchSessions(buildId, headers);
    if (sessions == null) {
      _logger.err(
        'Could not read the LambdaTest session for build $buildId '
        '(see the LambdaTest dashboard).',
      );
      return;
    }

    final outcomes = await _printPerTestBreakdown(buildId, headers);
    final failed = [
      for (final session in sessions)
        if (_didNotPass(session)) session
    ];
    final diagnosed = failed.isEmpty ? [sessions.first] : failed;
    for (final (index, session) in diagnosed.indexed) {
      if (diagnosed.length > 1) {
        _logger.info('── session ${index + 1}/${diagnosed.length}: ${session['session_id'] ?? 'unknown id'} ──');
      }
      await _diagnoseSession(session, platform, outcomes, headers, env);
    }
  }

  Future<void> _diagnoseSession(Map<String, dynamic> session, String platform, List<LtTestOutcome> outcomes,
      Map<String, String> headers, Map<String, String> env) async {
    _logger.info(
      'status: ${session['status_ind']}  '
      'device: ${session['device']} ${session['version'] ?? ''}  '
      'duration: ${session['duration']}s',
    );
    final evidence = await _printInstrumentationFailure(session, headers, env);

    _logger.info('video:       ${_safeUrl(session['video_url'])}');
    _logger.info('device log:  ${_safeUrl(session['device_logs'])}');
    _logger.info('network log: ${_safeUrl(session['network_logs'])}');
    final sessionId = session['session_id'];
    if (sessionId is String && sessionId.isNotEmpty) {
      _logger.info('test page:   ${ltTestPageUrl(sessionId, buildId: session['build_id']?.toString())} '
          '(video, screenshots, device and network logs for this test)');
    }

    final egress = await _egress(session['network_logs'], headers);
    if (egress != null) {
      _logger.info('network: ${egress.completed}/${egress.total} requests completed');
    }
    final reason = _reason(session, egress, evidence, ios: platform == 'iOS');
    _logger.err('likely reason: $reason');
    _recordDiagnosis(session, evidence, reason, env);
    _learn('$evidence $reason');
  }

  /// Records this diagnosis as the CI verdict of the diagnosed session, unless
  /// the runner already decided one: a session that never received a test or
  /// skipped at runtime is NOT RUN, any other diagnosed session a FAIL.
  void _recordDiagnosis(Map<String, dynamic> session, String evidence, String reason, Map<String, String> env) {
    final sessionId = session['session_id'];
    if (sessionId is! String || sessionId.isEmpty || session['status_ind'] == 'passed') {
      return;
    }
    final summary = _instrumentationFailureSummary(evidence);
    final detail = redactE2eSecrets(summary ?? reason, env);
    final runtimeSkipDescribed = reason.startsWith('NOT RUN (skipped at runtime');
    final infrastructure = reason.startsWith(ltNoDartTestReason);
    final notRun = reason.startsWith('NOT RUN') && !runtimeSkipDescribed;
    final skipped = runtimeSkipDescribed || (!notRun && patrolSkipSummary(evidence).hasSkippedTests);
    getDep<ItRunResults>().verdict(
      notRun || skipped ? ItTestOutcome.notRun : ItTestOutcome.fail,
      sessionId: sessionId,
      reason: skipped ? '$itRuntimeSkipReason ($detail)' : (notRun ? reason : detail),
      evidence: '$evidence\n$reason',
      cause: infrastructure ? ItResultCategory.ltFailure : null,
      keepExisting: true,
    );
  }

  Future<List<Map<String, dynamic>>?> _fetchSessions(String buildId, Map<String, String> headers) async {
    try {
      final response = await _http.get('$_sessionsUrl?build_id=$buildId', headers: headers);
      final decoded = jsonDecode(response.body);
      final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
      if (data is! List || data.isEmpty) {
        return null;
      }
      final sessions = <Map<String, dynamic>>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) {
          return null;
        }
        sessions.add(item);
      }
      return sessions;
    } catch (_) {
      return null;
    }
  }

  static const _notPassedStatuses = {'failed', 'error', 'timeout', 'idle_timeout', 'queue_timeout'};

  bool _didNotPass(Map<String, dynamic> session) =>
      _notPassedStatuses.contains((session['status_ind'] ?? '').toString().toLowerCase());

  /// Prints the session's native phase, warning count and failure summary,
  /// and returns the instrumentation log as evidence for [_learn].
  Future<String> _printInstrumentationFailure(
      Map<String, dynamic> session, Map<String, String> headers, Map<String, String> env) async {
    final sessionId = session['session_id'];
    if (sessionId is! String || sessionId.isEmpty) {
      return '';
    }

    try {
      final body = await _fetchInstrumentation(sessionId, headers);
      if (body == null) {
        return '';
      }
      final phase = RegExp('PATROL_PHASE phase=([A-Za-z0-9_.-]+)').allMatches(body).lastOrNull;
      if (phase != null) {
        _logger.err('native phase: ${phase[1]} (session $sessionId)');
      }
      final warningPattern = RegExp(
        r'warning:|\[WARN\]|\bWARNING\b',
        caseSensitive: false,
      );
      final warningCount = const LineSplitter().convert(body).where(warningPattern.hasMatch).length;
      if (warningCount > 0) {
        _logger.err(
          'native warnings present: $warningCount line(s) for session $sessionId; '
          'inspect the authenticated instrumentation log',
        );
      }
      final summary = _instrumentationFailureSummary(body);
      if (summary != null) {
        final label = _runtimeSkipReason(body) == null ? 'failure' : 'not-run';
        _logger.err('$label: ${redactE2eSecrets(summary, env)}');
      } else {
        _logger.err(
          'native instrumentation: no failure marker found for '
          'session $sessionId (${body.length} bytes)',
        );
      }
      return body;
    } catch (error) {
      _logger.err(
        'native instrumentation fetch failed for session $sessionId '
        '(${error.runtimeType}); see the device log',
      );
      return '';
    }
  }

  /// LambdaTest can publish the instrumentation log a few seconds after the
  /// job ends, so retry transient misses before giving up. Returns null when
  /// the log is unavailable, or the (possibly empty) published body.
  Future<String?> _fetchInstrumentation(String sessionId, Map<String, String> headers) async {
    var publishedEmpty = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final response = await _http.get(
        '$_sessionsUrl/$sessionId/log/instrumentation',
        headers: headers,
        timeout: const Duration(seconds: 30),
      );
      if (response.statusCode == 200 && response.body.trim().isNotEmpty) {
        return plainLtInstrumentationLog(response.body);
      }
      if (![200, 404, 429, 500, 502, 503, 504].contains(response.statusCode)) {
        _logger.err(
          'native instrumentation: HTTP ${response.statusCode} '
          'for session $sessionId; failure details unavailable',
        );
        return null;
      }
      publishedEmpty = response.statusCode == 200;
      if (attempt < 2) {
        await Future<void>.delayed(logRetryDelay);
      }
    }
    if (publishedEmpty) {
      return '';
    }
    _logger.warn('Instrumentation log not published after three attempts. '
        'Check the LambdaTest session logs.');
    return null;
  }

  /// Records recognized failure lessons so repeated causes surface with
  /// their remedy and an observation count.
  void _learn(String evidence) => reportTestLessons(evidence,
      repo: getDep<ItLegDir>().stateRepo(getDep<FileSystem>().getAppDirectory().path), logger: _logger);

  Future<LtEgress?> _egress(Object? networkLogUrl, Map<String, String> headers) async {
    if (networkLogUrl is! String || networkLogUrl.isEmpty) {
      return null;
    }
    try {
      final response = await _http.get(networkLogUrl, headers: headers, timeout: const Duration(seconds: 30));
      final entries = jsonDecode(response.body);
      if (entries is! List) {
        return null;
      }
      var completed = 0;
      for (final entry in entries) {
        if (entry is! Map) {
          continue;
        }
        final responseField = entry['response'];
        final status = responseField is Map ? responseField['status'] : entry['status'];
        if (status is int && status > 0) {
          completed++;
        }
      }
      return LtEgress(total: entries.length, completed: completed);
    } catch (_) {
      return null;
    }
  }

  /// Fetches the build's XML report and prints the per-test pass/fail breakdown.
  ///
  /// LambdaTest's iOS dashboard collapses a Patrol XCUITest run under a single
  /// `testInvocations()` session (per-test naming/sharding is HyperExecute-only),
  /// but the report body still carries each `Test Case '-[Class method]'
  /// passed|failed (N seconds)` line — so this surfaces the real per-test
  /// results the dashboard hides. Best-effort: a missing/unparsable report is
  /// silently skipped so diagnosis still prints the session summary.
  Future<List<LtTestOutcome>> _printPerTestBreakdown(String buildId, Map<String, String> headers) async {
    final outcomes = parseLtTestOutcomes(await _fetchReport(buildId, headers));
    if (outcomes.isEmpty) {
      return outcomes;
    }
    final passed = outcomes.where((outcome) => outcome.passed).length;
    _logger.info('per-test results ($passed/${outcomes.length} passed):');
    for (final outcome in outcomes) {
      _logger.info(
        '  ${outcome.passed ? '✅' : '❌'} ${outcome.name}  '
        '(${outcome.seconds}s)',
      );
    }
    return outcomes;
  }

  Future<String?> _fetchReport(String buildId, Map<String, String> headers) async {
    try {
      final response = await _http.get(
        '$_reportUrlBase/$buildId/report?encoder=false',
        headers: headers,
        timeout: const Duration(seconds: 30),
      );
      return response.body.isEmpty ? null : response.body;
    } catch (_) {
      return null;
    }
  }

  String _reason(Map<String, dynamic> session, LtEgress? egress, String evidence, {required bool ios}) {
    final status = (session['status_ind'] ?? '').toString();
    if (evidence.contains('PATROL_SHARD_NOT_RUN') || evidence.contains('PATROL_SELECTION_COORDINATOR_FAILED')) {
      return 'NOT RUN (infrastructure): this shard never received a test — the '
          'device could not reach the mplatrol iOS shard coordinator through the '
          'LambdaTest tunnel. It is neither a pass nor a test failure; re-run.';
    }
    if (ios && _endedBeforeDartTest(session, evidence)) {
      return '$ltNoDartTestReason after ${session['duration']}s with no failure marker, so it is '
          'LambdaTest infrastructure, not a test failure; re-run.';
    }
    final skip = _runtimeSkipReason(evidence);
    if (skip != null) {
      return 'NOT RUN (skipped at runtime: $skip): the test skipped itself, so it '
          'neither passed nor failed. The device log has its MPLATROL_TEST_SKIPPED reason.';
    }
    if (egress != null && egress.noneCompleted) {
      return 'the device issued ${egress.total} requests and NONE completed — no '
          'network egress. The LT tunnel was not forwarding for the device run '
          '(dropped or not bound). Ensure the tunnel stays up through the run.';
    }
    if (status == 'queue_timeout') {
      return 'the requested device was not allocated in time (queue timeout) — '
          'it was unavailable/busy. Retry, or widen the device pool.';
    }
    if (status == 'idle_timeout' || status == 'timeout') {
      return 'the test launched but did not finish within idleTimeout — a slow '
          'login/MFA or an on-device hang. See the video + device log.';
    }
    if (status == 'failed' || status == 'error') {
      return 'the test ran and failed (assertion or thrown error). See the '
          'device log + video for the failing step.';
    }
    return 'see the video + device log above (status: $status).';
  }

  /// Whether an iOS [session] ended within [ltNoDartTestMaxSeconds] with an instrumentation log ([evidence])
  /// that shows no Dart test and no failure marker: r11 wayne PROJ-TC-7760 failed in 2 s that way.
  bool _endedBeforeDartTest(Map<String, dynamic> session, String evidence) {
    final duration = num.tryParse('${session['duration']}');
    return duration != null &&
        duration < ltNoDartTestMaxSeconds &&
        evidence.trim().isNotEmpty &&
        _instrumentationFailureSummary(evidence) == null &&
        ltIosLogShowsNoDartTest(evidence);
  }

  /// The reason a test skipped itself at runtime: the test's own
  /// `MPLATROL_TEST_SKIPPED <CODE> ...` line, else the iOS runner's, else
  /// Patrol's generic message; null when [evidence] shows no runtime skip.
  String? _runtimeSkipReason(String evidence) {
    final own = RegExp(r'MPLATROL_TEST_SKIPPED ([A-Z][A-Z0-9_]{2,}[^\n]*)').firstMatch(evidence);
    if (own != null) {
      return own[1]!.trim();
    }
    final runner =
        RegExp(r'MPLATROL_TEST_SKIPPED coordinator shard method=(\S+) NOT RUN: ([^\n]+)').firstMatch(evidence);
    if (runner != null) {
      return '${runner[2]!.trim()}, ${runner[1]}';
    }
    return evidence.contains(_patrolRuntimeSkip) ? _patrolRuntimeSkip : null;
  }

  static const _patrolRuntimeSkip = 'Dart test skipped at runtime';

  String _safeUrl(Object? value) {
    if (value is! String || value.isEmpty) {
      return '(none)';
    }
    return value.replaceAllMapped(
      RegExp(r'([?&](?:token|verify|access[_-]?key)=)[^&\s"]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
  }

  String? _instrumentationFailureSummary(String body) {
    final lines = const LineSplitter()
        .convert(body)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return null;
    }

    final nativeResult = lines.lastIndexWhere(
      (line) => line.contains('PATROL_RESULT ') && line.contains('passed=false'),
    );
    if (nativeResult >= 0) {
      final details = RegExp('details=(.*)').firstMatch(lines[nativeResult])?[1];
      final context = lines
          .skip(nativeResult + 1)
          .takeWhile(
            (line) =>
                !line.contains(' error: ') &&
                !line.contains('PATROL_') &&
                !line.startsWith('Test Case ') &&
                !line.startsWith('XCTestOutputBarrier'),
          )
          .take(8);
      return _safeUrl([details ?? lines[nativeResult], ...context].join('\n'));
    }
    final nativeError = _collectFailureStartingAt(
      lines,
      lines.lastIndexWhere((line) => line.contains(': error:')),
    );
    if (nativeError != null) {
      return _safeUrl(nativeError);
    }

    final patrolFailure = lines.indexWhere((line) => line.contains('was thrown running a test:'));
    if (patrolFailure >= 0 && patrolFailure + 1 < lines.length) {
      return _safeUrl(_collectFailureStartingAt(lines, patrolFailure + 1));
    }

    final badState = _collectFailureStartingAt(lines, lines.indexWhere((line) => line.contains('Bad state:')));
    if (badState != null) {
      return _safeUrl(badState);
    }

    final assertion = lines
        .where((line) => line.startsWith('INSTRUMENTATION_STATUS: stack='))
        .map((line) => line.substring('INSTRUMENTATION_STATUS: stack='.length))
        .firstOrNull;
    if (assertion != null && assertion.isNotEmpty) {
      return _safeUrl(assertion);
    }

    return null;
  }

  String? _collectFailureStartingAt(List<String> lines, int startIndex) {
    if (startIndex < 0) {
      return null;
    }

    final summary = <String>[];
    for (var index = startIndex; index < lines.length; index++) {
      final line = lines[index];
      if (index > startIndex && _isInstrumentationSummaryTerminator(line)) {
        break;
      }
      summary.add(line);
    }
    return summary.isEmpty ? null : summary.join(' ');
  }

  bool _isInstrumentationSummaryTerminator(String line) =>
      line.startsWith('When the exception was thrown') ||
      line.startsWith('INSTRUMENTATION_STATUS') ||
      line.startsWith('#') ||
      line.startsWith('at ');
}

/// One XCTest/Espresso case result parsed from a LambdaTest XML report.
class LtTestOutcome {
  const LtTestOutcome({required this.name, required this.passed, required this.seconds});

  /// The humanised test name (the `test_` prefix dropped, `_` → space).
  final String name;
  final bool passed;

  /// The case's wall-clock seconds, as reported (e.g. `21.363`).
  final String seconds;
}

final _ltTestCaseLine = RegExp(r"Test Case '-\[\w+ (\w+)\]' (passed|failed) \(([\d.]+) seconds\)");

/// Parses `Test Case '-[Class method]' passed|failed (N seconds)` lines out of a
/// LambdaTest XML [report] body into per-test outcomes, in run order. Returns an
/// empty list for a null/empty/unparsable report. The method name is humanised
/// (drop the `test_` prefix, `_` → space) so the output reads like the Dart test.
List<LtTestOutcome> parseLtTestOutcomes(String? report) {
  if (report == null || report.isEmpty) {
    return const [];
  }
  final outcomes = <LtTestOutcome>[];
  for (final match in _ltTestCaseLine.allMatches(report)) {
    final method = match.group(1)!;
    final name = method.startsWith('test_') ? method.substring(5) : method;
    outcomes.add(
      LtTestOutcome(name: name.replaceAll('_', ' '), passed: match.group(2) == 'passed', seconds: match.group(3)!),
    );
  }
  return outcomes;
}
