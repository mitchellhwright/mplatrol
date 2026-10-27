import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:test/test.dart';

const _leg =
    ItRunLeg(tenant: 'acme', environment: 'Staging', variant: 'lt-ios', buildLabel: 'mplatrol 1.0 · app 1a2b3c4d');

ItTestResult _result({
  String description = 'reaches accounts',
  ItTestOutcome outcome = ItTestOutcome.pass,
  String? device,
  bool deviceInName = false,
  String? reason,
  bool selected = true,
}) =>
    ItTestResult(
      leg: _leg,
      file: 'patrol_login_test',
      description: description,
      outcome: outcome,
      device: device,
      deviceInName: deviceInName,
      reason: reason,
      selected: selected,
    );

void main() {
  group('ticketKeyIn', () {
    test('normalizes test case keys written with - or _', () {
      expect(ticketKeyIn('PROJ-TC-34713 relaunch'), 'PROJ-TC-34713');
      expect(ticketKeyIn('PROJ_TC_34730 after log out'), 'PROJ-TC-34730');
    });

    test('normalizes plain issue keys, also at the end of a description', () {
      expect(ticketKeyIn('PROJ-244739 relaunch'), 'PROJ-244739');
      expect(ticketKeyIn('probe delivery APP2-236957'), 'APP2-236957');
    });

    test('is null without a key', () {
      expect(ticketKeyIn('reaches the home screen after sign-in'), isNull);
      expect(ticketKeyIn('DEVICE 1234 settings'), isNull);
      expect(ticketKeyIn('lower-case proj-12 is not a key'), isNull);
    });
  });

  group('caseKeysIn', () {
    test('lists every test case key once, normalized, in order', () {
      expect(caseKeysIn('PROJ-TC-34713 PROJ_TC_7602 PROJ-TC-34713 PROJ-TC-7605 relaunch'),
          ['PROJ-TC-34713', 'PROJ-TC-7602', 'PROJ-TC-7605']);
    });

    test('leaves out plain issue keys and is empty without a key', () {
      expect(caseKeysIn('PROJ-244739 PROJ-TC-12345 sign in'), ['PROJ-TC-12345']);
      expect(caseKeysIn('sign in'), isEmpty);
    });

    test('an ItTestResult carries the keys as the test cases metadata', () {
      final result = _result(description: 'PROJ-TC-123 PROJ-TC-456 sign in');

      expect(result.caseKeys, ['PROJ-TC-123', 'PROJ-TC-456']);
      expect(result.metadata.where((entry) => entry.name == 'Test cases').single.value, 'PROJ-TC-123 PROJ-TC-456');
    });
  });

  group('safeReportUrl', () {
    test('drops the signed query string and fragment', () {
      expect(safeReportUrl(' https://r2.lambdatest.com/video.mp4?verify=secret&x=1 '),
          'https://r2.lambdatest.com/video.mp4');
      expect(safeReportUrl('https://host/log#token'), 'https://host/log');
      expect(safeReportUrl('https://host/devicelog'), 'https://host/devicelog');
    });

    test('is null for a blank value', () {
      expect(safeReportUrl(null), isNull);
      expect(safeReportUrl('  '), isNull);
    });
  });

  group('ItTestResult', () {
    test('names the test with its ticket key first, then the description', () {
      expect(_result(description: 'PROJ-TC-34713 Snapshot').name, 'PROJ-TC-34713 Snapshot');
      expect(_result(description: 'Faro probe PROJ-236957').name, 'PROJ-236957 Faro probe PROJ-236957');
      expect(_result().name, 'reaches accounts');
    });

    test('adds the device to the name only when the leg ran several devices', () {
      expect(_result(device: 'iPhone 17-26', deviceInName: true).name, 'reaches accounts [iPhone 17-26]');
      expect(_result(device: 'iPhone 17-26').name, 'reaches accounts');
      expect(_result(deviceInName: true).name, 'reaches accounts');
    });

    test('lists present metadata in order, links flagged and without signatures', () {
      const result = ItTestResult(
        leg: _leg,
        file: 'snapshot_deep_link_journey_test',
        description: 'PROJ-TC-34730 after log out',
        outcome: ItTestOutcome.fail,
        reason: 'Failed to resolve query',
        device: 'iPhone 13',
        os: 'iOS 26.6.2',
        ltSessionId: 'RMAA-IOS-1',
        videoUrl: 'https://r2/video.mp4?verify=abc',
        deviceLogUrl: 'https://api/devicelog',
        lesson: TestLesson.appProcessCrashed,
        flaky: true,
      );
      expect(result.metadata.map((entry) => entry.name), [
        'Outcome',
        'Category',
        'Reason',
        'Ticket',
        'Test cases',
        'Tenant',
        'Environment',
        'Variant',
        'Device',
        'OS',
        'Build label',
        'Test file',
        'LambdaTest session id',
        'LambdaTest session',
        'Video',
        'Device log',
        'TestLesson',
        'Flaky',
      ]);
      final byName = {for (final entry in result.metadata) entry.name: entry};
      expect(byName['Video']!.value, 'https://r2/video.mp4');
      expect(byName['Video']!.link, isTrue);
      expect(byName['LambdaTest session']!.value, 'https://appautomation.lambdatest.com/test?testID=RMAA-IOS-1');
      expect(byName['Category']!.value, 'app-defect');
      expect(byName['Outcome']!.link, isFalse);
    });

    test('omits absent metadata', () {
      const leg = ItRunLeg(tenant: 'demo', environment: 'QA', variant: 'android');
      final names = const ItTestResult(leg: leg, file: 'f', description: 'd', outcome: ItTestOutcome.pass)
          .metadata
          .map((entry) => entry.name);
      expect(names, ['Outcome', 'Category', 'Tenant', 'Environment', 'Variant', 'Test file']);
    });

    test('tells runtime skips and executed tests apart', () {
      expect(_result(outcome: ItTestOutcome.notRun, reason: '$itRuntimeSkipReason (x)').runtimeSkip, isTrue);
      expect(_result(outcome: ItTestOutcome.notRun, reason: 'infrastructure').runtimeSkip, isFalse);
      expect(_result(outcome: ItTestOutcome.notRun).runtimeSkip, isFalse);
      expect(_result(outcome: ItTestOutcome.fail, reason: itRuntimeSkipReason).runtimeSkip, isFalse);
      expect([for (final outcome in ItTestOutcome.values) _result(outcome: outcome).executed],
          [true, true, false, false, true]);
      expect(_result(selected: false).selected, isFalse);
    });
  });

  group('itDefectCounts', () {
    test('groups lesson-explained failures once, and unexplained ones per test, most occurrences first', () {
      const other = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android');
      ItTestResult failed(ItRunLeg leg, String description, {TestLesson? lesson}) =>
          ItTestResult(leg: leg, file: 'f', description: description, outcome: ItTestOutcome.fail, lesson: lesson);
      final counts = itDefectCounts([
        failed(_leg, 'a'),
        failed(other, 'a'),
        failed(_leg, 'b', lesson: TestLesson.appProcessCrashed),
        failed(other, 'c', lesson: TestLesson.appProcessCrashed),
        _result(),
        _result(outcome: ItTestOutcome.fail, reason: 'x', selected: false),
      ]);
      expect([
        for (final count in counts) '${count.defect}|${count.occurrences}|${count.tenants.join(',')}'
      ], [
        'appProcessCrashed|2|acme,globex',
        'test: a|2|acme,globex',
      ]);
    });
  });

  group('itResultCategory', () {
    ItResultCategory categoryOf(ItTestOutcome outcome,
            {TestLesson? lesson,
            ItResultCategory? cause,
            bool selected = true,
            String variant = 'lt-ios',
            bool detailMissing = false}) =>
        itResultCategory(outcome,
            lesson: lesson, cause: cause, selected: selected, variant: variant, detailMissing: detailMissing);

    test('a FAIL with no per-test detail is no-detail, not failed, unless a lesson or cause explains it', () {
      expect(categoryOf(ItTestOutcome.fail, detailMissing: true), ItResultCategory.noDetail);
      expect(ItResultCategory.noDetail.failed, isFalse);
      expect(ItResultCategory.noDetail.blocker, isFalse);
      expect(categoryOf(ItTestOutcome.fail, detailMissing: true, lesson: TestLesson.appProcessCrashed),
          ItResultCategory.appDefect);
      expect(categoryOf(ItTestOutcome.fail, detailMissing: true, cause: ItResultCategory.envFailure),
          ItResultCategory.envFailure);
    });

    test('a pass is pass and an unselected test not-selected, whatever explains them', () {
      expect(categoryOf(ItTestOutcome.pass, lesson: TestLesson.lambdaTestTunnel), ItResultCategory.pass);
      expect(categoryOf(ItTestOutcome.mocked), ItResultCategory.pass);
      expect(categoryOf(ItTestOutcome.notRun, selected: false, cause: ItResultCategory.credFailure),
          ItResultCategory.notSelected);
    });

    test('a FAIL is the category of its lesson, a test-failure without one, and the run cause first', () {
      expect(categoryOf(ItTestOutcome.fail), ItResultCategory.testFailure);
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.appProcessCrashed), ItResultCategory.appDefect);
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.lambdaTestTunnel), ItResultCategory.ltTunnelErr);
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.cocoaPodsSpecsOutdated), ItResultCategory.buildFailure);
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.credentials, cause: ItResultCategory.envFailure),
          ItResultCategory.envFailure);
    });

    test("a device failure is LambdaTest's on a LambdaTest variant and the device's locally", () {
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.proxy), ItResultCategory.ltFailure);
      expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.emulatorMemory, variant: 'android'),
          ItResultCategory.deviceFailure);
    });

    test("a LambdaTest failure stays LambdaTest's on a LambdaTest variant and is the device's locally", () {
      for (final variant in ['lt-android', 'lt-ios']) {
        expect(categoryOf(ItTestOutcome.fail, lesson: TestLesson.runtimeCredentialsUnreachable, variant: variant),
            ItResultCategory.ltTunnelErr);
        expect(categoryOf(ItTestOutcome.notRun, cause: ItResultCategory.ltFailure, variant: variant),
            ItResultCategory.ltFailure);
      }
      for (final variant in ['android', 'ios']) {
        for (final lesson in [
          TestLesson.runtimeCredentialsUnreachable,
          TestLesson.authPageScriptsBlocked,
          TestLesson.ipAllowlistBlocked,
          TestLesson.lambdaTestTunnel
        ]) {
          expect(categoryOf(ItTestOutcome.fail, lesson: lesson, variant: variant), ItResultCategory.deviceFailure,
              reason: '$variant $lesson');
        }
        expect(categoryOf(ItTestOutcome.notRun, cause: ItResultCategory.ltFailure, variant: variant),
            ItResultCategory.deviceFailure);
        expect(categoryOf(ItTestOutcome.notVerified, lesson: TestLesson.lambdaTestFrameworkSetup, variant: variant),
            ItResultCategory.deviceFailure);
        expect(categoryOf(ItTestOutcome.fail, cause: ItResultCategory.envFailure, variant: variant),
            ItResultCategory.envFailure);
      }
    });

    test('NOT RUN and NOT VERIFIED take a blocker category, never a failed one', () {
      expect(categoryOf(ItTestOutcome.notRun), ItResultCategory.notRun);
      expect(categoryOf(ItTestOutcome.notVerified), ItResultCategory.notVerified);
      expect(categoryOf(ItTestOutcome.notRun, lesson: TestLesson.lambdaTestFrameworkSetup), ItResultCategory.ltFailure);
      expect(categoryOf(ItTestOutcome.notRun, cause: ItResultCategory.credFailure), ItResultCategory.credFailure);
      expect(categoryOf(ItTestOutcome.notRun, lesson: TestLesson.appProcessCrashed), ItResultCategory.notRun);
      expect(categoryOf(ItTestOutcome.notVerified, lesson: TestLesson.locationAlert), ItResultCategory.notVerified);
    });

    test('names an environment failure after the environment', () {
      const leg = ItRunLeg(tenant: 'globex', environment: 'QA', variant: 'lt-android');
      const result = ItTestResult(
          leg: leg, file: 'f', description: 'd', outcome: ItTestOutcome.fail, lesson: TestLesson.loginErrorPage);
      expect([result.category, result.categoryName], [ItResultCategory.envFailure, 'qa-env-failure']);
    });

    test('itCategoryCounts counts by name in category order', () {
      const trin = ItRunLeg(tenant: 'globex', environment: 'QA', variant: 'lt-android');
      const staging = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android');
      expect(
          itCategoryCounts(const [
            ItTestResult(leg: trin, file: 'f', description: 'a', outcome: ItTestOutcome.notRun),
            ItTestResult(
                leg: staging,
                file: 'f',
                description: 'b',
                outcome: ItTestOutcome.fail,
                lesson: TestLesson.loginErrorPage),
            ItTestResult(leg: trin, file: 'f', description: 'c', outcome: ItTestOutcome.pass),
            ItTestResult(
                leg: trin, file: 'f', description: 'd', outcome: ItTestOutcome.fail, lesson: TestLesson.loginErrorPage),
          ]),
          {'pass': 1, 'staging-env-failure': 1, 'qa-env-failure': 1, 'not-run': 1});
      expect(itCategoryCounts(const []), isEmpty);
    });
  });

  test('ItTestOutcome labels and pass semantics', () {
    expect(ItTestOutcome.values.map((outcome) => outcome.label), ['PASS', 'FAIL', 'NOT RUN', 'NOT VERIFIED', 'MOCKED']);
    expect(ItTestOutcome.values.where((outcome) => outcome.passed), [ItTestOutcome.pass, ItTestOutcome.mocked]);
  });

  test('ItRunLeg suite name is stable for a tenant, environment and variant', () {
    expect(_leg.suiteName, 'mplatrol acme Staging lt-ios');
  });

  group('passedRunOutcome', () {
    test('is PASS without mock markers, even for a MOCKED test name', () {
      expect(passedRunOutcome('PATROL_RESULT name=PROJ-TC-23586 MOCKED Delete passed=true'),
          (outcome: ItTestOutcome.pass, reason: null));
    });

    test('is MOCKED when the run printed MPLATROL_MOCKED', () {
      expect(passedRunOutcome('MPLATROL_MOCKED scope=api mock=origin key=PROJ-TC-23586'),
          (outcome: ItTestOutcome.mocked, reason: null));
    });

    test('is NOT VERIFIED when a mocked run leaked, with or without detail', () {
      expect(passedRunOutcome('MPLATROL_MOCKED scope=api\nMPLATROL_MOCK_LEAK real login host hit\n'),
          (outcome: ItTestOutcome.notVerified, reason: 'mocked run leaked to a real service: real login host hit'));
      expect(passedRunOutcome('MPLATROL_MOCK_LEAK'),
          (outcome: ItTestOutcome.notVerified, reason: 'mocked run leaked to a real service'));
    });
  });
}
