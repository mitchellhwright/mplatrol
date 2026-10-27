import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _leg = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android');

const _login = ItSelectedTest(
  id: 'mplatrol.e2e.PatrolLoginTest/reaches_accounts',
  file: 'patrol_login_test',
  description: 'reaches accounts',
  aliases: ['patrol_login_test reaches accounts'],
);
const _rdc = ItSelectedTest(id: 'rdc', file: 'rdc_journey_test', description: 'enters an RDC amount');

ItTestResult _only(ItRunResults results) => results.results.single;

void main() {
  late ItRunResults results;

  setUp(() => results = ItRunResults());

  test('ignores records made outside a leg', () async {
    expect(results.recording, isFalse);
    results
      ..selectTests([_login])
      ..excludeTest(file: 'f', description: 'd', reason: 'r')
      ..session('s', const ItSessionDetails(testId: 'x'))
      ..verdict(ItTestOutcome.pass, testId: _login.id)
      ..unfinished(ItTestOutcome.notRun, 'x')
      ..buildReused();
    expect(results.sessionHasVerdict('s'), isFalse);
    await results.withDevice('Pixel 7-13', () async {});
    expect(results.results, isEmpty);
    expect(results.buildReuses, 0);
  });

  test('a selected test without a verdict is NOT RUN', () async {
    await results.withLeg(_leg, () async {
      expect(results.recording, isTrue);
      results.selectTests([_login]);
    }, device: 'emulator-5554');
    final result = _only(results);
    expect(result.outcome, ItTestOutcome.notRun);
    expect(result.reason, 'no result: the run ended before this test reported');
    expect(result.device, 'emulator-5554');
    expect(result.leg, same(_leg));
  });

  test('a test verdict, recorded by an alias, classifies its evidence', () async {
    await results.withLeg(_leg, () async {
      results
        ..selectTests([_login])
        ..verdict(ItTestOutcome.fail,
            testId: 'patrol_login_test reaches accounts',
            reason: 'NPE in plugin',
            evidence: 'E AndroidRuntime: FATAL EXCEPTION: main');
    });
    final result = _only(results);
    expect(result.outcome, ItTestOutcome.fail);
    expect(result.lesson, TestLesson.appProcessCrashed);
    expect(result.device, isNull);
  });

  test('a known app defect in the failure block makes the FAIL an app defect, with the block in every report',
      () async {
    const local = ItRunLeg(tenant: 'acme', environment: 'Staging', variant: 'android');
    const details = 'FATAL EXCEPTION: main (last\n'
        'state: account picker: 9 native labels)\n#0      DepositJourneyPage._waitForAccountLabels';
    await results.withLeg(local, () async {
      results
        ..selectTests([_rdc])
        ..verdict(ItTestOutcome.fail,
            testId: 'rdc',
            reason: 'FATAL EXCEPTION: main (last state: ...',
            evidence: 'FATAL EXCEPTION: main (last state: ...',
            details: details);
    }, device: 'emulator-5554');
    final result = _only(results);
    expect(result.lesson, TestLesson.appProcessCrashed);
    expect(result.categoryName, 'app-defect');
    expect(result.details, details);
    final summary = jsonDecode(renderCiSummary(results.results,
        (duration: Duration.zero, testResultsUrl: null, mplatrolVersion: '1.13.2', appVersion: 'dev'))) as Map;
    expect((summary['Tests'] as List).single,
        allOf(containsPair('category', 'app-defect'), containsPair('details', details)));
    expect(
        renderJUnitReport(results.results, timestamp: DateTime(2026, 10, 6)), contains('#0      DepositJourneyPage'));
  });

  test('ignores a verdict that names neither a test nor a session', () async {
    await results.withLeg(_leg, () async {
      results
        ..selectTests([_login])
        ..verdict(ItTestOutcome.pass);
    });
    expect(_only(results).outcome, ItTestOutcome.notRun);
  });

  group('no per-test detail and the ChatSdk crash', () {
    Future<ItTestResult> failWith({String? reason, String? evidence, String? details}) async {
      final run = ItRunResults();
      await run.withLeg(_leg, () async {
        run
          ..selectTests([_login])
          ..verdict(ItTestOutcome.fail, testId: _login.id, reason: reason, evidence: evidence, details: details);
      });
      return run.results.single;
    }

    test('a FAIL with no reason or only the generic Dart line and no message is no-detail', () async {
      for (final reason in [null, '  ', 'Dart test failed', 'Dart test failed: reaches accounts']) {
        final result = await failWith(reason: reason, evidence: 'Dart test failed\n');
        expect(result.category, ItResultCategory.noDetail, reason: '$reason');
        expect(result.category.failed, isFalse);
      }
    });

    test('a FAIL with a specific reason, failure details or a failure message in the evidence is a test-failure',
        () async {
      expect((await failWith(reason: 'Expected exactly 1 Dart test in group, found 0')).category,
          ItResultCategory.testFailure);
      expect((await failWith(reason: 'Dart test failed', details: 'at page.dart:5')).category,
          ItResultCategory.testFailure);
      expect((await failWith(reason: 'Dart test failed', evidence: 'Dart test failed\nExpected: true\n')).category,
          ItResultCategory.testFailure);
    });

    test('a provider-status FAIL carries no detail either', () async {
      final run = ItRunResults();
      await run.withLeg(_leg, () async {
        run
          ..selectTests([_login])
          ..session('s1', ItSessionDetails(testId: _login.id, providerStatus: 'failed'));
      });
      expect(run.results.single.category, ItResultCategory.noDetail);
    });

    test('a leg lesson explains a test that did not run, never one the run did not select', () async {
      final run = ItRunResults();
      await run.withLeg(_leg, () async {
        run
          ..selectTests([_login])
          ..excludeTest(file: 'f', description: 'sdk off', reason: 'SDK not built')
          ..observeLessons([TestLesson.appProcessCrashed]);
      });
      expect({for (final result in run.results) result.name: result.lesson},
          {'reaches accounts': TestLesson.appProcessCrashed, 'sdk off': null});
    });
  });

  group('LambdaTest sessions', () {
    Future<ItTestResult> sessionResult(String status) async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..session('s1', ItSessionDetails(testId: _login.id, providerStatus: status));
      });
      return _only(results);
    }

    test('an unverified provider pass is NOT VERIFIED', () async {
      final result = await sessionResult('passed');
      expect(result.outcome, ItTestOutcome.notVerified);
      expect(result.ltSessionId, 's1');
    });

    test('a provider skip is a runtime skip, never a pass', () async {
      final result = await sessionResult('skipped');
      expect(result.outcome, ItTestOutcome.notRun);
      expect(result.runtimeSkip, isTrue);
    });

    test('any other provider status is a FAIL', () async {
      final result = await sessionResult('idle_timeout');
      expect(result.outcome, ItTestOutcome.fail);
      expect(result.reason, 'LambdaTest session idle_timeout');
    });

    test('a bound session without status or verdict leaves the test NOT RUN', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..session('s1', ItSessionDetails(testId: _login.id));
      });
      expect(_only(results).outcome, ItTestOutcome.notRun);
    });

    test('merges details and a verdict recorded before the session was bound', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..session(
              's1',
              const ItSessionDetails(
                  providerStatus: 'failed',
                  duration: Duration(seconds: 38),
                  device: 'Pixel 7',
                  os: 'Android 13',
                  videoUrl: 'https://r2/video.mp4?verify=x',
                  deviceLogUrl: 'https://api/s1/log/devicelog'))
          ..verdict(ItTestOutcome.fail,
              sessionId: 's1', reason: 'timeout at https://bank.example/login?token=abc&x=1 then gave up');
        expect(results.sessionHasVerdict('s1'), isTrue);
        results.session('s1', ItSessionDetails(testId: _login.id, providerStatus: 'failed'));
      });
      final result = _only(results);
      expect(result.outcome, ItTestOutcome.fail);
      expect(result.reason, 'timeout at https://bank.example/login then gave up');
      expect(result.duration, const Duration(seconds: 38));
      expect(result.device, 'Pixel 7');
      expect(result.os, 'Android 13');
      expect(result.videoUrl, 'https://r2/video.mp4?verify=x');
      expect(result.deviceLogUrl, 'https://api/s1/log/devicelog');
      expect(result.ltSessionId, 's1');
    });

    test('a pass after a failed session is flaky; the passing session is reported', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..session('s1', ItSessionDetails(testId: _login.id, providerStatus: 'failed'))
          ..session('s2', ItSessionDetails(testId: _login.id, providerStatus: 'passed'))
          ..verdict(ItTestOutcome.mocked, sessionId: 's2')
          ..session('s2', ItSessionDetails(testId: _login.id));
      });
      final result = _only(results);
      expect(result.outcome, ItTestOutcome.mocked);
      expect(result.flaky, isTrue);
      expect(result.ltSessionId, 's2');
    });

    test('a failed verdict on a session counts towards flaky', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..verdict(ItTestOutcome.fail, testId: _login.id, sessionId: 's1')
          ..verdict(ItTestOutcome.pass, testId: _login.id, sessionId: 's2');
      });
      expect(_only(results).flaky, isTrue);
    });

    test('a session bound after a test verdict replaces that verdict', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login])
          ..verdict(ItTestOutcome.notRun, testId: _login.id, reason: 'never assigned')
          ..verdict(ItTestOutcome.pass, testId: _login.id, sessionId: 'retry');
      });
      expect(_only(results).outcome, ItTestOutcome.pass);
    });

    test('keepExisting leaves an earlier test or session verdict in place', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login, _rdc])
          ..verdict(ItTestOutcome.notRun, sessionId: 's1', testId: _login.id, reason: itRuntimeSkipReason)
          ..verdict(ItTestOutcome.fail, sessionId: 's1', reason: 'diagnosed', keepExisting: true)
          ..verdict(ItTestOutcome.notRun, testId: _rdc.id, reason: 'stalled')
          ..verdict(ItTestOutcome.fail, testId: _rdc.id, reason: 'late', keepExisting: true)
          ..verdict(ItTestOutcome.fail, sessionId: 'fresh', reason: 'kept', keepExisting: true);
        expect(results.sessionHasVerdict('fresh'), isTrue);
      });
      expect(results.results.map((result) => result.reason), [itRuntimeSkipReason, 'stalled']);
    });
  });

  test('excluded tests are NOT RUN and not selected', () async {
    await results.withLeg(_leg, () async {
      results.excludeTest(
          file: 'chatsdk_chat_journey_test', description: 'opens chat', reason: 'SDK not built: chatsdk');
    });
    final result = _only(results);
    expect(result.outcome, ItTestOutcome.notRun);
    expect(result.selected, isFalse);
    expect(result.reason, 'not selected: SDK not built: chatsdk');
    expect(result.file, 'chatsdk_chat_journey_test');
  });

  test('unfinished gives unresolved tests its verdict; the first one wins', () async {
    await results.withLeg(_leg, () async {
      results
        ..selectTests([_login, _rdc])
        ..verdict(ItTestOutcome.pass, testId: _rdc.id)
        ..unfinished(ItTestOutcome.notRun, 'stalled')
        ..unfinished(ItTestOutcome.notVerified, 'later');
    });
    expect(results.results.map((result) => (result.outcome, result.reason)),
        [(ItTestOutcome.notRun, 'stalled'), (ItTestOutcome.pass, null)]);
  });

  test('device jobs keep their own tests and add the device to names', () async {
    await results.withLeg(_leg, () async {
      await results.withDevice('Pixel 7-13', () async => results.selectTests([_login]));
      await results.withDevice('Galaxy S23-14', () async {
        results
          ..selectTests([_login])
          ..verdict(ItTestOutcome.pass, testId: _login.id);
      });
    });
    expect(results.results.map((result) => (result.name, result.outcome)), [
      ('reaches accounts [Pixel 7-13]', ItTestOutcome.notRun),
      ('reaches accounts [Galaxy S23-14]', ItTestOutcome.pass),
    ]);
  });

  test('a leg with one device job keeps plain names', () async {
    await results.withLeg(_leg, () async {
      await results.withDevice('Pixel 7-13', () async => results.selectTests([_login]));
    });
    expect(_only(results).name, 'reaches accounts');
    expect(_only(results).device, 'Pixel 7-13');
  });

  group('endLeg', () {
    test('changes nothing for a successful leg', () async {
      await results.withLeg(_leg, () async => results.selectTests([_login]));
      results.endLeg(_leg, exitCode: 0, planned: () => fail('not planned'));
      expect(_only(results).reason, 'no result: the run ended before this test reported');
    });

    test('reports the planned tests of a leg that failed before selecting any', () async {
      await results.withLeg(_leg, () async {}, device: 'emulator-5554');
      results.endLeg(_leg, exitCode: 70, planned: () => [_login, _rdc]);
      expect(results.results.map((result) => (result.outcome, result.reason, result.device)), [
        for (var i = 0; i < 2; i++)
          (ItTestOutcome.notRun, 'the lt-android run ended with exit 70 before this test reported', 'emulator-5554'),
      ]);
    });

    test('gives tests without a verdict the exit code as their reason', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login, _rdc])
          ..verdict(ItTestOutcome.fail, testId: _rdc.id);
      });
      results.endLeg(_leg, exitCode: 69, planned: () => fail('not planned'));
      expect(results.results.first.reason, 'the lt-android run ended with exit 69 before this test reported');
      expect(results.results.last.outcome, ItTestOutcome.fail);
    });
  });

  group('endUnstarted', () {
    test('records the planned tests of a leg that never ran', () {
      results.endUnstarted(_leg, exitCode: 66, planned: () => [_login]);
      expect(results.results.map((result) => (result.leg.variant, result.outcome)), [
        ('lt-android', ItTestOutcome.notRun),
      ]);
    });

    test('leaves a leg that ran, or a successful tenant, alone', () async {
      await results.withLeg(_leg, () async => results.selectTests([_login]));
      results
        ..endUnstarted(const ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android'),
            exitCode: 66, planned: () => fail('ran'))
        ..endUnstarted(const ItRunLeg(tenant: 'other', environment: 'Staging', variant: 'lt-android'),
            exitCode: 0, planned: () => fail('passed'));
      expect(results.results, hasLength(1));
    });
  });

  group('categories', () {
    test('a runner cause names the category of a verdict and of the tests a job never reported', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login, _rdc])
          ..verdict(ItTestOutcome.notRun,
              testId: _login.id, reason: 'never assigned', cause: ItResultCategory.ltFailure)
          ..unfinished(ItTestOutcome.notRun, 'stalled', cause: ItResultCategory.ltFailure);
      });
      expect([for (final result in results.results) (result.reason, result.categoryName)],
          [('never assigned', 'lt-failure'), ('stalled', 'lt-failure')]);
    });

    test('lessons seen in a leg explain its NOT RUN tests, never a FAIL or a test with its own lesson', () async {
      const tunnel = ItSelectedTest(id: 'tunnel', file: 'f', description: 'tunnel');
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login, _rdc, tunnel])
          ..verdict(ItTestOutcome.fail, testId: _rdc.id, reason: 'expected 1')
          ..verdict(ItTestOutcome.notRun, testId: tunnel.id, evidence: 'ERR::TUN::1')
          ..observeLessons({TestLesson.cocoaPodsSpecsOutdated});
      });
      results.endLeg(_leg, exitCode: 70, planned: () => fail('selected'));
      expect([
        for (final result in results.results) (result.lesson, result.categoryName)
      ], [
        (TestLesson.cocoaPodsSpecsOutdated, 'build-failure'),
        (null, 'test-failure'),
        (TestLesson.lambdaTestTunnel, 'lt-tunnel-err'),
      ]);
    });

    test('an e2e bundle that fails to build makes every planned test build-failure, not not-run', () async {
      await results.withLeg(_leg, () async {
        results.observeLessons({TestLesson.e2eImportsOptionalPackage});
      });
      results.endLeg(_leg, exitCode: 1, planned: () => [_login, _rdc]);
      expect([
        for (final result in results.results) (result.lesson, result.categoryName)
      ], [
        (TestLesson.e2eImportsOptionalPackage, 'build-failure'),
        (TestLesson.e2eImportsOptionalPackage, 'build-failure'),
      ]);
    });

    test('a test that skipped itself stays NOT RUN when another test of the leg shows a lesson', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([_login, _rdc])
          ..verdict(ItTestOutcome.notRun, testId: _rdc.id, reason: '$itRuntimeSkipReason (assumption)')
          ..observeLessons({TestLesson.patrolClientTimeout});
      });
      results.endLeg(_leg, exitCode: 70, planned: () => fail('selected'));
      final skipped = results.results.firstWhere((result) => result.reason?.startsWith(itRuntimeSkipReason) ?? false);
      expect((skipped.lesson, skipped.categoryName), (null, 'not-run'));
    });

    test('lessons outside any tenant or leg are dropped', () {
      results
        ..observeLessons({TestLesson.lambdaTestTunnel})
        ..blockTenant(ItResultCategory.credFailure, 'no login');
      results.endUnstarted(_leg, exitCode: 78, planned: () => [_login]);
      expect(_only(results).categoryName, 'not-run');
    });

    test('blockTenant names the planned tests of the tenant legs that never started', () async {
      await results.withTenant('globex', 'Staging', () async {
        results
          ..observeLessons({TestLesson.lambdaTestTunnel})
          ..blockTenant(ItResultCategory.credFailure, 'no verified credentials for globex/Staging');
      });
      results.endUnstarted(_leg, exitCode: 78, planned: () => [_login, _rdc]);
      expect([
        for (final result in results.results) (result.outcome, result.reason, result.categoryName)
      ], [
        for (var i = 0; i < 2; i++)
          (ItTestOutcome.notRun, 'no verified credentials for globex/Staging', 'cred-failure'),
      ]);
    });

    test('lessons seen while a tenant prepared name its legs that never started', () async {
      await results.withTenant(
          'globex', 'Staging', () async => results.observeLessons({TestLesson.cocoaPodsSpecsOutdated}));
      results
        ..endUnstarted(_leg, exitCode: 70, planned: () => [_login])
        ..endUnstarted(const ItRunLeg(tenant: 'other', environment: 'Staging', variant: 'lt-ios'),
            exitCode: 70, planned: () => [_rdc]);
      expect([
        for (final result in results.results) (result.reason, result.categoryName)
      ], [
        ('the lt-android run ended with exit 70 before this test reported', 'build-failure'),
        ('the lt-ios run ended with exit 70 before this test reported', 'not-run'),
      ]);
    });

    test('lessons seen in a leg stay with that leg, not its tenant', () async {
      await results.withTenant('globex', 'Staging', () async {
        await results.withLeg(_leg, () async {
          results
            ..selectTests([_login])
            ..observeLessons({TestLesson.lambdaTestCapacity});
        });
      });
      results.endUnstarted(const ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-ios'),
          exitCode: 70, planned: () => [_rdc]);
      expect([for (final result in results.results) result.categoryName], ['lt-failure', 'not-run']);
    });
  });

  group('infrastructure retry', () {
    ItSelectedTest selected(String id) => ItSelectedTest(id: id, file: 'f', description: id);

    test('only LambdaTest infrastructure failures are retryable', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([
            for (final id in ['tunnel', 'lt', 'setup', 'cred', 'env', 'data', 'build', 'fail', 'pass']) selected(id),
          ])
          ..excludeTest(file: 'f', description: 'unbuilt', reason: 'SDK not built')
          ..verdict(ItTestOutcome.fail, testId: 'tunnel', evidence: 'ERR::TUN::1')
          ..verdict(ItTestOutcome.notRun, testId: 'lt', cause: ItResultCategory.ltFailure)
          ..verdict(ItTestOutcome.notRun, testId: 'cred', cause: ItResultCategory.credFailure)
          ..verdict(ItTestOutcome.notRun, testId: 'env', cause: ItResultCategory.envFailure)
          ..verdict(ItTestOutcome.notRun, testId: 'data', cause: ItResultCategory.testDataFailure)
          ..verdict(ItTestOutcome.notRun, testId: 'build', cause: ItResultCategory.buildFailure)
          ..verdict(ItTestOutcome.fail, testId: 'fail', reason: 'Expected: true')
          ..verdict(ItTestOutcome.pass, testId: 'pass')
          ..observeLessons([TestLesson.lambdaTestFrameworkSetup]);
        expect(results.retryableTests(), ['tunnel', 'lt', 'setup']);
      });
    });

    test('the retry alone decides a retried test, and a test is retried only once', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([selected('a'), selected('b')])
          ..session('s1', const ItSessionDetails(testId: 'a', providerStatus: 'failed'))
          ..verdict(ItTestOutcome.fail, sessionId: 's1', evidence: 'ERR::TUN::1')
          ..verdict(ItTestOutcome.pass, testId: 'b');
        expect(results.beginRetry(['a', 'unknown']), {
          'a': 'retried after lt-tunnel-err (lesson lambdaTestTunnel); first attempt FAIL [LambdaTest session s1]',
        });
        results
          ..session('s2', const ItSessionDetails(testId: 'a', providerStatus: 'failed'))
          ..verdict(ItTestOutcome.fail, sessionId: 's2', evidence: 'ERR::TUN::1')
          ..verdict(ItTestOutcome.pass, sessionId: 's1');
        expect(results.retryableTests(), isEmpty);
      });
      final a = results.results.first;
      expect([a.outcome, a.categoryName, a.ltSessionId, a.flaky], [ItTestOutcome.fail, 'lt-tunnel-err', 's2', false]);
      expect(a.retriedAfter, startsWith('retried after lt-tunnel-err'));
      expect(a.metadata.singleWhere((entry) => entry.name == 'Retried').value, a.retriedAfter);
      expect(results.results.last.retriedAfter, isNull);
    });

    test('a first-attempt stall or leg lesson never explains a retried test the retry did not reach', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([selected('a'), selected('b')])
          ..unfinished(ItTestOutcome.notRun, 'stalled', cause: ItResultCategory.ltFailure)
          ..observeLessons([TestLesson.lambdaTestFrameworkSetup])
          ..beginRetry(['a']);
      });
      final [a, b] = results.results;
      expect([a.outcome, a.reason, a.categoryName, a.lesson],
          [ItTestOutcome.notRun, 'no result: the retry ended before this test reported', 'not-run', null]);
      expect(a.retriedAfter, 'retried after lt-failure; first attempt NOT RUN: stalled');
      expect([b.reason, b.categoryName], ['stalled', 'lt-failure']);
    });

    test('what the retry itself observes explains its retried tests', () async {
      await results.withLeg(_leg, () async {
        results
          ..selectTests([selected('a'), selected('b')])
          ..verdict(ItTestOutcome.notRun, testId: 'a', cause: ItResultCategory.ltFailure)
          ..verdict(ItTestOutcome.notRun, testId: 'b', cause: ItResultCategory.ltFailure)
          ..beginRetry(['a', 'b'])
          ..observeLessons([TestLesson.lambdaTestTunnel])
          ..verdict(ItTestOutcome.notRun, testId: 'b', reason: 'never assigned')
          ..unfinished(ItTestOutcome.notRun, 'retry stalled', cause: ItResultCategory.ltFailure);
      });
      final [a, b] = results.results;
      expect([a.reason, a.categoryName], ['retry stalled', 'lt-failure']);
      expect([b.reason, b.categoryName, b.lesson], ['never assigned', 'lt-tunnel-err', TestLesson.lambdaTestTunnel]);
    });

    test('a local leg has no LambdaTest failure to retry: its connection failures are device-failure', () async {
      for (final variant in ['android', 'ios']) {
        final run = ItRunResults();
        await run.withLeg(ItRunLeg(tenant: 'globex', environment: 'Staging', variant: variant), () async {
          run
            ..selectTests([selected('a')])
            ..verdict(ItTestOutcome.fail,
                testId: 'a', evidence: 'Could not read runtime E2E credentials from the runner: TimeoutException');
          expect(run.retryableTests(), isEmpty);
        }, device: 'local-device');
        expect([run.results.single.lesson, run.results.single.categoryName],
            [TestLesson.runtimeCredentialsUnreachable, 'device-failure']);
      }
    });

    test('outside a leg nothing is retryable or retried', () {
      expect(results.retryableTests(), isEmpty);
      expect(results.currentDeviceResults(), isEmpty);
      expect(results.beginRetry(['a']), isEmpty);
    });
  });

  test('counts build reuses only inside a leg, and reports results per leg', () async {
    const other = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-ios');
    await results.withLeg(_leg, () async {
      results
        ..buildReused()
        ..selectTests([_login]);
    });
    await results.withLeg(other, () async => results.selectTests([_rdc]));
    expect(results.buildReuses, 1);
    expect(results.resultsOf(other).single.file, 'rdc_journey_test');
    expect(results.resultsOf(const ItRunLeg(tenant: 'x', environment: 'y', variant: 'z')), isEmpty);
  });

  test('plannedPatrolTests lists the selected tests under their Dart names', () {
    final repo = Directory.systemTemp.createTempSync('planned_');
    addTearDown(() => repo.deleteSync(recursive: true));
    File(p.join(repo.path, 'patrol_test', 'patrol_login_test.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("void main() { patrolTest('reaches accounts', (\$) async {}); }\n");
    final planned = plannedPatrolTests(repo.path);
    expect(planned.map((test) => (test.id, test.file, test.description)),
        [('patrol_login_test reaches accounts', 'patrol_login_test', 'reaches accounts')]);
  });
}
