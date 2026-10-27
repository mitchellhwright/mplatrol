import 'dart:io';

import 'package:mplatrol/src/ci_report/ci_summary.dart';
import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/ci_report/teamcity_messages.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/terminal_capabilities.dart';
import 'package:mplatrol/src/core/terminal_text.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/results/result_sink.dart';
import 'package:mplatrol/src/version.dart';
import 'package:path/path.dart' as p;

/// The `--ci-report` value that turns on TeamCity service messages.
const ciReportTeamCity = 'teamcity';

/// How one `mplatrol run` reports its per-test results to CI.
class ItCiReportOptions {
  const ItCiReportOptions({
    required this.repo,
    required this.startedAt,
    this.ciReport,
    this.junitPath,
  });

  /// The app root; the default JUnit file goes under its `.mplatrol`.
  final String repo;
  final DateTime startedAt;

  /// `teamcity` to emit TeamCity service messages outside TeamCity.
  final String? ciReport;

  /// Where to write the JUnit XML instead of the default path.
  final String? junitPath;
}

/// Publishes the results [ItRunResults] collected: TeamCity service messages
/// per leg and run statistics (in TeamCity, or with `--ci-report=teamcity`),
/// and one JUnit XML file plus a `summary.json` per run, then publishes the run to every configured
/// [ResultSink]. Reporting never changes a verdict or the exit code: a report that cannot be written or
/// published is a warning.
class ItCiReporter {
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  ItRunResults get _results => getDep<ItRunResults>();

  /// Whether TeamCity service messages are on for [options].
  bool teamCity(ItCiReportOptions options) =>
      options.ciReport == ciReportTeamCity ||
      (getDep<PlatformWrapper>().environment['TEAMCITY_VERSION'] ?? '').isNotEmpty;

  /// Logs the LambdaTest build page of [leg] once it finished, and emits its TeamCity test messages.
  void reportLeg(ItRunLeg leg, ItCiReportOptions options) {
    final build = _results.resultsOf(leg).firstOrNull?.ltBuildUrl;
    if (build != null) {
      _logger.info('[lt] Build page: $build (every device session of this leg, with status, video and logs)');
    }
    if (!teamCity(options)) {
      return;
    }
    teamCityTestMessages(_results.resultsOf(leg)).forEach(_logger.info);
  }

  /// Emits the run statistics, writes the JUnit report for every leg and a `summary.json` beside it, then
  /// publishes the run to every [ResultSink]. A run without results still writes both, as not verified.
  Future<void> finish(ItCiReportOptions options) async {
    final results = _results.results;
    final duration = DateTime.now().difference(options.startedAt);
    if (teamCity(options)) {
      final statistics = teamCityStatistics(results, duration: duration, buildReuses: _results.buildReuses);
      teamCityStatisticMessages(statistics, results).forEach(_logger.info);
    }
    final env = getDep<PlatformWrapper>().environment;
    final report = RunReport(
      results: results,
      startedAt: options.startedAt,
      duration: duration,
      toolVersion: mplatrolVersion,
      runUrl: env['CI_JOB_URL'] ?? env['BUILD_URL'] ?? env['GITHUB_SERVER_URL'],
      appVersion: appVersionOf(env),
    );
    final coverage = getDep<E2eCoverageReports>().runSummary();
    final path = options.junitPath ?? defaultJUnitPath(results, options);
    _write('JUnit report', path, report.renderJUnit());
    _write(
        'run summary',
        p.join(p.dirname(path), 'summary.json'),
        renderCiSummary(
          results,
          (
            duration: duration,
            testResultsUrl: report.runUrl,
            mplatrolVersion: mplatrolVersion,
            appVersion: report.appVersion,
          ),
          coverage: coverage?.toJson(),
        ));
    for (final outcome in await getDep<ResultSinks>().publishAll(report)) {
      if (outcome.error != null) {
        _logger.warn('[ci-report] result sink ${outcome.sink} failed: ${outcome.error}; the run verdict is '
            'unchanged.');
      } else if (outcome.location != null) {
        _logger.info('[ci-report] ${outcome.sink}: ${outcome.location}');
      }
    }
    _logger.info('[ci-report] ${results.length} Patrol test result(s) reported.');
    _logCategories(results);
    coverage?.renderConsole().forEach(_logger.info);
  }

  /// The console summary: the count of every category, then each selected test
  /// that did not pass with its category and the lesson that explained it.
  void _logCategories(List<ItTestResult> results) {
    final counts = itCategoryCounts(results);
    if (counts.isEmpty) {
      return;
    }
    final failed = results.where((result) => result.category.failed).length;
    final text = TerminalText(getDep<TerminalCapabilities>());
    _logger
      ..info('[results] ${results.length} test(s), $failed failed (only app-defect and test-failure count as failed)')
      ..info(text.table([for (final MapEntry(:key, :value) in counts.entries) (key, value)]).join('\n'));
    final defects = itDefectCounts(results);
    if (defects.isNotEmpty) {
      _logger.info('[results] $failed failed test(s) are ${defects.length} distinct defect(s):');
      for (final defect in defects) {
        _logger.info('[results]   ${defect.occurrences}x ${defect.defect} [${defect.category}] '
            'on ${defect.tenants.join(', ')}');
      }
    }
    final noDetail = counts[ItResultCategory.noDetail.label] ?? 0;
    if (noDetail > 0) {
      _logger.warn('[results] $noDetail FAIL(s) carry no per-test failure detail (no test log reached mplatrol, or '
          'only the generic "Dart test failed" line), so they count as no-detail, not test-failure. Fetch their '
          'LambdaTest test logs (hyperexecute/<platform>/logs/<job>/scenarios) or videos and triage them.');
    }
    for (final result in results
        .where((result) => !const {ItResultCategory.pass, ItResultCategory.notSelected}.contains(result.category))) {
      final lesson = result.lesson == null ? '' : ' (lesson ${result.lesson!.name})';
      final retried = result.retriedAfter == null ? '' : ' [retried once]';
      _logger.info('[results] ${result.categoryName}: ${result.leg.tenant} ${result.leg.variant} '
          '${result.name}$lesson$retried');
      final test = result.sessionUrl;
      if (test != null) {
        _logger.info('[results]   LambdaTest test page: $test (video, screenshots, device and network logs for '
            'this test)');
      }
    }
  }

  void _write(String what, String path, String content) {
    try {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
      _logger.info('[ci-report] $what: $path');
    } on FileSystemException catch (error) {
      _logger.warn('[ci-report] could not write the $what to $path: ${error.message}; the run verdict is '
          'unchanged. Check the directory is writable, or pass --junit=<path>.');
    }
  }

  /// `<repo>/.mplatrol/reports/junit-<tenant>-<variant>-<timestamp>.xml`, joining
  /// several tenants or variants with `+`.
  String defaultJUnitPath(List<ItTestResult> results, ItCiReportOptions options) {
    String joined(String Function(ItRunLeg) field) {
      final values = {for (final result in results) field(result.leg)};
      return values.isEmpty ? 'none' : values.join('+');
    }

    final stamp = options.startedAt.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]|\.\d+'), '');
    final name = 'junit-${joined((leg) => leg.tenant)}-${joined((leg) => leg.variant)}-$stamp.xml';
    return p.join(options.repo, '.mplatrol', 'reports', name.replaceAll(RegExp('[^A-Za-z0-9+._-]'), '_'));
  }
}

/// Env var: the version of the app under test, for reports.
const appVersionEnv = 'MPLATROL_APP_VERSION';

/// Env var: the build number of the app under test, for reports.
const appBuildEnv = 'MPLATROL_APP_BUILD';

/// `<version> (<build>)` from [appVersionEnv] and [appBuildEnv], `<version>` without a build, else `dev`.
String appVersionOf(Map<String, String> env) {
  final version = env[appVersionEnv]?.trim() ?? '';
  final build = env[appBuildEnv]?.trim() ?? '';
  if (version.isEmpty) {
    return 'dev';
  }
  return build.isEmpty ? version : '$version ($build)';
}
