import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:test/test.dart';

const _leg = ItRunLeg(tenant: 'acme', environment: 'Staging', variant: 'lt-ios');

ItTestResult _result(String file, String description, ItTestOutcome outcome,
        {String? reason, bool selected = true, Duration? duration, bool flaky = false, TestLesson? lesson}) =>
    ItTestResult(
      leg: _leg,
      file: file,
      description: description,
      outcome: outcome,
      reason: reason,
      selected: selected,
      duration: duration,
      flaky: flaky,
      lesson: lesson,
    );

void main() {
  group('escapeTeamCityValue', () {
    test("escapes | ' [ ] newline and carriage return", () {
      expect(escapeTeamCityValue("a|b'c[d]e\nf\rg"), "a||b|'c|[d|]e|nf|rg");
    });

    test('escapes non-ASCII characters as |0x code units', () {
      expect(escapeTeamCityValue('mplatrol 1.0 · é'), 'mplatrol 1.0 |0x00b7 |0x00e9');
      expect(escapeTeamCityValue('ok ✅'), 'ok |0x2705');
      expect(escapeTeamCityValue('😀'), '|0xd83d|0xde00');
    });
  });

  group('teamCityTestMessages', () {
    test('is empty without results', () {
      expect(teamCityTestMessages(const []), isEmpty);
    });

    test('nests a suite per file in the leg suite, all on the leg flow', () {
      final messages = teamCityTestMessages([
        _result('patrol_login_test', 'reaches accounts', ItTestOutcome.pass, duration: const Duration(seconds: 52)),
        _result('login_faults_test', 'fast-fails', ItTestOutcome.mocked),
      ]);
      expect(
          messages.first,
          "##teamcity[testSuiteStarted name='mplatrol acme Staging lt-ios' "
          "flowId='mplatrol-acme-Staging-lt-ios']");
      expect(messages[1], contains("testSuiteStarted name='patrol_login_test'"));
      expect(messages[2], contains("testStarted name='reaches accounts' captureStandardOutput='false'"));
      expect(messages, contains(contains("testFinished name='reaches accounts' duration='52000'")));
      expect(messages, contains("##teamcity[testFinished name='fast-fails' flowId='mplatrol-acme-Staging-lt-ios']"));
      expect(messages.last, contains("testSuiteFinished name='mplatrol acme Staging lt-ios'"));
      expect(messages.every((message) => message.contains("flowId='mplatrol-acme-Staging-lt-ios'")), isTrue);
      expect(messages.where((message) => message.contains('testFailed') || message.contains('testIgnored')), isEmpty);
    });

    test('emits metadata per test, links typed as links', () {
      final messages = teamCityTestMessages([
        const ItTestResult(
          leg: _leg,
          file: 'f',
          description: 'PROJ-TC-34713 deep link',
          outcome: ItTestOutcome.pass,
          ltSessionId: 'RMAA-IOS-1',
        ),
      ]);
      expect(
          messages,
          contains(
              contains("testMetadata testName='PROJ-TC-34713 deep link' name='Ticket' value='PROJ-TC-34713' flowId=")));
      expect(
          messages,
          contains(contains("name='LambdaTest session' "
              "value='https://appautomation.lambdatest.com/test?testID=RMAA-IOS-1' type='link'")));
    });

    test('fails only the failed categories; every other non-pass is ignored under its category', () {
      final messages = teamCityTestMessages([
        _result('chatsdk_chat_journey_test', 'opens chat', ItTestOutcome.notRun,
            reason: 'not selected: SDK not built: chatsdk', selected: false),
        _result('f', 'skipped', ItTestOutcome.notRun, reason: itRuntimeSkipReason),
        _result('f', 'unverified', ItTestOutcome.notVerified),
        _result('f', 'tunnel', ItTestOutcome.fail, reason: 'ERR::TUN::1', lesson: TestLesson.lambdaTestTunnel),
        _result('f', 'assert', ItTestOutcome.fail, reason: 'expected 1'),
        _result('f', 'rdc', ItTestOutcome.fail, reason: 'NullPointerException', lesson: TestLesson.appProcessCrashed),
      ]);
      expect(
          messages,
          contains(
              contains("testIgnored name='opens chat' message='not-selected: not selected: SDK not built: chatsdk'")));
      expect(messages, contains(contains("testIgnored name='skipped' message='not-run: $itRuntimeSkipReason'")));
      expect(messages, contains(contains("testIgnored name='unverified' message='not-verified: NOT VERIFIED'")));
      expect(messages, contains(contains("testIgnored name='tunnel' message='lt-tunnel-err: ERR::TUN::1'")));
      expect(messages, contains(contains("testFailed name='assert' message='test-failure: expected 1'")));
      expect(messages, contains(contains("testFailed name='rdc' message='app-defect: NullPointerException'")));
      expect(messages, contains(contains("testMetadata testName='tunnel' name='Category' value='lt-tunnel-err'")));
    });
  });

  group('statistics', () {
    final results = [
      _result('f', 'a', ItTestOutcome.pass, flaky: true),
      _result('f', 'b', ItTestOutcome.fail),
      _result('f', 'c', ItTestOutcome.notRun),
      _result('f', 'd', ItTestOutcome.notVerified),
      _result('f', 'e', ItTestOutcome.mocked),
    ];

    test('counts every outcome, flaky passes, duration and build reuses', () {
      expect(teamCityStatistics(results, duration: const Duration(seconds: 2252), buildReuses: 1), {
        'mplatrol.total': 5,
        'mplatrol.passed': 1,
        'mplatrol.failed': 1,
        'mplatrol.skipped': 1,
        'mplatrol.notVerified': 1,
        'mplatrol.mocked': 1,
        'mplatrol.flakyRetried': 1,
        'mplatrol.durationSec': 2252,
        'mplatrol.buildReuses': 1,
        'mplatrol.category.pass': 2,
        'mplatrol.category.test-failure': 1,
        'mplatrol.category.not-run': 1,
        'mplatrol.category.not-verified': 1,
      });
    });

    test('counts a FAIL a blocker explains under its category, not as failed', () {
      final statistics = teamCityStatistics(
          [_result('f', 'a', ItTestOutcome.fail, lesson: TestLesson.cocoaPodsSpecsOutdated)],
          duration: Duration.zero, buildReuses: 0);
      expect([statistics['mplatrol.failed'], statistics['mplatrol.category.build-failure']], [0, 1]);
    });

    test('includes the queue wait when known', () {
      final statistics =
          teamCityStatistics(results, duration: Duration.zero, buildReuses: 0, queueWait: const Duration(seconds: 95));
      expect(statistics['mplatrol.queueWaitSec'], 95);
    });

    test('renders one buildStatisticValue per statistic', () {
      expect(teamCityStatisticMessages(const {'mplatrol.total': 3}, results),
          ["##teamcity[buildStatisticValue key='mplatrol.total' value='3']"]);
    });

    test('adds a build problem when no test executed: an empty run is never green', () {
      final messages = teamCityStatisticMessages(const {'mplatrol.total': 0}, const []);
      expect(
          messages.last,
          "##teamcity[buildProblem description='mplatrol executed no Patrol test (0 result(s), none passed or "
          "failed); the run is not verified.' identity='mplatrol-no-executed-tests']");
    });

    test('adds a build problem per leg whose tests only hit blockers: a blocked leg is never green', () {
      const android = ItRunLeg(tenant: 'acme', environment: 'QA', variant: 'lt-android');
      final messages = teamCityStatisticMessages(const {}, [
        _result('f', 'a', ItTestOutcome.pass),
        const ItTestResult(
            leg: android, file: 'f', description: 'b', outcome: ItTestOutcome.fail, lesson: TestLesson.loginErrorPage),
        const ItTestResult(leg: android, file: 'f', description: 'c', outcome: ItTestOutcome.notRun),
      ]);
      const problem = "##teamcity[buildProblem description='mplatrol acme QA lt-android: no test passed or "
          "failed (1 qa-env-failure, 1 not-run); the leg is not verified.' "
          "identity='mplatrol-unverified-acme-lt-android']";
      expect(messages, [problem]);
    });
  });
}
