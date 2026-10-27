import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/lt_dashboard_links.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/test_order.dart';

/// The one verdict a selected Patrol test gets in a CI report.
enum ItTestOutcome {
  pass('PASS'),
  fail('FAIL'),
  notRun('NOT RUN'),
  notVerified('NOT VERIFIED'),
  mocked('MOCKED');

  const ItTestOutcome(this.label);

  /// The word `mplatrol run` prints for this verdict.
  final String label;

  /// Whether the test ran and its verdict counts as a pass.
  bool get passed => this == pass || this == mocked;
}

/// What a result with [outcome] counts as. A pass is [ItResultCategory.pass] and a test the run did not
/// select [ItResultCategory.notSelected]. Otherwise the run's own [cause], else the [lesson]'s category,
/// names it; a device failure on a LambdaTest variant (`lt-`) is LambdaTest's, so
/// [ItResultCategory.ltFailure], and a LambdaTest failure on a local variant is the local device's, so
/// [ItResultCategory.deviceFailure]: a local run has no LambdaTest tunnel or device. A FAIL nothing explains
/// is [ItResultCategory.testFailure], or [ItResultCategory.noDetail] when [detailMissing] says no per-test
/// failure detail reached the run. A NOT RUN or NOT VERIFIED keeps its own category unless the cause is a
/// blocker: a lesson naming an app defect or a test failure never turns a test that did not run into a failure.
ItResultCategory itResultCategory(ItTestOutcome outcome,
    {required TestLesson? lesson,
    required ItResultCategory? cause,
    required bool selected,
    required String variant,
    bool detailMissing = false}) {
  if (outcome.passed) {
    return ItResultCategory.pass;
  }
  if (!selected) {
    return ItResultCategory.notSelected;
  }
  final explained = _onVariant(cause ?? lesson?.category, lambdaTest: variant.startsWith('lt-'));
  if (outcome == ItTestOutcome.fail) {
    return explained ?? (detailMissing ? ItResultCategory.noDetail : ItResultCategory.testFailure);
  }
  if (explained != null && explained.blocker) {
    return explained;
  }
  return outcome == ItTestOutcome.notVerified ? ItResultCategory.notVerified : ItResultCategory.notRun;
}

/// [category] as a run on LambdaTest ([lambdaTest]) or on a local device can have it: device failures are
/// LambdaTest's on LambdaTest, and LambdaTest failures the local device's locally.
ItResultCategory? _onVariant(ItResultCategory? category, {required bool lambdaTest}) => switch (category) {
      ItResultCategory.deviceFailure when lambdaTest => ItResultCategory.ltFailure,
      ItResultCategory.ltFailure || ItResultCategory.ltTunnelErr when !lambdaTest => ItResultCategory.deviceFailure,
      _ => category,
    };

/// How many of [results] fall in each category, by category name (`qa-env-failure`, not
/// `env-failure`), in [ItResultCategory] order; categories without a result are left out.
Map<String, int> itCategoryCounts(Iterable<ItTestResult> results) {
  final counts = <String, int>{};
  for (final category in ItResultCategory.values) {
    for (final result in results.where((result) => result.category == category)) {
      counts.update(result.categoryName, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return counts;
}

/// One distinct defect behind failed results: a recognised [TestLesson], or else the failing test itself.
typedef ItDefectCount = ({String defect, String category, int occurrences, List<String> tenants});

/// The failed results ([ItResultCategory.failed]) grouped by distinct defect, most occurrences first. Results
/// a lesson explains share one defect however many tests and tenants hit it; the rest are one defect per test.
List<ItDefectCount> itDefectCounts(Iterable<ItTestResult> results) {
  final groups = <String, List<ItTestResult>>{};
  for (final result in results.where((result) => result.category.failed)) {
    final lesson = result.lesson;
    final key = lesson == null ? 'test: ${result.name}' : lesson.name;
    groups.putIfAbsent(key, () => []).add(result);
  }
  final counts = [
    for (final MapEntry(:key, :value) in groups.entries)
      (
        defect: key,
        category: value.first.categoryName,
        occurrences: value.length,
        tenants: ({for (final result in value) result.leg.tenant}.toList()..sort()),
      ),
  ];
  counts.sort(
      (a, b) => b.occurrences != a.occurrences ? b.occurrences.compareTo(a.occurrences) : a.defect.compareTo(b.defect));
  return counts;
}

/// The reason a test skipped at runtime starts with. A runtime skip of a
/// selected test is NOT RUN and, as everywhere in mplatrol, never a pass.
const itRuntimeSkipReason = 'skipped at runtime; a skip is not a pass';

/// The detail Patrol reports for a runtime skip whose test gave no reason of its own.
const itGenericSkipDetail = 'Dart test skipped at runtime';

/// The details that say a test skipped at runtime without saying why: Patrol's fallback, the iOS runner's
/// and the Android instrumentation status of an assumption with no message.
const _genericSkipDetails = [itGenericSkipDetail, 'no skip reason', 'JUnit assumption/status -4'];

/// Whether a runtime-skip [detail] carries the test's own reason (e.g. `MOCK_TENANT_MISMATCH ...`) rather than
/// only a generic fallback. A skip with a reason is NOT RUN for a known cause and does not block a pass.
bool itSkipHasReason(String? detail) {
  final text = detail?.replaceFirst(itRuntimeSkipReason, '').replaceAll(RegExp(r'[\s(),.;:]+'), ' ').trim() ?? '';
  return text.isNotEmpty && !_genericSkipDetails.any(text.contains);
}

/// One leg of `mplatrol run`: a tenant, environment and variant run together.
class ItRunLeg {
  const ItRunLeg({
    required this.tenant,
    required this.environment,
    required this.variant,
    this.buildLabel,
    this.order,
  });

  final String tenant;
  final String environment;

  /// The variant id, e.g. `lt-ios`.
  final String variant;

  /// The E2E build label the run served, when credentials were verified.
  final String? buildLabel;

  /// The order the leg ran its tests in, with the seed that reproduces it.
  final TestOrder? order;

  /// The report suite name: stable run after run for one tenant, environment and
  /// variant, so CI history and flaky-test detection line up.
  String get suiteName => 'mplatrol $tenant $environment $variant';
}

/// The final result of one selected Patrol test on one device.
class ItTestResult {
  const ItTestResult({
    required this.leg,
    required this.file,
    required this.description,
    required this.outcome,
    this.device,
    this.os,
    this.duration,
    this.reason,
    this.details,
    this.ltSessionId,
    this.ltBuildId,
    this.hyperexecuteJobIds = const [],
    this.retriedAfter,
    this.videoUrl,
    this.deviceLogUrl,
    this.lesson,
    this.cause,
    this.flaky = false,
    this.deviceInName = false,
    this.selected = true,
    this.detailMissing = false,
  });

  final ItRunLeg leg;

  /// The Patrol test file basename, e.g. `patrol_login_test`.
  final String file;

  /// The `patrolTest` description.
  final String description;
  final ItTestOutcome outcome;
  final String? device;
  final String? os;
  final Duration? duration;

  /// Why the test failed, did not run or could not be verified.
  final String? reason;

  /// The failure message and stack the run printed for the test, when it kept them (local runs).
  final String? details;
  final String? ltSessionId;

  /// The App Automation build of [ltSessionId]'s session.
  final String? ltBuildId;

  /// The HyperExecute jobs the test's leg ran, in start order.
  final List<String> hyperexecuteJobIds;
  final String? videoUrl;
  final String? deviceLogUrl;

  /// The TestLesson that classified this test's failure evidence.
  final TestLesson? lesson;

  /// The category the run itself named for this result, e.g. [ItResultCategory.credFailure] when the
  /// tenant had no verified login; it wins over [lesson].
  final ItResultCategory? cause;

  /// Whether the test failed at least once before it passed.
  final bool flaky;

  /// Whether [name] carries [device], because the leg ran several devices.
  final bool deviceInName;

  /// The first attempt of a test retried once after a LambdaTest infrastructure failure, e.g.
  /// `retried after lt-tunnel-err (lesson lambdaTestTunnel); first attempt NOT RUN: ...`; null for a test
  /// that ran once. Every other field is the retry's.
  final String? retriedAfter;

  /// False for a test the run did not select (e.g. its SDK was not built),
  /// which is NOT RUN by design rather than a test the run lost.
  final bool selected;

  /// Whether a FAIL carries no per-test failure detail (no test log, or only the generic "Dart test failed"
  /// line), so its cause is unknown rather than a test failure.
  final bool detailMissing;

  /// Whether a selected test was NOT RUN because it skipped at runtime.
  bool get runtimeSkip => outcome == ItTestOutcome.notRun && (reason?.startsWith(itRuntimeSkipReason) ?? false);

  /// Whether the test skipped itself at runtime and said why (see [itSkipHasReason]): NOT RUN, but neither a
  /// failure nor a blocker of the leg's pass.
  bool get explainedSkip => runtimeSkip && category == ItResultCategory.notRun && itSkipHasReason(reason);

  /// What this result counts as in every report; see [itResultCategory].
  ItResultCategory get category => itResultCategory(outcome,
      lesson: lesson, cause: cause, selected: selected, variant: leg.variant, detailMissing: detailMissing);

  /// The name reports use for [category], e.g. `qa-env-failure` for an environment failure on QA.
  String get categoryName => category.nameFor(leg.environment);

  /// Whether the test ran to a pass or fail verdict.
  bool get executed =>
      outcome == ItTestOutcome.pass || outcome == ItTestOutcome.mocked || outcome == ItTestOutcome.fail;

  /// The test case or issue key in [description], normalized, e.g. `PROJ-TC-123` or `PROJ-456`.
  String? get ticketKey => ticketKeyIn(description);

  /// Every test case key (`PROJ-TC-n`) in [description], normalized, in order and without repeats.
  List<String> get caseKeys => caseKeysIn(description);

  /// The App Automation test page of [ltSessionId]: video, screenshots, device and network logs.
  String? get sessionUrl => ltSessionId == null ? null : ltTestPageUrl(ltSessionId!, buildId: ltBuildId);

  /// The HyperExecute job pages of the test's leg, space-separated; null when the leg ran no job.
  String? get hyperexecuteJobUrl => _joined(hyperexecuteJobIds.map(hyperexecuteJobPageUrl));

  /// The App Automation build pages of the test's leg, space-separated; null when the leg ran no job.
  String? get ltBuildUrl => _joined(hyperexecuteJobIds.map(ltBuildPageUrl));

  /// The test name CI tracks run after run: the ticket key first, then the
  /// description, plus the device when the leg ran several devices.
  String get name {
    final key = ticketKey;
    final base = key == null || description.startsWith(key) ? description : '$key $description';
    return deviceInName && device != null ? '$base [$device]' : base;
  }

  /// The metadata CI shows per test, in display order; absent values omitted.
  /// URL values carry no signed query parameters.
  List<({String name, String value, bool link})> get metadata => [
        _meta('Outcome', outcome.label),
        _meta('Category', categoryName),
        _meta('Reason', reason),
        _meta('Ticket', ticketKey),
        _meta('Test cases', caseKeys.join(' ')),
        _meta('Tenant', leg.tenant),
        _meta('Environment', leg.environment),
        _meta('Variant', leg.variant),
        _meta('Retried', retriedAfter),
        _meta('Device', device),
        _meta('OS', os),
        _meta('Build label', leg.buildLabel),
        _meta('Test file', 'patrol_test/$file.dart'),
        _meta('LambdaTest session id', ltSessionId),
        _meta('LambdaTest session', sessionUrl, link: true),
        _meta('Video', safeReportUrl(videoUrl), link: true),
        _meta('Device log', safeReportUrl(deviceLogUrl), link: true),
        _meta('TestLesson', lesson?.name),
        if (flaky) _meta('Flaky', 'passed after a failed attempt'),
      ].whereType<({String name, String value, bool link})>().toList();
}

String? _joined(Iterable<String> urls) => urls.isEmpty ? null : urls.join(' ');

({String name, String value, bool link})? _meta(String name, String? value, {bool link = false}) =>
    value == null || value.trim().isEmpty ? null : (name: name, value: value.trim(), link: link);

final _ticketKey = RegExp(r'\b([A-Z][A-Z0-9]{1,9})[-_](TC[-_])?(\d+)\b');

/// The first issue-tracker key in [text] (`PROJ-123`, or a test case key `PROJ-TC-123`), normalized, or null.
String? ticketKeyIn(String text) {
  final match = _ticketKey.firstMatch(text);
  if (match == null) {
    return null;
  }
  return match[2] == null ? '${match[1]}-${match[3]}' : '${match[1]}-TC-${match[3]}';
}

/// Every normalized test case key (`PROJ-TC-n`) in [text], in order and without repeats. An issue key that is
/// not a test case is left out.
List<String> caseKeysIn(String text) {
  final keys = <String>[];
  for (final match in _ticketKey.allMatches(text)) {
    final key = '${match[1]}-TC-${match[3]}';
    if (match[2] != null && !keys.contains(key)) {
      keys.add(key);
    }
  }
  return keys;
}

/// [url] without its query string or fragment, which on LambdaTest artefact
/// links carry the signature that grants access. Null for a blank value.
String? safeReportUrl(String? url) {
  final trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) {
    return null;
  }
  final end = trimmed.indexOf(RegExp('[?#]'));
  return end < 0 ? trimmed : trimmed.substring(0, end);
}

final _mockLeak = RegExp(r'MPLATROL_MOCK_LEAK\b[ \t]*([^\r\n]*)');

/// The verdict of a run that passed, from its device or instrumentation [log]:
/// MOCKED when the app ran against mocks (`MPLATROL_MOCKED`), NOT VERIFIED
/// when a mocked run reached the real backend (`MPLATROL_MOCK_LEAK`), else PASS.
/// The markers are the ones mocked Patrol runs print (see mocked_run.dart on
/// the mocking branch); a `MOCKED` test name alone proves nothing.
({ItTestOutcome outcome, String? reason}) passedRunOutcome(String log) {
  final leak = _mockLeak.firstMatch(log);
  if (leak != null) {
    final detail = leak[1]!.trim();
    return (
      outcome: ItTestOutcome.notVerified,
      reason: 'mocked run leaked to a real service${detail.isEmpty ? '' : ': $detail'}',
    );
  }
  if (RegExp(r'\bMPLATROL_MOCKED\b').hasMatch(log)) {
    return (outcome: ItTestOutcome.mocked, reason: null);
  }
  return (outcome: ItTestOutcome.pass, reason: null);
}
