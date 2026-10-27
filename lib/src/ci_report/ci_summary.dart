import 'dart:convert';

import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/test_order.dart';

/// The run identity a [renderCiSummary] carries beyond the counts.
typedef CiSummaryContext = ({
  Duration duration,
  String? testResultsUrl,
  String mplatrolVersion,
  String appVersion,
});

/// The run summary JSON (`summary.json`): `Env`, `Total`, `Passed`, `Failed`, `Skipped`, `Blocked`,
/// `DurationSec`, `Result`, `TestResultsUrl`, `Platform`, plus `mplatrol_version`, `app_version`, `commit` (from
/// the build label), `order` and `seed` (`--order` and the `--seed` that reproduces the test order), and
/// `coverage` (the E2E line coverage summary of a `--coverage` run) when [coverage] is given.
///
/// The counts follow [ItResultCategory]: Passed counts PASS and MOCKED, Failed only the failed
/// categories (`app-defect`, `test-failure`), Skipped the tests the run did not select and the tests that
/// skipped themselves at runtime with a reason (`ItTestResult.explainedSkip`), and Blocked every other result
/// (credentials, environment, LambdaTest, build, test data, device, framework, NOT RUN without a reason, NOT
/// VERIFIED). `Failed` counts per test; `DistinctDefects` and `Defects` count the same failures once per distinct
/// defect with its occurrences (see `itDefectCounts`). `Categories` counts every category by name and `Tests`
/// lists each test with its category and the TestLesson that matched. `Result` is `Passed` only when at least
/// one test passed and nothing failed or was blocked: an empty or blocked run is never green.
String renderCiSummary(List<ItTestResult> results, CiSummaryContext context, {Map<String, Object?>? coverage}) {
  final passed = results.where((result) => result.outcome.passed).length;
  final skipped =
      results.where((result) => result.category == ItResultCategory.notSelected || result.explainedSkip).length;
  final failed = results.where((result) => result.category.failed).length;
  final blocked = results.length - passed - skipped - failed;
  final defects = itDefectCounts(results);
  String joined(String Function(ItRunLeg leg) field) => {for (final result in results) field(result.leg)}.join(',');
  final commits = {for (final result in results) _commitIn(result.leg.buildLabel)}.whereType<String>();
  final orders = {for (final result in results) result.leg.order}.whereType<TestOrder>();
  return const JsonEncoder.withIndent('  ').convert({
    'Env': joined((leg) => leg.environment),
    'Total': results.length,
    'Passed': passed,
    'Failed': failed,
    'Skipped': skipped,
    'Blocked': blocked,
    'Categories': itCategoryCounts(results),
    'DistinctDefects': defects.length,
    'Defects': [
      for (final defect in defects)
        {
          'defect': defect.defect,
          'category': defect.category,
          'occurrences': defect.occurrences,
          'tenants': defect.tenants,
        },
    ],
    'DurationSec': context.duration.inSeconds,
    'Result': passed > 0 && failed == 0 && blocked == 0 ? 'Passed' : 'Failed',
    'TestResultsUrl': context.testResultsUrl,
    'Platform': joined((leg) => leg.variant),
    'mplatrol_version': context.mplatrolVersion,
    'app_version': context.appVersion,
    'commit': commits.isEmpty ? null : commits.join(','),
    if (orders.isNotEmpty) 'order': orders.first.mode,
    if (orders.isNotEmpty) 'seed': orders.first.seed,
    if (coverage != null) 'coverage': coverage,
    'Legs': _legs(results),
    'Tests': [for (final result in results) _test(result)],
  });
}

/// Each leg's LambdaTest dashboard pages: the App Automation build page (`ltBuildUrl`) and the HyperExecute job
/// page (`hyperexecuteJobUrl`) of its job, space-separated when the leg ran several jobs (iOS waves).
List<Map<String, Object?>> _legs(List<ItTestResult> results) {
  final legs = <ItRunLeg, ItTestResult>{};
  for (final result in results) {
    legs.putIfAbsent(result.leg, () => result);
  }
  return [
    for (final MapEntry(key: leg, value: first) in legs.entries)
      {
        'tenant': leg.tenant,
        'environment': leg.environment,
        'variant': leg.variant,
        'ltBuildUrl': first.ltBuildUrl,
        'hyperexecuteJobUrl': first.hyperexecuteJobUrl,
      },
  ];
}

Map<String, Object?> _test(ItTestResult result) => {
      'name': result.name,
      'file': result.file,
      'tenant': result.leg.tenant,
      'environment': result.leg.environment,
      'variant': result.leg.variant,
      if (result.device != null) 'device': result.device,
      'outcome': result.outcome.label,
      'category': result.categoryName,
      if (result.caseKeys.isNotEmpty) 'test_cases': result.caseKeys,
      if (result.lesson != null) 'lesson': result.lesson!.name,
      if (result.retriedAfter != null) 'retried': result.retriedAfter,
      if (result.sessionUrl != null) 'ltTestUrl': result.sessionUrl,
      if (result.reason != null) 'reason': result.reason,
      if (result.details != null) 'details': result.details,
    };

/// The app commit in an E2E build label (`· app 1a2b3c4d+dirty`).
String? _commitIn(String? buildLabel) =>
    buildLabel == null ? null : RegExp(r'· app ([0-9a-f]+(?:\+dirty)?)').firstMatch(buildLabel)?[1];
