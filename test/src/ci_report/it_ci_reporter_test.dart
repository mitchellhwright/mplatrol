import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/results/result_sink.dart';
import 'package:mplatrol/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import '../../helpers/helpers.dart';

const _leg = ItRunLeg(tenant: 'acme', environment: 'staging', variant: 'lt-ios');
const _test = ItSelectedTest(id: 'm', file: 'login_test', description: 'reaches the home screen');

const _failureEvidence = 'Expected: true\n  Actual: <false>';

void main() {
  late Directory repo;
  late ItCiReporter reporter;
  late List<String> infos;

  setUp(() async {
    await scaffoldMockDependencies();
    repo = Directory.systemTemp.createTempSync('ci_report_');
    reporter = ItCiReporter();
    infos = [];
    when(() => getDep<MplatrolLogger>().info(any())).thenAnswer((invocation) {
      infos.add(invocation.positionalArguments.first as String);
    });
  });

  tearDown(() => repo.deleteSync(recursive: true));

  ItCiReportOptions options({String? ciReport, String? junitPath}) => ItCiReportOptions(
      repo: repo.path, startedAt: DateTime.utc(2026, 10, 2, 17, 57, 32), ciReport: ciReport, junitPath: junitPath);

  Map<String, dynamic> summary() =>
      jsonDecode(File(p.join(repo.path, '.mplatrol', 'reports', 'summary.json')).readAsStringSync())
          as Map<String, dynamic>;

  Future<void> runLeg(ItTestOutcome outcome) => getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..selectTests([_test])
          ..verdict(outcome, testId: 'm', evidence: outcome == ItTestOutcome.fail ? _failureEvidence : null);
      });

  group('teamCity', () {
    test('is on in TeamCity or with --ci-report=teamcity, else off', () {
      expect(reporter.teamCity(options()), isFalse);
      expect(reporter.teamCity(options(ciReport: ciReportTeamCity)), isTrue);
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'TEAMCITY_VERSION': '2025.07'});
      expect(reporter.teamCity(options()), isTrue);
    });
  });

  group('reportLeg', () {
    test('prints the leg test messages when TeamCity reporting is on', () async {
      await runLeg(ItTestOutcome.pass);
      reporter.reportLeg(_leg, options(ciReport: ciReportTeamCity));
      expect(infos.first, startsWith("##teamcity[testSuiteStarted name='mplatrol acme staging lt-ios'"));
      expect(infos, contains(startsWith("##teamcity[testStarted name='reaches the home screen'")));
    });

    test('links the LambdaTest build page of the HyperExecute job the leg ran', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..hyperexecuteJob('0a480ae9-b8a9-47d9-aa84-8fe7f5d84930')
          ..selectTests([_test])
          ..verdict(ItTestOutcome.pass, testId: 'm');
      });
      reporter.reportLeg(_leg, options());
      const page = 'https://appautomation.lambdatest.com/build?jobid=0a480ae9-b8a9-47d9-aa84-8fe7f5d84930';
      expect(infos, ['[lt] Build page: $page (every device session of this leg, with status, video and logs)']);
    });

    test('prints nothing otherwise', () async {
      await runLeg(ItTestOutcome.pass);
      reporter.reportLeg(_leg, options());
      expect(infos, isEmpty);
    });
  });

  group('finish', () {
    test('writes the JUnit report and summary.json at the default path', () async {
      await runLeg(ItTestOutcome.fail);
      await reporter.finish(options());
      final reports = Directory(p.join(repo.path, '.mplatrol', 'reports'));
      final junit = File(p.join(reports.path, 'junit-acme-lt-ios-20261002T175732Z.xml'));
      expect(XmlDocument.parse(junit.readAsStringSync()).findAllElements('failure'), hasLength(1));
      final summary = jsonDecode(File(p.join(reports.path, 'summary.json')).readAsStringSync()) as Map;
      expect([summary['Total'], summary['Failed'], summary['Result'], summary['mplatrol_version']],
          [1, 1, 'Failed', mplatrolVersion]);
      expect(infos, contains('[ci-report] JUnit report: ${junit.path}'));
      expect(infos, contains('[ci-report] 1 Patrol test result(s) reported.'));
      expect(infos.where((line) => line.startsWith('##teamcity')), isEmpty);
    });

    test('summary.json and the JUnit report carry the job, build and test pages', () async {
      const job = '0a480ae9-b8a9-47d9-aa84-8fe7f5d84930';
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..hyperexecuteJob(job)
          ..selectTests([_test])
          ..session('RMAA-1', const ItSessionDetails(testId: 'm', buildId: '7'))
          ..verdict(ItTestOutcome.pass, sessionId: 'RMAA-1');
      });
      await reporter.finish(options());
      final leg = (summary()['Legs'] as List).single as Map;
      expect(leg['hyperexecuteJobUrl'], 'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=$job');
      expect(leg['ltBuildUrl'], 'https://appautomation.lambdatest.com/build?jobid=$job');
      expect(((summary()['Tests'] as List).single as Map)['ltTestUrl'],
          'https://appautomation.lambdatest.com/test?build=7&testID=RMAA-1&selectedTab=logs');
      final xml =
          File(p.join(repo.path, '.mplatrol', 'reports', 'junit-acme-lt-ios-20261002T175732Z.xml')).readAsStringSync();
      expect(xml, contains('name="mplatrol.ltBuildUrl" value="https://appautomation.lambdatest.com/build?jobid=$job"'));
      expect(xml, contains('name="mplatrol.hyperexecuteJobUrl"'));
      expect(xml, contains('name="mplatrol.ltTestUrl" value="https://appautomation.lambdatest.com/test?build=7'));
    });

    test('prints the count of every category, then each selected non-pass with its lesson', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..selectTests([_test, const ItSelectedTest(id: 't', file: 'f', description: 'tunnel')])
          ..excludeTest(file: 'f', description: 'chatsdk', reason: 'SDK not built')
          ..verdict(ItTestOutcome.pass, testId: 'm')
          ..verdict(ItTestOutcome.fail, testId: 't', evidence: 'ERR::TUN::1');
      });
      await reporter.finish(options());
      expect(infos, contains('[results] 3 test(s), 0 failed (only app-defect and test-failure count as failed)'));
      expect(infos, contains('  pass           1\n  lt-tunnel-err  1\n  not-selected   1'));
      expect(infos, contains('[results] lt-tunnel-err: acme lt-ios tunnel (lesson lambdaTestTunnel)'));
      expect(infos.where((line) => line.startsWith('[results] ')), hasLength(2));
    });

    test('a retried test reports only its retry, marked retried, with the first attempt as a note', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        final results = getDep<ItRunResults>()
          ..selectTests([_test])
          ..session('RMAA-1', const ItSessionDetails(testId: 'm'))
          ..verdict(ItTestOutcome.fail, sessionId: 'RMAA-1', evidence: 'ERR::TUN::1');
        results
          ..beginRetry(results.retryableTests())
          ..session('RMAA-2', const ItSessionDetails(testId: 'm'))
          ..verdict(ItTestOutcome.fail, sessionId: 'RMAA-2', reason: 'Expected: true');
      });
      await reporter.finish(options());
      const note =
          'retried after lt-tunnel-err (lesson lambdaTestTunnel); first attempt FAIL [LambdaTest session RMAA-1]';
      expect(infos, contains('[results] test-failure: acme lt-ios reaches the home screen [retried once]'));
      final test = (summary()['Tests'] as List).single as Map;
      expect([test['category'], test['retried'], test['ltTestUrl']],
          ['test-failure', note, 'https://appautomation.lambdatest.com/test?testID=RMAA-2']);
      final xml =
          File(p.join(repo.path, '.mplatrol', 'reports', 'junit-acme-lt-ios-20261002T175732Z.xml')).readAsStringSync();
      expect(xml, contains('<property name="mplatrol.retried" value="$note"/>'));
      expect(xml, contains('<system-out>Retried: $note'));
    });

    test('links the test page next to each failed test that ran in a LambdaTest session', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..selectTests([_test])
          ..session('RMAA-1', const ItSessionDetails(testId: 'm', buildId: '28547361'))
          ..verdict(ItTestOutcome.fail, sessionId: 'RMAA-1', evidence: _failureEvidence);
      });
      await reporter.finish(options());
      expect(
          infos,
          contains('[results]   LambdaTest test page: '
              'https://appautomation.lambdatest.com/test?build=28547361&testID=RMAA-1&selectedTab=logs '
              '(video, screenshots, device and network logs for this test)'));
    });

    test('prints no category line for a run without results', () async {
      await reporter.finish(options());
      expect(infos.where((line) => line.startsWith('[results]')), isEmpty);
    });

    test('a FAIL without a lesson is named test-failure on the console', () async {
      await runLeg(ItTestOutcome.fail);
      await reporter.finish(options());
      expect(infos, contains('[results] test-failure: acme lt-ios reaches the home screen'));
    });

    test('a FAIL with no per-test detail is no-detail: not counted failed, logged with why, listed once', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..selectTests([_test])
          ..verdict(ItTestOutcome.fail, testId: 'm', reason: 'Dart test failed');
      });
      await reporter.finish(options());
      expect(infos, contains('[results] 1 test(s), 0 failed (only app-defect and test-failure count as failed)'));
      expect(infos, contains('[results] no-detail: acme lt-ios reaches the home screen'));
      verify(() => getDep<MplatrolLogger>().warn(
              any(that: allOf(contains('1 FAIL(s) carry no per-test failure detail'), contains('not test-failure')))))
          .called(1);
    });

    test('counts the failed tests by distinct defect with occurrences', () async {
      await getDep<ItRunResults>().withLeg(_leg, () async {
        getDep<ItRunResults>()
          ..selectTests([_test, const ItSelectedTest(id: 'g', file: 'f', description: 'crash a')])
          ..verdict(ItTestOutcome.fail, testId: 'm', evidence: _failureEvidence)
          ..verdict(ItTestOutcome.fail,
              testId: 'g', evidence: 'E AndroidRuntime: FATAL EXCEPTION: main\nProcess: com.example.app');
      });
      await reporter.finish(options());
      expect(infos, contains('[results] 2 failed test(s) are 2 distinct defect(s):'));
      expect(infos, contains('[results]   1x appProcessCrashed [app-defect] on acme'));
      expect(infos, contains('[results]   1x test: reaches the home screen [test-failure] on acme'));
    });

    test('writes to --junit, with the CI job link in the summary', () async {
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'CI_JOB_URL': 'https://ci.example.test/job/9'});
      await runLeg(ItTestOutcome.pass);
      final path = p.join(repo.path, 'out', 'mplatrol.xml');
      await reporter.finish(options(junitPath: path));
      expect(File(path).existsSync(), isTrue);
      final summary = jsonDecode(File(p.join(repo.path, 'out', 'summary.json')).readAsStringSync()) as Map;
      expect([summary['Result'], summary['TestResultsUrl']], ['Passed', 'https://ci.example.test/job/9']);
    });

    test('prints the run statistics in TeamCity', () async {
      await runLeg(ItTestOutcome.pass);
      await reporter.finish(options(ciReport: ciReportTeamCity));
      expect(infos, contains("##teamcity[buildStatisticValue key='mplatrol.passed' value='1']"));
      expect(infos.where((line) => line.contains('buildProblem')), isEmpty);
    });

    test('a run without results still writes a not-verified report and fails in TeamCity', () async {
      await reporter.finish(options(ciReport: ciReportTeamCity));
      final junit = File(p.join(repo.path, '.mplatrol', 'reports', 'junit-none-none-20261002T175732Z.xml'));
      expect(XmlDocument.parse(junit.readAsStringSync()).findAllElements('error'), hasLength(1));
      expect(infos, contains(contains('buildProblem')));
    });

    test('publishes the run to every result sink and logs where it went', () async {
      final sink = _RecordingSink();
      GetIt.I.unregister<ResultSinks>();
      GetIt.I.registerSingleton(ResultSinks([sink]));
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'CI_JOB_URL': 'https://ci.example.test/job/9'});
      await runLeg(ItTestOutcome.fail);

      await reporter.finish(options());

      final report = sink.reports.single;
      expect(report.results.single.leg.tenant, 'acme');
      expect(report.runUrl, 'https://ci.example.test/job/9');
      expect(infos, contains('[ci-report] recording: memory://report'));
    });

    test('a failing result sink is a warning and the other sinks still publish', () async {
      final sink = _RecordingSink();
      GetIt.I.unregister<ResultSinks>();
      GetIt.I.registerSingleton(ResultSinks([_FailingSink(), sink]));
      await runLeg(ItTestOutcome.pass);

      await reporter.finish(options());

      expect(sink.reports, hasLength(1));
      verify(() => getDep<MplatrolLogger>().warn(any(that: startsWith('[ci-report] result sink failing failed'))))
          .called(1);
    });

    test('a run with E2E coverage records it in summary.json and prints it', () async {
      File(p.join(repo.path, patrolLcovPath))
        ..createSync(recursive: true)
        ..writeAsStringSync('SF:/w/app/lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n');
      await getDep<E2eCoverageReports>()
          .collect(repo: repo.path, tenant: 'acme', variant: 'ios', startedAt: DateTime.utc(2026, 10, 5));
      await runLeg(ItTestOutcome.pass);

      await reporter.finish(options());

      final coverage = summary()['coverage'] as Map<String, dynamic>;
      expect(coverage['overall'], {'hit': 1, 'total': 2, 'percent': 50.0});
      expect((coverage['packages'] as Map).keys, ['app']);
      expect(infos, contains('[coverage] E2E (journey) line coverage: 1/2 lines, 50.0%'));
    });

    test('a run without coverage has no coverage entry', () async {
      await runLeg(ItTestOutcome.pass);
      await reporter.finish(options());
      expect(summary().containsKey('coverage'), isFalse);
      expect(infos.where((line) => line.startsWith('[coverage]')), isEmpty);
    });

    test('a report that cannot be written is a warning', () async {
      await runLeg(ItTestOutcome.pass);
      final blocker = File(p.join(repo.path, 'blocker'))..writeAsStringSync('');
      await reporter.finish(options(junitPath: p.join(blocker.path, 'junit.xml')));
      verify(() => getDep<MplatrolLogger>().warn(any(that: startsWith('[ci-report] could not write the JUnit report'))))
          .called(1);
      verify(() => getDep<MplatrolLogger>().warn(any(that: startsWith('[ci-report] could not write the run summary'))))
          .called(1);
    });
  });

  test('defaultJUnitPath joins several tenants and variants', () async {
    const other = ItRunLeg(tenant: 'globex', environment: 'staging', variant: 'lt-android');
    await runLeg(ItTestOutcome.pass);
    await getDep<ItRunResults>().withLeg(other, () async => getDep<ItRunResults>().selectTests([_test]));
    expect(p.basename(reporter.defaultJUnitPath(getDep<ItRunResults>().results, options())),
        'junit-acme+globex-lt-ios+lt-android-20261002T175732Z.xml');
  });
}

class _RecordingSink implements ResultSink {
  final reports = <RunReport>[];

  @override
  String get name => 'recording';

  @override
  Future<String?> publish(RunReport report) async {
    reports.add(report);
    return 'memory://report';
  }
}

class _FailingSink implements ResultSink {
  @override
  String get name => 'failing';

  @override
  Future<String?> publish(RunReport report) async => throw StateError('dashboard is down');
}
