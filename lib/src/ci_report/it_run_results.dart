import 'dart:async';

import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_lessons.dart';

/// One Patrol test a runner selected, under the id that runner reports it by
/// (an Android native identity, an iOS shard method or a Dart test name).
class ItSelectedTest {
  const ItSelectedTest({
    required this.id,
    required this.file,
    required this.description,
    this.aliases = const [],
    this.selected = true,
  });

  final String id;

  /// The Patrol test file basename, e.g. `patrol_login_test`.
  final String file;
  final String description;

  /// Other ids the same runner may report this test by.
  final List<String> aliases;

  /// False for a test the run excluded from its selection.
  final bool selected;
}

/// The Patrol tests [target], [targetRegex] and [sdk] select in [repo], each
/// under its Dart test name `<file> <description>`: the tests a leg planned
/// to run, for a leg that failed before a runner selected its own.
List<ItSelectedTest> plannedPatrolTests(String repo, {String? target, String? targetRegex, String? sdk}) => [
      for (final file in discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex, sdk: sdk))
        for (final test in file.tests)
          ItSelectedTest(
              id: '${file.basename} ${test.description}', file: file.basename, description: test.description),
    ];

/// What a LambdaTest session showed: which test it ran and the evidence links.
class ItSessionDetails {
  const ItSessionDetails({
    this.testId,
    this.providerStatus,
    this.duration,
    this.device,
    this.os,
    this.videoUrl,
    this.deviceLogUrl,
    this.buildId,
  });

  final String? testId;

  /// LambdaTest's own status, e.g. `passed`, `failed` or `skipped`.
  final String? providerStatus;
  final Duration? duration;
  final String? device;
  final String? os;
  final String? videoUrl;
  final String? deviceLogUrl;

  /// The App Automation build the session belongs to.
  final String? buildId;
}

/// Collects the per-test verdicts the runners decide during `mplatrol run`,
/// so CI reports show every selected test once. Recording never changes a
/// verdict or an exit code.
///
/// The command runs each leg inside [withLeg] and each LambdaTest device job
/// inside [withDevice]; runners record into the leg and device of the zone
/// they run in, so concurrent legs and device jobs never mix. Records made
/// outside a leg are ignored.
class ItRunResults {
  static final _legKey = Object();
  static final _deviceKey = Object();
  static final _fiKey = Object();

  final _legs = <_LegRecord>[];
  final _fis = <(String, String), _TenantRecord>{};
  var _buildReuses = 0;

  /// The number of legs that reused an already built app instead of building.
  int get buildReuses => _buildReuses;

  /// Whether records made here are kept: only inside a leg of `mplatrol run`.
  /// Runners skip work done only for the report when this is false.
  bool get recording => _currentLeg != null;

  /// Runs [body] as one leg of the run; records inside it belong to [leg].
  /// [device] is the leg's device when it has exactly one, e.g. a local id.
  Future<T> withLeg<T>(ItRunLeg leg, Future<T> Function() body, {String? device}) {
    final record = _LegRecord(leg, device);
    _legs.add(record);
    return runZoned(body, zoneValues: {_legKey: record});
  }

  /// Runs [body] as the preparation and legs of [tenant] on [environment], so
  /// [blockTenant] and lessons observed before any leg starts name why its legs
  /// that never ran did not run.
  Future<T> withTenant<T>(String tenant, String environment, Future<T> Function() body) {
    final record = _fis.putIfAbsent((tenant, environment), _TenantRecord.new);
    return runZoned(body, zoneValues: {_fiKey: record});
  }

  /// Records that the current tenant's tests cannot run for [reason], counted as
  /// [category] (e.g. [ItResultCategory.credFailure] without a verified
  /// login) on every planned test of a leg that never starts.
  void blockTenant(ItResultCategory category, String reason) {
    final tenant = Zone.current[_fiKey] as _TenantRecord?;
    tenant?.cause = _Verdict(ItTestOutcome.notRun, reason, null, cause: category);
  }

  /// Records [lessons] the run recognized in output that belongs to no single
  /// test: they explain the tests of the current leg (else of the current
  /// tenant's legs that never started) that end without a result.
  void observeLessons(Iterable<TestLesson> lessons) {
    final leg = _currentLeg;
    if (leg == null) {
      (Zone.current[_fiKey] as _TenantRecord?)?.lessons.addAll(lessons);
      return;
    }
    leg.observe(lessons);
  }

  /// Runs [body] as the job of one LambdaTest [device] spec of the current leg.
  Future<T> withDevice<T>(String device, Future<T> Function() body) {
    _currentLeg?.multiDevice.add(device);
    return runZoned(body, zoneValues: {_deviceKey: device});
  }

  /// Ends [leg] with the variant's [exitCode]. A leg that failed before any
  /// runner selected its tests reports the [planned] tests as NOT RUN, and
  /// every test still without a verdict is NOT RUN with that exit code.
  void endLeg(ItRunLeg leg, {required int exitCode, required List<ItSelectedTest> Function() planned}) {
    final record = _legs.lastWhere((record) => identical(record.leg, leg));
    if (exitCode == 0) {
      return;
    }
    final signal = itRunStopSignal(exitCode);
    final reason = signal == null
        ? 'the ${leg.variant} run ended with exit $exitCode before this test reported'
        : itRunStoppedReason(signal);
    if (record.devices.values.every((device) => device.tests.isEmpty)) {
      final device = record.devices.putIfAbsent(record.device ?? '', () => _DeviceRecord(record.device ?? ''));
      planned().forEach(device.select);
    }
    for (final device in record.devices.values) {
      device.unfinished(ItTestOutcome.notRun, reason);
    }
  }

  /// [cause] for the planned tests of [leg] that never started, from its tenant's [blockTenant] or lessons.
  _Verdict? _fiCause(ItRunLeg leg, String reason) {
    final tenant = _fis[(leg.tenant, leg.environment)];
    if (tenant == null) {
      return null;
    }
    return tenant.cause ?? _Verdict(ItTestOutcome.notRun, reason, _firstLesson(tenant.lessons));
  }

  /// Records [leg] as ended with [exitCode] before it ran, e.g. when its tenant
  /// failed to prepare, unless the leg already ran: its [planned] tests are
  /// NOT RUN, so missing results never read as a pass.
  void endUnstarted(ItRunLeg leg, {required int exitCode, required List<ItSelectedTest> Function() planned}) {
    final ran = _legs.any((record) =>
        record.leg.tenant == leg.tenant &&
        record.leg.environment == leg.environment &&
        record.leg.variant == leg.variant);
    if (ran || exitCode == 0) {
      return;
    }
    final record = _LegRecord(leg, null);
    _legs.add(record);
    final cause = _fiCause(leg, 'the ${leg.variant} run ended with exit $exitCode before this test reported');
    if (cause != null) {
      final device = record.devices.putIfAbsent('', () => _DeviceRecord(''));
      planned().forEach(device.select);
      device._unfinished = cause;
    }
    endLeg(leg, exitCode: exitCode, planned: planned);
  }

  /// Registers the tests the current device job selected, each NOT RUN until
  /// a verdict arrives.
  void selectTests(Iterable<ItSelectedTest> tests) {
    final device = _currentDevice;
    if (device != null) {
      tests.forEach(device.select);
    }
  }

  /// Records a test that was not selected for [reason] (e.g. its SDK was not
  /// built), so the report shows it as NOT RUN.
  void excludeTest({required String file, required String description, required String reason}) {
    final id = '$file $description';
    _currentDevice
      ?..select(ItSelectedTest(id: id, file: file, description: description, selected: false))
      ..verdict(id, ItTestOutcome.notRun, 'not selected: $reason');
  }

  /// Records that the current leg ran HyperExecute job [jobId], so its reports link the job and build pages.
  void hyperexecuteJob(String jobId) => _currentLeg?.jobIds.add(jobId);

  /// Records what LambdaTest session [sessionId] ran and its evidence.
  void session(String sessionId, ItSessionDetails details) => _currentDevice?.session(sessionId, details);

  /// Records a verdict the runner decided for test [testId], or for the test
  /// session [sessionId] ran. [evidence] is classified into a TestLesson;
  /// [details] is the failure message and stack the reports carry in full;
  /// [cause] is the category the runner knows, e.g. [ItResultCategory.ltFailure]
  /// for a test LambdaTest never assigned. With [keepExisting], a verdict
  /// already recorded for the same test or session wins.
  void verdict(ItTestOutcome outcome,
      {String? testId,
      String? sessionId,
      String? reason,
      String? evidence,
      String? details,
      ItResultCategory? cause,
      bool keepExisting = false}) {
    final device = _currentDevice;
    if (device == null || testId == null && sessionId == null) {
      return;
    }
    if (keepExisting && device.hasVerdict(testId, sessionId)) {
      return;
    }
    device.verdict(testId, outcome, _withoutUrlQueries(reason),
        evidence: evidence, details: _withoutUrlQueries(details), sessionId: sessionId, cause: cause);
  }

  /// Whether session [sessionId] of the current device job has a verdict.
  bool sessionHasVerdict(String sessionId) => _currentDevice?.sessions[sessionId]?.verdict != null;

  /// Gives every test of the current device job that has no verdict yet
  /// [outcome] with [reason] and the known [cause], e.g. when the job stalled before they ran.
  void unfinished(ItTestOutcome outcome, String reason, {ItResultCategory? cause}) =>
      _currentDevice?.unfinished(outcome, reason, cause: cause);

  /// The current results of the current device job's tests, by the id each runner selected them under.
  Map<String, ItTestResult> currentDeviceResults() {
    final leg = _currentLeg;
    final device = _currentDevice;
    return leg == null || device == null ? const {} : leg.deviceResults(device);
  }

  /// The ids of the current device job's tests that a LambdaTest infrastructure failure
  /// ([itRetryableCategories]) kept from a result and that were not retried yet.
  List<String> retryableTests() => [
        for (final MapEntry(key: id, value: result) in currentDeviceResults().entries)
          if (itRetryableCategories.contains(result.category) && result.retriedAfter == null) id,
      ];

  /// Starts the one retry of the current device job's tests [ids]: their first attempt is forgotten, so the
  /// retry's verdict alone decides their result, and kept only as the note [ItTestResult.retriedAfter]. A
  /// retried test the retry never reaches ends NOT RUN, explained only by what the retry observed. Returns
  /// the note of each retried test, by id.
  Map<String, String> beginRetry(Iterable<String> ids) {
    final device = _currentDevice;
    if (device == null) {
      return const {};
    }
    final results = currentDeviceResults();
    final notes = {
      for (final id in ids)
        if (results[id] case final result?) id: _retryNote(result),
    };
    device.beginRetry(notes);
    return notes;
  }

  /// Records that the current leg reused an already built app.
  void buildReused() {
    if (_currentLeg != null) {
      _buildReuses++;
    }
  }

  /// The results of every leg so far, one per test and device.
  List<ItTestResult> get results => [for (final leg in _legs) ...leg.results()];

  /// The results recorded for [leg]; empty when it never ran.
  List<ItTestResult> resultsOf(ItRunLeg leg) => [
        for (final record in _legs)
          if (identical(record.leg, leg)) ...record.results(),
      ];

  _LegRecord? get _currentLeg => Zone.current[_legKey] as _LegRecord?;

  _DeviceRecord? get _currentDevice {
    final leg = _currentLeg;
    if (leg == null) {
      return null;
    }
    final device = Zone.current[_deviceKey] as String? ?? leg.device ?? '';
    return leg.devices.putIfAbsent(device, () => _DeviceRecord(device));
  }
}

/// The categories whose tests are retried once: LambdaTest infrastructure failures, which say nothing about
/// the app or the test. Credentials, environments, test data and builds are never retried; a repeated login
/// rejection can lock an account.
const itRetryableCategories = {ItResultCategory.ltTunnelErr, ItResultCategory.ltFailure};

/// What [result], a first attempt, says on the retried test's result.
String _retryNote(ItTestResult result) {
  final lesson = result.lesson == null ? '' : ' (lesson ${result.lesson!.name})';
  final reason = result.reason == null ? '' : ': ${result.reason}';
  final session = result.ltSessionId == null ? '' : ' [LambdaTest session ${result.ltSessionId}]';
  return 'retried after ${result.categoryName}$lesson; first attempt ${result.outcome.label}$reason$session';
}

class _LegRecord {
  _LegRecord(this.leg, this.device);

  final ItRunLeg leg;
  final String? device;
  final devices = <String, _DeviceRecord>{};
  final multiDevice = <String>{};
  final lessons = <TestLesson>{};
  final jobIds = <String>{};

  /// Adds [observed] to the leg's lessons and to those of every device job retrying its tests.
  void observe(Iterable<TestLesson> observed) {
    lessons.addAll(observed);
    for (final device in devices.values) {
      device.observeDuringRetry(observed);
    }
  }

  Iterable<ItTestResult> results() sync* {
    for (final device in devices.values) {
      yield* deviceResults(device).values;
    }
  }

  /// The results of [device]'s tests, by test id.
  Map<String, ItTestResult> deviceResults(_DeviceRecord device) => device.results(leg,
      deviceInName: multiDevice.length > 1, legLesson: _firstLesson(lessons), jobIds: jobIds.toList());
}

class _TenantRecord {
  final lessons = <TestLesson>{};
  _Verdict? cause;
}

class _Verdict {
  _Verdict(this.outcome, this.reason, this.lesson, {this.cause, this.details, this.detailMissing = false});

  final ItTestOutcome outcome;
  final String? reason;
  final TestLesson? lesson;
  final ItResultCategory? cause;
  final String? details;

  /// Whether this FAIL carries no per-test failure detail; see [ItTestResult.detailMissing].
  final bool detailMissing;

  /// This verdict explained by [legLesson] when it is a NOT RUN or NOT
  /// VERIFIED that nothing of its own explains. A test that ran and skipped
  /// itself is explained by its own skip, not by a failure elsewhere in the leg,
  /// and a test the run did not select by not being selected.
  _Verdict explainedBy(TestLesson? legLesson, {required bool selected}) => legLesson == null ||
          !selected ||
          outcome == ItTestOutcome.fail ||
          outcome.passed ||
          lesson != null ||
          cause != null ||
          (reason?.startsWith(itRuntimeSkipReason) ?? false)
      ? this
      : _Verdict(outcome, reason, legLesson);
}

/// The generic line Patrol's Android runner reports for any Dart failure; it names the test, not the cause.
final _genericDartFailure = RegExp(r'^.*Dart test failed(?::[^\n]*)?$', multiLine: true);

/// Signs of a real failure message once the generic Patrol line is removed.
final _failureDetail = RegExp(
    r'Expected:|Exception\b|TestFailure|EXCEPTION CAUGHT|Failed assertion|Process crashed|FATAL EXCEPTION|'
    'was thrown|Bad state:|Error:|STEP [a-z_]+:',
    caseSensitive: false);

/// Whether a FAIL with [reason], [details] and [evidence] says nothing about its cause: no reason, or only
/// Patrol's generic "Dart test failed" line, and no failure message in the evidence either.
bool _lacksFailureDetail(String? reason, String? details, String? evidence) {
  final specificReason = (reason ?? '').trim().isNotEmpty && !_genericDartFailure.hasMatch(reason!);
  if (specificReason || (details ?? '').trim().isNotEmpty) {
    return false;
  }
  return !_failureDetail.hasMatch((evidence ?? '').replaceAll(_genericDartFailure, ''));
}

class _SessionRecord {
  String? testId;
  ItSessionDetails details = const ItSessionDetails();
  _Verdict? verdict;
}

class _TestRecord {
  _TestRecord(this.test);

  final ItSelectedTest test;
  final sessionIds = <String>[];

  /// A verdict about the test itself; a session bound later replaces it.
  _Verdict? verdict;

  /// The first attempt of a retried test (see [ItRunResults.beginRetry]); null until it is retried.
  String? retriedAfter;
}

class _DeviceRecord {
  _DeviceRecord(this.device);

  final String device;
  final tests = <String, _TestRecord>{};
  final _aliases = <String, String>{};
  final sessions = <String, _SessionRecord>{};
  _Verdict? _unfinished;

  /// Whether this device job retries some of its tests; from then on [_retryLessons] and [_retryUnfinished]
  /// explain the retried tests instead of the leg's lessons and [_unfinished].
  var _retrying = false;
  final _retryLessons = <TestLesson>{};
  _Verdict? _retryUnfinished;

  /// Forgets the first attempt of the tests [notes] names and keeps its note on each.
  void beginRetry(Map<String, String> notes) {
    _retrying = true;
    for (final MapEntry(key: id, value: note) in notes.entries) {
      final test = tests[_resolve(id)]!
        ..retriedAfter = note
        ..verdict = null;
      for (final sessionId in test.sessionIds) {
        sessions[sessionId]!.testId = null;
      }
      test.sessionIds.clear();
    }
  }

  void observeDuringRetry(Iterable<TestLesson> lessons) {
    if (_retrying) {
      _retryLessons.addAll(lessons);
    }
  }

  void select(ItSelectedTest test) {
    tests.putIfAbsent(test.id, () => _TestRecord(test));
    for (final alias in test.aliases) {
      _aliases[alias] = test.id;
    }
  }

  String _resolve(String id) => _aliases[id] ?? id;

  bool hasVerdict(String? id, String? sessionId) =>
      sessionId == null ? tests[_resolve(id!)]?.verdict != null : sessions[sessionId]?.verdict != null;

  void session(String sessionId, ItSessionDetails details) {
    final record = sessions.putIfAbsent(sessionId, _SessionRecord.new);
    final testId = details.testId == null ? record.testId : _resolve(details.testId!);
    record
      ..details = _merge(record.details, details)
      ..testId = testId;
    final test = testId == null ? null : tests[testId];
    if (test != null && !test.sessionIds.contains(sessionId)) {
      test
        ..sessionIds.add(sessionId)
        ..verdict = null;
    }
  }

  /// Records a verdict for session [sessionId] (bound to [id] when given), or
  /// for test [id] itself. A session verdict waits for the session's test.
  void verdict(String? id, ItTestOutcome outcome, String? reason,
      {String? evidence, String? details, String? sessionId, ItResultCategory? cause}) {
    final text = '${evidence ?? ''}\n${details ?? ''}\n${reason ?? ''}';
    final lessons = recognizeTestLessons(text);
    final verdict = _Verdict(outcome, reason, _firstLesson(lessons),
        cause: cause,
        details: details,
        detailMissing: outcome == ItTestOutcome.fail && _lacksFailureDetail(reason, details, evidence));
    if (sessionId == null) {
      tests[_resolve(id!)]?.verdict = verdict;
      return;
    }
    session(sessionId, ItSessionDetails(testId: id));
    sessions[sessionId]!.verdict = verdict;
  }

  void unfinished(ItTestOutcome outcome, String reason, {ItResultCategory? cause}) {
    final verdict = _Verdict(outcome, reason, null, cause: cause);
    _unfinished ??= verdict;
    if (_retrying) {
      _retryUnfinished ??= verdict;
    }
  }

  /// Whether any verdict of this device job recognized [lesson].
  bool sawLesson(TestLesson lesson) =>
      tests.values.any((test) => test.verdict?.lesson == lesson) ||
      sessions.values.any((session) => session.verdict?.lesson == lesson);

  Map<String, ItTestResult> results(ItRunLeg leg,
          {required bool deviceInName, required TestLesson? legLesson, required List<String> jobIds}) =>
      {
        for (final MapEntry(key: id, value: test) in tests.entries)
          id: _result(leg, test,
              deviceInName: deviceInName,
              legLesson: test.retriedAfter == null ? legLesson : _firstLesson(_retryLessons),
              jobIds: jobIds),
      };

  ItTestResult _result(ItRunLeg leg, _TestRecord test,
      {required bool deviceInName, required TestLesson? legLesson, required List<String> jobIds}) {
    final runs = [for (final id in test.sessionIds) (id: id, session: sessions[id]!)];
    final passing = runs.where((run) => _sessionVerdict(run.session)?.outcome.passed ?? false);
    final chosen = passing.lastOrNull ?? runs.lastOrNull;
    final verdict = (test.verdict ?? (chosen == null ? null : _sessionVerdict(chosen.session)) ?? _noVerdict(test))
        .explainedBy(legLesson, selected: test.test.selected);
    final details = chosen?.session.details ?? const ItSessionDetails();
    return ItTestResult(
      leg: leg,
      file: test.test.file,
      description: test.test.description,
      outcome: verdict.outcome,
      reason: verdict.reason,
      details: verdict.details,
      lesson: verdict.lesson,
      cause: verdict.cause,
      device: details.device ?? (device.isEmpty ? null : device),
      os: details.os,
      duration: details.duration,
      ltSessionId: chosen?.id,
      ltBuildId: details.buildId,
      hyperexecuteJobIds: jobIds,
      videoUrl: details.videoUrl,
      deviceLogUrl: details.deviceLogUrl,
      flaky: verdict.outcome.passed && runs.any((run) => _failed(run.session)),
      deviceInName: deviceInName,
      selected: test.test.selected,
      detailMissing: verdict.detailMissing,
      retriedAfter: test.retriedAfter,
    );
  }

  _Verdict _noVerdict(_TestRecord test) => test.retriedAfter == null
      ? _unfinished ?? _Verdict(ItTestOutcome.notRun, 'no result: the run ended before this test reported', null)
      : _retryUnfinished ??
          _Verdict(ItTestOutcome.notRun, 'no result: the retry ended before this test reported', null);

  /// The runner's verdict for [run], else the one LambdaTest's own status
  /// implies: a provider pass mplatrol did not verify is NOT VERIFIED.
  _Verdict? _sessionVerdict(_SessionRecord run) =>
      run.verdict ??
      switch (run.details.providerStatus) {
        'passed' ||
        'completed' =>
          _Verdict(ItTestOutcome.notVerified, 'LambdaTest reported a pass that mplatrol did not verify', null),
        'skipped' => _Verdict(ItTestOutcome.notRun, itRuntimeSkipReason, null),
        null => null,
        final status => _Verdict(ItTestOutcome.fail, 'LambdaTest session $status', null, detailMissing: true),
      };

  bool _failed(_SessionRecord run) =>
      run.verdict?.outcome == ItTestOutcome.fail || run.verdict == null && run.details.providerStatus == 'failed';
}

/// [text] with the query string and fragment of every URL removed, so a
/// signed link never reaches a report.
String? _withoutUrlQueries(String? text) =>
    text?.replaceAllMapped(RegExp(r'(https?://[^\s?#"<>]+)[?#][^\s"<>]*'), (match) => match[1]!);

TestLesson? _firstLesson(Set<TestLesson> lessons) {
  for (final lesson in TestLesson.values) {
    if (lessons.contains(lesson)) {
      return lesson;
    }
  }
  return null;
}

ItSessionDetails _merge(ItSessionDetails base, ItSessionDetails update) => ItSessionDetails(
      testId: update.testId ?? base.testId,
      providerStatus: update.providerStatus ?? base.providerStatus,
      duration: update.duration ?? base.duration,
      device: update.device ?? base.device,
      os: update.os ?? base.os,
      videoUrl: update.videoUrl ?? base.videoUrl,
      deviceLogUrl: update.deviceLogUrl ?? base.deviceLogUrl,
      buildId: update.buildId ?? base.buildId,
    );
