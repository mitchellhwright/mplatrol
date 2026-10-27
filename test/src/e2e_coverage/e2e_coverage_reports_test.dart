import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

final _startedAt = DateTime.utc(2026, 10, 5, 14, 30);

void main() {
  late Directory repo;
  late E2eCoverageReports reports;
  late MplatrolLogger logger;
  late MplatrolShell shell;

  setUp(() async {
    await scaffoldMockDependencies();
    repo = Directory.systemTemp.createTempSync('e2e_coverage_');
    reports = E2eCoverageReports();
    logger = getDep<MplatrolLogger>();
    shell = getDep<MplatrolShell>();
    when(() => getDep<PlatformWrapper>().environment).thenReturn({'MPLATROL_RUN_ID': 'run-7'});
    when(() => shell.whichSync('genhtml')).thenReturn(null);
  });

  tearDown(() => repo.deleteSync(recursive: true));

  void patrolLcov(String text) => File(p.join(repo.path, patrolLcovPath))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  Future<String?> collect() =>
      reports.collect(repo: repo.path, tenant: 'acme', variant: 'android', startedAt: _startedAt);

  test('prepare removes a stale Patrol report and tolerates none', () {
    reports.prepare(repo.path);
    patrolLcov('old');

    reports.prepare(repo.path);

    expect(File(p.join(repo.path, patrolLcovPath)).existsSync(), isFalse);
  });

  group('collect', () {
    test('filters to app code and writes the lcov and a JSON summary with the run identity', () async {
      patrolLcov('SF:/w/app/lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n'
          'SF:/w/app/lib/a.g.dart\nDA:1,1\nend_of_record\n'
          'SF:/w/app/lib/e2e/page.dart\nDA:1,1\nend_of_record\n');

      final path = await collect();

      expect(path, p.join(repo.path, '.mplatrol', 'reports', 'coverage', 'lcov-acme-android-20261005T143000Z.info'));
      expect(Lcov.parse(File(path!).readAsStringSync()).files.keys, ['/w/app/lib/a.dart']);
      final json = jsonDecode(File(p.setExtension(path, '.json')).readAsStringSync()) as Map<String, dynamic>;
      expect(json, containsPair('kind', 'run'));
      expect(json, containsPair('tenant', 'acme'));
      expect(json, containsPair('variant', 'android'));
      expect(json, containsPair('runId', 'run-7'));
      expect(json, containsPair('startedAt', '2026-10-05T14:30:00.000Z'));
      expect((json['overall'] as Map)['percent'], 50);
      expect((json['packages'] as Map).keys, ['app']);
      expect(reports.hasCoverage, isTrue);
      verify(() => logger.info('[coverage] E2E lcov: $path')).called(1);
    });

    test('names packages from the checkout package config', () async {
      File(p.join(repo.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
            '{"packages":[{"name":"shared_platform","rootUri":"file:///w/fp-splash","packageUri":"lib/"}]}');
      patrolLcov('SF:/w/fp-splash/lib/a.dart\nDA:1,1\nend_of_record\n');

      await collect();

      expect(reports.runSummary()!.packages.keys, ['shared_platform']);
    });

    test('errors and reports nothing when Patrol wrote no file', () async {
      expect(await collect(), isNull);

      verify(() => logger.err(any(
          that: allOf(contains('android/acme'), contains('wrote no coverage/patrol_lcov.info'),
              contains('COVERAGE_ENABLED'))))).called(1);
      expect(reports.hasCoverage, isFalse);
      expect(reports.runSummary(), isNull);
    });

    test('errors when the Patrol file is empty, as a June run left it', () async {
      patrolLcov('');

      expect(await collect(), isNull);

      verify(() => logger.err(any(that: contains('has no app code after filtering')))).called(1);
    });

    test('errors when the Patrol file is malformed', () async {
      patrolLcov('SF:/a/lib/x.dart\nDA:oops\n');

      expect(await collect(), isNull);

      verify(() => logger.err(any(that: contains('could not read')))).called(1);
    });

    test('merges the legs of a run into one summary', () async {
      patrolLcov('SF:/w/app/lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n');
      await collect();
      patrolLcov('SF:/w/app/lib/a.dart\nDA:1,0\nDA:2,1\nend_of_record\n');
      await reports.collect(repo: repo.path, tenant: 'acme', variant: 'ios', startedAt: _startedAt);

      expect(reports.runSummary()!.overall.percent, 100);
    });
  });

  group('packageNames', () {
    test('falls back to path names without a package config', () {
      expect(reports.packageNames(repo.path).of('/x/pkg/lib/a.dart'), 'pkg');
    });

    test('warns and falls back when the package config is not valid', () {
      File(p.join(repo.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');

      expect(reports.packageNames(repo.path).of('/x/pkg/lib/a.dart'), 'pkg');
      verify(() => logger.warn(any(that: contains('naming packages from paths')))).called(1);
    });
  });

  group('HTML report', () {
    final lcov = Lcov({
      '/w/pkg/lib/a.dart': {1: 1}
    });

    Future<void> write() =>
        reports.write(lcov, path: p.join(repo.path, 'out', 'x.info'), names: const PackageNames(), meta: {});

    test('is produced when genhtml is installed', () async {
      when(() => shell.whichSync('genhtml')).thenReturn('/opt/homebrew/bin/genhtml');
      when(() => shell.run(any(), throwOnError: any(named: 'throwOnError')))
          .thenAnswer((_) async => ProcessResultX(exitCode: 0, stdout: '', stderr: '', pid: 1));

      await write();

      verify(() => shell.run(
          'genhtml "${p.join(repo.path, 'out', 'x.info')}" --output-directory "${p.join(repo.path, 'out', 'x.html')}"',
          throwOnError: false)).called(1);
      verify(() => logger.info('[coverage] E2E HTML report: ${p.join(repo.path, 'out', 'x.html', 'index.html')}'))
          .called(1);
    });

    test('is skipped quietly when genhtml is not installed', () async {
      await write();

      verifyNever(() => shell.run(any(), throwOnError: any(named: 'throwOnError')));
      expect(File(p.join(repo.path, 'out', 'x.info')).existsSync(), isTrue);
    });

    test('a genhtml failure is a warning and keeps the lcov and JSON', () async {
      when(() => shell.whichSync('genhtml')).thenReturn('/usr/bin/genhtml');
      when(() => shell.run(any(), throwOnError: any(named: 'throwOnError')))
          .thenAnswer((_) async => ProcessResultX(exitCode: 1, stdout: '', stderr: 'boom', pid: 1));

      await write();

      verify(() => logger.warn(any(that: contains('genhtml failed (exit 1)')))).called(1);
      expect(File(p.join(repo.path, 'out', 'x.json')).existsSync(), isTrue);
    });
  });
}
