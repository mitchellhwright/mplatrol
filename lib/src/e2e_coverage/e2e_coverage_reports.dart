import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/e2e_coverage/coverage_summary.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;

/// Where `patrol test --coverage` writes its LCOV report, relative to the app root it runs in.
const patrolLcovPath = 'coverage/patrol_lcov.info';

/// Collects the E2E (journey) coverage of `mplatrol run --coverage`: filters each leg's Patrol LCOV to app code,
/// writes `.mplatrol/reports/coverage/lcov-<tenant>-<variant>-<timestamp>.info` with a JSON summary beside it, and
/// merges the legs of the run for `summary.json` and the console.
class E2eCoverageReports {
  final _collected = <Lcov>[];
  PackageNames _names = const PackageNames();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Whether any leg of this run produced coverage.
  bool get hasCoverage => _collected.isNotEmpty;

  /// `<repo>/.mplatrol/reports/coverage`.
  String reportsDirectory(String repo) => p.join(repo, '.mplatrol', 'reports', 'coverage');

  /// Removes a stale Patrol LCOV so a run that produces none is not credited with an older run's coverage.
  void prepare(String repo) {
    final stale = File(p.join(repo, patrolLcovPath));
    if (stale.existsSync()) {
      stale.deleteSync();
    }
  }

  /// Reads the Patrol LCOV a finished leg wrote, keeps app code, and writes the leg's report. Returns the LCOV path,
  /// or null, logging an error and recording [TestLesson.emptyCoverage] when Patrol produced no usable coverage.
  Future<String?> collect({
    required String repo,
    required String tenant,
    required String variant,
    required DateTime startedAt,
  }) async {
    final source = File(p.join(repo, patrolLcovPath));
    if (!source.existsSync()) {
      return _missing('$variant/$tenant: Patrol wrote no $patrolLcovPath, so there is no coverage for this leg.');
    }
    final Lcov lcov;
    try {
      lcov = Lcov.parse(source.readAsStringSync()).appCodeOnly();
    } on FormatException catch (error) {
      return _missing('$variant/$tenant: could not read ${source.path}: ${error.message}.');
    }
    if (lcov.files.isEmpty) {
      return _missing('$variant/$tenant: ${source.path} has no app code after filtering; nothing to report.');
    }
    _names = packageNames(repo);
    _collected.add(lcov);
    final path = p.join(reportsDirectory(repo), 'lcov-$tenant-$variant-${timestamp(startedAt)}.info');
    await write(lcov, path: path, names: _names, meta: {
      'kind': 'run',
      'tenant': tenant,
      'variant': variant,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'runId': getDep<PlatformWrapper>().environment['MPLATROL_RUN_ID'],
    });
    return path;
  }

  String? _missing(String what) {
    _logger.err('[coverage] $what ${TestLesson.emptyCoverage.remedy}');
    getDep<ItRunResults>().observeLessons([TestLesson.emptyCoverage]);
    return null;
  }

  /// The merged summary of every collected leg, or null when no leg produced coverage.
  CoverageSummary? runSummary() => _collected.isEmpty ? null : CoverageSummary.of(Lcov.merge(_collected), _names);

  /// Writes [lcov] to [path], its [CoverageSummary] with [meta] to the same name with `.json`, and an HTML report
  /// beside it when `genhtml` is installed. Returns the summary.
  Future<CoverageSummary> write(
    Lcov lcov, {
    required String path,
    required PackageNames names,
    required Map<String, Object?> meta,
  }) async {
    final summary = CoverageSummary.of(lcov, names);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(lcov.render());
    File(p.setExtension(path, '.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      ...meta,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'lcov': p.basename(path),
      ...summary.toJson(),
    }));
    _logger.info('[coverage] E2E lcov: $path');
    await _html(path);
    return summary;
  }

  /// The package names of the app checkout [repo], or path-derived names without its package config.
  PackageNames packageNames(String repo) {
    final config = File(p.join(repo, '.dart_tool', 'package_config.json'));
    if (!config.existsSync()) {
      return const PackageNames();
    }
    try {
      return PackageNames.fromPackageConfig(config.readAsStringSync(), configDirectory: config.parent.path);
    } on FormatException catch (error) {
      _logger.warn('[coverage] could not read ${config.path}: ${error.message}; naming packages from paths.');
      return const PackageNames();
    }
  }

  /// `20261005T143000Z`, the timestamp in report file names.
  String timestamp(DateTime time) => time.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]|\.\d+'), '');

  Future<void> _html(String lcovPath) async {
    final shell = getDep<MplatrolShell>();
    if (shell.whichSync('genhtml') == null) {
      _logger.detail('[coverage] genhtml is not installed; skipping the HTML report (brew install lcov).');
      return;
    }
    final output = p.setExtension(lcovPath, '.html');
    final result = await shell.run('genhtml "$lcovPath" --output-directory "$output"', throwOnError: false);
    if (result.exitCode == 0) {
      _logger.info('[coverage] E2E HTML report: ${p.join(output, 'index.html')}');
    } else {
      _logger.warn('[coverage] genhtml failed (exit ${result.exitCode}); the lcov and JSON reports are unaffected.');
    }
  }
}
