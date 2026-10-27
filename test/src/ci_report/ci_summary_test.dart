import 'dart:convert';

import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:test/test.dart';

const _acme = ItRunLeg(
    tenant: 'acme',
    environment: 'Staging',
    variant: 'lt-ios',
    buildLabel: 'mplatrol 1.0 · acme Staging · dev · app 1a2b3c4d+dirty',
    order: TestOrder.random(1234));
const _globex = ItRunLeg(tenant: 'globex', environment: 'QA', variant: 'lt-android');

const CiSummaryContext _context = (
  duration: Duration(seconds: 977),
  testResultsUrl: 'https://ci.example.test/job/1',
  mplatrolVersion: '2.1408.3',
  appVersion: 'dev',
);

ItTestResult _result(ItRunLeg leg, ItTestOutcome outcome, {bool selected = true, TestLesson? lesson}) => ItTestResult(
    leg: leg, file: 'f', description: '$outcome $lesson', outcome: outcome, selected: selected, lesson: lesson);

Map<String, dynamic> _summary(List<ItTestResult> results) =>
    jsonDecode(renderCiSummary(results, _context)) as Map<String, dynamic>;

void main() {
  test('counts failed tests per test and per distinct defect, with occurrences and tenants', () {
    final summary = _summary([
      for (final leg in [_acme, _globex, _acme]) _result(leg, ItTestOutcome.fail, lesson: TestLesson.appProcessCrashed),
      _result(_globex, ItTestOutcome.fail),
      _result(_globex, ItTestOutcome.fail, lesson: TestLesson.lambdaTestTunnel),
    ]);
    expect(summary['Failed'], 4);
    expect(summary['DistinctDefects'], 2);
    expect(summary['Defects'], [
      {
        'defect': 'appProcessCrashed',
        'category': 'app-defect',
        'occurrences': 3,
        'tenants': ['acme', 'globex'],
      },
      {
        'defect': 'test: ItTestOutcome.fail null',
        'category': 'test-failure',
        'occurrences': 1,
        'tenants': ['globex'],
      },
    ]);
  });

  test('uses the summary fields plus the mplatrol, app and commit identity', () {
    final summary = _summary([
      _result(_acme, ItTestOutcome.pass),
      _result(_acme, ItTestOutcome.mocked),
      _result(_globex, ItTestOutcome.notRun, selected: false),
    ]);
    expect(summary, {
      'Env': 'Staging,QA',
      'Total': 3,
      'Passed': 2,
      'Failed': 0,
      'Skipped': 1,
      'Blocked': 0,
      'Categories': {'pass': 2, 'not-selected': 1},
      'DistinctDefects': 0,
      'Defects': <Object?>[],
      'DurationSec': 977,
      'Result': 'Passed',
      'TestResultsUrl': 'https://ci.example.test/job/1',
      'Platform': 'lt-ios,lt-android',
      'mplatrol_version': '2.1408.3',
      'app_version': 'dev',
      'commit': '1a2b3c4d+dirty',
      'order': 'random',
      'seed': 1234,
      'Legs': [
        {
          'tenant': 'acme',
          'environment': 'Staging',
          'variant': 'lt-ios',
          'ltBuildUrl': null,
          'hyperexecuteJobUrl': null,
        },
        {
          'tenant': 'globex',
          'environment': 'QA',
          'variant': 'lt-android',
          'ltBuildUrl': null,
          'hyperexecuteJobUrl': null,
        },
      ],
      'Tests': [
        {
          'name': 'ItTestOutcome.pass null',
          'file': 'f',
          'tenant': 'acme',
          'environment': 'Staging',
          'variant': 'lt-ios',
          'outcome': 'PASS',
          'category': 'pass',
        },
        {
          'name': 'ItTestOutcome.mocked null',
          'file': 'f',
          'tenant': 'acme',
          'environment': 'Staging',
          'variant': 'lt-ios',
          'outcome': 'MOCKED',
          'category': 'pass',
        },
        {
          'name': 'ItTestOutcome.notRun null',
          'file': 'f',
          'tenant': 'globex',
          'environment': 'QA',
          'variant': 'lt-android',
          'outcome': 'NOT RUN',
          'category': 'not-selected',
        },
      ],
    });
  });

  // Regression: r11 runtime skips were Blocked, so no lt-ios leg could ever pass.
  test('a runtime skip with its reason is Skipped and lets the run pass; one without a reason blocks it', () {
    ItTestResult skip(String reason) =>
        ItTestResult(leg: _globex, file: 'f', description: reason, outcome: ItTestOutcome.notRun, reason: reason);
    final explained = _summary([
      _result(_globex, ItTestOutcome.pass),
      skip('$itRuntimeSkipReason (MOCK_TENANT_MISMATCH PROJ-TC-23589 needs an app prepared for soylent, testBDelete)'),
      skip('$itRuntimeSkipReason (native test a/b skipped: DEVICE_NO_BIOMETRICS no_enrolled_biometrics)'),
    ]);
    expect([explained['Passed'], explained['Failed'], explained['Blocked'], explained['Skipped'], explained['Result']],
        [1, 0, 0, 2, 'Passed']);
    for (final generic in [
      itRuntimeSkipReason,
      '$itRuntimeSkipReason (Dart test skipped at runtime, testBSpanish)',
      '$itRuntimeSkipReason (native test a/b skipped (JUnit assumption/status -4); a native skip is not a pass)',
    ]) {
      final blocked = _summary([_result(_globex, ItTestOutcome.pass), skip(generic)]);
      expect([blocked['Blocked'], blocked['Skipped'], blocked['Result']], [1, 0, 'Failed'], reason: generic);
    }
  });

  test('only failed categories count as Failed; every other selected non-pass is Blocked and fails the run', () {
    final summary = _summary([
      _result(_globex, ItTestOutcome.pass),
      _result(_globex, ItTestOutcome.fail),
      _result(_globex, ItTestOutcome.fail, lesson: TestLesson.lambdaTestTunnel),
      _result(_globex, ItTestOutcome.notVerified),
      _result(_globex, ItTestOutcome.notRun),
    ]);
    expect([summary['Passed'], summary['Failed'], summary['Blocked'], summary['Skipped'], summary['Result']],
        [1, 1, 3, 0, 'Failed']);
    expect(summary['Categories'], {'pass': 1, 'test-failure': 1, 'lt-tunnel-err': 1, 'not-run': 1, 'not-verified': 1});
    final tunnel = (summary['Tests'] as List).cast<Map<String, dynamic>>()[2];
    expect([tunnel['outcome'], tunnel['category'], tunnel['lesson']], ['FAIL', 'lt-tunnel-err', 'lambdaTestTunnel']);
    expect(summary['commit'], isNull);
    expect(summary.containsKey('seed'), isFalse, reason: 'a leg without an order records none');
  });

  test('a test carries its test case keys, lesson and LambdaTest session', () {
    const lesson = TestLesson.appProcessCrashed;
    final result = ItTestResult(
      leg: _globex,
      file: 'f',
      description: 'PROJ-TC-123 PROJ-TC-456 sign in',
      outcome: ItTestOutcome.fail,
      ltSessionId: 'S1',
      ltBuildId: '28547361',
      lesson: lesson,
    );

    final test = (_summary([result])['Tests'] as List).cast<Map<String, dynamic>>().single;

    expect(test['test_cases'], ['PROJ-TC-123', 'PROJ-TC-456']);
    expect(test['lesson'], lesson.name);
    expect(test['ltTestUrl'], 'https://appautomation.lambdatest.com/test?build=28547361&testID=S1&selectedTab=logs');
  });

  test('a leg carries the build and HyperExecute job pages of every job it ran', () {
    const jobs = ['0a480ae9-b8a9-47d9-aa84-8fe7f5d84930', 'cb4e4649-e6df-48d8-86b3-a8a1fa70019f'];
    ItTestResult result(ItRunLeg leg, String file) =>
        ItTestResult(leg: leg, file: file, description: file, outcome: ItTestOutcome.pass, hyperexecuteJobIds: jobs);

    final legs = (_summary([result(_globex, 'a'), result(_globex, 'b')])['Legs'] as List).cast<Map<String, dynamic>>();

    expect(legs, hasLength(1));
    expect(
        legs.single['hyperexecuteJobUrl'],
        'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=${jobs[0]} '
        'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=${jobs[1]}');
    expect(
        legs.single['ltBuildUrl'],
        'https://appautomation.lambdatest.com/build?jobid=${jobs[0]} '
        'https://appautomation.lambdatest.com/build?jobid=${jobs[1]}');
  });

  test('a run with no executed test is Failed, never green', () {
    expect(_summary(const [])['Result'], 'Failed');
    expect(_summary([_result(_globex, ItTestOutcome.notRun, selected: false)])['Result'], 'Failed');
  });

  test('a run whose only non-passes are blockers has no failures and is still not green', () {
    final summary = _summary([
      _result(_globex, ItTestOutcome.pass),
      _result(_globex, ItTestOutcome.fail, lesson: TestLesson.loginErrorPage),
    ]);
    expect([summary['Failed'], summary['Blocked'], summary['Result']], [0, 1, 'Failed']);
    expect(summary['Categories'], {'pass': 1, 'qa-env-failure': 1});
  });

  test('carries coverage only when given', () {
    final results = [_result(_globex, ItTestOutcome.pass)];
    expect(_summary(results).containsKey('coverage'), isFalse);
    final withCoverage = jsonDecode(renderCiSummary(results, _context, coverage: {
      'overall': {'percent': 12.5}
    }));
    expect((withCoverage as Map)['coverage'], {
      'overall': {'percent': 12.5}
    });
  });
}
