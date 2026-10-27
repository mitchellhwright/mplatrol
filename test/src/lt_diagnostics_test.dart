// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

void main() {
  late LtHttp ltHttp;
  late MplatrolLogger logger;

  const env = {'LT_USERNAME': 'u', 'LT_ACCESS_KEY': 'k'};

  setUp(() async {
    await scaffoldMockDependencies();
    ltHttp = getDep<LtHttp>();
    logger = getDep<MplatrolLogger>();
  });

  LtDiagnostics diagnostics() => LtDiagnostics(logRetryDelay: Duration.zero);

  /// Stub the session fetch (returns [sessionBody]), the network-log fetch
  /// (→ [networkBody]), and the XML report fetch (→ [reportBody], empty by
  /// default so the per-test breakdown is skipped).
  void stubGet({
    required String sessionBody,
    String networkBody = '[]',
    String reportBody = '',
    String instrumentationBody = '',
    int instrumentationStatus = 200,
  }) {
    when(
      () => ltHttp.get(
        any(that: contains('sessions?build_id')),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => http.Response(sessionBody, 200));
    when(
      () => ltHttp.get(
        any(that: contains('/network')),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => http.Response(networkBody, 200));
    when(
      () => ltHttp.get(
        any(that: contains('/report')),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => http.Response(reportBody, 200));
    when(
      () => ltHttp.get(
        any(that: contains('/log/instrumentation')),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer(
      (_) async => http.Response(instrumentationBody, instrumentationStatus),
    );
  }

  String session({
    String status = 'timeout',
    String? networkLogs = 'https://lt/log/network',
    String videoUrl = 'v',
    String deviceLogs = 'd',
  }) =>
      '{"data":[{"status_ind":"$status","device":"iPhone 17 Pro",'
      '"version":"26.0","duration":"540","video_url":"$videoUrl",'
      '"session_id":"session-1","build_id":28547361,'
      '"device_logs":"$deviceLogs","network_logs":'
      '${networkLogs == null ? 'null' : '"$networkLogs"'}}]}';

  group('LtDiagnostics CI verdicts', () {
    const leg = ItRunLeg(tenant: 'acme', environment: 'Staging', variant: 'lt-ios');

    Future<ItTestResult> diagnose(String status, String instrumentation,
        {String sessionId = 'session-1', String duration = '540', String platform = 'iOS'}) async {
      stubGet(
          sessionBody: session(status: status)
              .replaceFirst('session-1', sessionId)
              .replaceFirst('"duration":"540"', '"duration":"$duration"'),
          instrumentationBody: instrumentation);
      final results = getDep<ItRunResults>();
      await results.withLeg(leg, () async {
        results.selectTests([const ItSelectedTest(id: 'm', file: 'f', description: 'd')]);
        await diagnostics().report(buildId: 'b', platform: platform, env: const {...env, 'E2E_PASSWORD': 'hunter22'});
        results.session(sessionId, const ItSessionDetails(testId: 'm'));
      });
      return results.resultsOf(leg).single;
    }

    test('a diagnosed failure is a FAIL with its redacted summary and lesson', () async {
      final result = await diagnose(
          'failed',
          'PATROL_RESULT name=x attempt=1 passed=false details=DepositSdk crash '
              'hunter22 at com.depositsdk.rdcframework.model.DepositModel.<init>');
      expect(result.outcome, ItTestOutcome.fail);
      expect(result.reason, 'DepositSdk crash <redacted> at com.depositsdk.rdcframework.model.DepositModel.<init>');
    });

    test('a session that skipped at runtime is NOT RUN', () async {
      final result = await diagnose(
          'failed',
          'MPLATROL_TEST_SKIPPED coordinator shard method=m NOT RUN: Dart test '
              'skipped at runtime');
      expect(result.outcome, ItTestOutcome.notRun);
      expect(result.runtimeSkip, isTrue);
    });

    test('a session that never reached the coordinator is NOT RUN (infrastructure)', () async {
      final result = await diagnose('failed', 'PATROL_SHARD_NOT_RUN iOS shard coordinator unreachable');
      expect(result.outcome, ItTestOutcome.notRun);
      expect(result.reason, startsWith('NOT RUN (infrastructure): this shard never received a test'));
      expect(result.lesson?.name, 'iosShardCoordinatorUnreachable');
    });

    // Regression: r11 wayne PROJ-TC-7760 ended in 2 s, before any Dart test, and counted as test-failure.
    test('an iOS session that ended in seconds with no Dart output is lt-failure, not a test failure', () async {
      final result = await diagnose('failed', 'XCTestOutputBarrier launching Runner\nRunner was killed', duration: '2');
      expect(result.outcome, ItTestOutcome.notRun);
      expect(result.category, ItResultCategory.ltFailure);
      expect(result.reason, startsWith('$ltNoDartTestReason after 2s with no failure marker'));
    });

    for (final (name, instrumentation, duration, platform) in [
      ('a longer session', 'Runner was killed', '$ltNoDartTestMaxSeconds', 'iOS'),
      ('a session with a Patrol phase', 'PATROL_PHASE phase=run.runDartTest', '2', 'iOS'),
      ('a session with an XCTest error', 'Runner.swift:12: error: launch failed', '2', 'iOS'),
      ('an Android session', 'Runner was killed', '2', 'Android'),
    ]) {
      test('$name without a failure marker stays a test failure', () async {
        final result = await diagnose('failed', instrumentation, duration: duration, platform: platform);
        expect(result.category, ItResultCategory.testFailure);
      });
    }

    test('a session that skipped at runtime is labelled not-run, not failure, in the leg log', () async {
      await diagnose(
          'failed',
          'PATROL_RESULT name=x attempt=1 passed=false details=MOCK_TENANT_MISMATCH x\n'
              'MPLATROL_TEST_SKIPPED coordinator shard method=m NOT RUN: MOCK_TENANT_MISMATCH x');
      verify(() => logger.err(any(that: startsWith('not-run: ')))).called(1);
      verifyNever(() => logger.err(any(that: startsWith('failure: '))));
    });

    test('a passed session records nothing', () async {
      expect((await diagnose('passed', 'x')).outcome, ItTestOutcome.notRun);
    });

    test('an unidentified session records nothing', () async {
      expect(
          (await diagnose('failed', 'x', sessionId: '')).reason, 'no result: the run ended before this test reported');
    });
  });

  group('LtDiagnostics.report', () {
    test('links the App Automation test page of a diagnosed session; none without a session id', () async {
      stubGet(sessionBody: session(status: 'failed'));
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      verify(() => logger.info('test page:   https://appautomation.lambdatest.com/test?build=28547361'
          '&testID=session-1&selectedTab=logs (video, screenshots, device and network logs for this test)')).called(1);

      clearInteractions(logger);
      stubGet(sessionBody: '{"data":[{"status_ind":"failed","device":"Pixel 9"}]}');
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      verifyNever(() => logger.info(any(that: startsWith('test page:'))));
    });

    test('reports instrumentation transport errors without hiding the session', () async {
      stubGet(sessionBody: session(status: 'failed'));
      when(() => ltHttp.get(any(that: contains('/log/instrumentation')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'))).thenThrow(const SocketException('private transport detail'));
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      verify(() => logger.err(any(that: contains('native instrumentation fetch failed')))).called(1);
      verifyNever(() => logger.warn(any(that: contains('private transport detail'))));
      verify(() => logger.info('video:       v')).called(1);
    });

    test('an unreadable history preserves the original remedy and reports the save failure', () async {
      final repo = Directory.systemTemp.createTempSync('lt_invalid_history');
      addTearDown(() => repo.deleteSync(recursive: true));
      when(() => getDep<FileSystem>().getAppDirectory()).thenReturn(repo);
      final history = TestLessonHistory(repo.path);
      history.file.parent.createSync(recursive: true);
      history.file.writeAsStringSync('{}');
      stubGet(sessionBody: session(status: 'failed'), instrumentationBody: 'Bad state: InvalidCredentials timed out');
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      verify(() => logger.warn(any(that: contains('Could not save mplatrol lesson history')))).called(1);
      verify(() => logger.info(any(that: contains('lesson credentials')))).called(1);
      expect(history.file.readAsStringSync(), '{}');
    });

    test('persists a recurring failure category without retaining raw evidence', () async {
      final repo = Directory.systemTemp.createTempSync('lt_lesson_history');
      addTearDown(() => repo.deleteSync(recursive: true));
      when(() => getDep<FileSystem>().getAppDirectory()).thenReturn(repo);
      stubGet(
          sessionBody: session(status: 'failed'),
          instrumentationBody: 'Bad state: InvalidCredentials private-credential');
      for (var run = 0; run < 2; run++) {
        await diagnostics()
            .report(buildId: '1', platform: 'Android', env: {...env, 'E2E_PASSWORD': 'private-credential'});
      }
      final history = TestLessonHistory(repo.path);
      expect(history.read()[TestLesson.credentials], 2);
      expect(history.file.readAsStringSync(), isNot(contains('private-credential')));
      expect(File('${repo.path}/.mplatrol/.gitignore').readAsStringSync(), '*\n');
    });

    test('retries a log that has not been published yet', () async {
      stubGet(sessionBody: session(status: 'failed'));
      var reads = 0;
      when(() =>
          ltHttp.get(any(that: contains('/log/instrumentation')),
              headers: any(named: 'headers'), timeout: any(named: 'timeout'))).thenAnswer(
          (_) async => ++reads < 3 ? http.Response('', 404) : http.Response('Bad state: operators are offline', 200));
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      expect(reads, 3);
      verify(() => logger.err('failure: Bad state: operators are offline')).called(1);
    });

    for (final status in [404, 429, 503]) {
      test('warns after three unpublished HTTP $status instrumentation reads', () async {
        stubGet(sessionBody: session(status: 'failed'), instrumentationStatus: status);
        await diagnostics().report(buildId: '1', platform: 'Android', env: env);
        verify(() => ltHttp.get(any(that: contains('/log/instrumentation')),
            headers: any(named: 'headers'), timeout: any(named: 'timeout'))).called(3);
        verify(() => logger.warn(any(that: contains('Instrumentation log not published after three')))).called(1);
        verifyNever(() => logger.err(any(that: contains('no failure marker found'))));
      });
    }

    test('redacts only secret-keyed values long enough to be distinctive', () async {
      stubGet(
          sessionBody: session(status: 'failed'),
          instrumentationBody: 'The following PatrolActionException was thrown running a test:\n'
              'app package name is invalid for tenant-identifier\n'
              'When the exception was thrown, this was the stack:\n#0 openApp');
      await diagnostics().report(buildId: '1', platform: 'Android', env: {
        ...env,
        'E2E_MFA_CODE': 'name',
        'E2E_PASSWORD': 'tenant-identifier',
        'E2E_TENANT_INSTANCE_ID': 'invalid',
      });
      verify(() => logger.err('failure: app package name is invalid for <redacted>')).called(1);
    });

    test('does not retry unauthorized instrumentation access', () async {
      stubGet(sessionBody: session(status: 'failed'));
      when(() => ltHttp.get(any(that: contains('/log/instrumentation')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'))).thenAnswer((_) async => http.Response('', 401));
      await diagnostics().report(buildId: '1', platform: 'Android', env: env);
      verify(() => ltHttp.get(any(that: contains('/log/instrumentation')),
          headers: any(named: 'headers'), timeout: any(named: 'timeout'))).called(1);
      verify(() => logger.err(any(that: contains('HTTP 401 for session')))).called(1);
    });

    test('reports the Patrol failure before generic JUnit and redacts secrets', () async {
      stubGet(
          sessionBody: session(status: 'failed'),
          instrumentationBody: 'The following PatrolActionException was thrown running a test:\n'
              'app package name is invalid private-password\n'
              'When the exception was thrown, this was the stack:\n'
              '#0 openApp\nINSTRUMENTATION_STATUS: stack=java.lang.AssertionError');
      await diagnostics().report(
          buildId: '1',
          platform: 'Android',
          env: {...env, 'LT_ACCESS_KEY': 'long-access-key', 'E2E_PASSWORD': 'private-password'});
      verify(() => logger.err('failure: app package name is invalid <redacted>')).called(1);
      verify(() => logger.info(any(that: contains('lesson appPackage')))).called(1);
      verifyNever(() => logger.err(any(that: contains('private-password'))));
    });

    test('prints the session info and a no-egress reason when all requests fail', () async {
      stubGet(sessionBody: session(), networkBody: '[{"response":{"status":0}},{"response":{"status":0}}]');

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.info(any(that: contains('iPhone 17 Pro')))).called(1);
      verify(() => logger.info(any(that: contains('0/2 requests completed')))).called(1);
      verify(() => logger.err(any(that: contains('no network egress')))).called(1);
    });

    test('counts completed requests via response.status and the status fallback', () async {
      stubGet(
        sessionBody: session(status: 'idle_timeout'),
        // response.status>0, a non-map entry (skipped), and a top-level status.
        networkBody: '[{"response":{"status":200}},5,{"status":201}]',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.info(any(that: contains('2/3 requests completed')))).called(1);
      verify(() => logger.err(any(that: contains('did not finish')))).called(1);
    });

    test('reads JSON-lines instrumentation as the runner output it carries', () async {
      String record(String chunk) => '{"fields.msg":${jsonEncode(chunk)},"level":"info",'
          '"msg":"outputReceived:fromProcess:atTime:","pid":9645}';
      stubGet(
        sessionBody: session(status: 'failed'),
        instrumentationBody: [
          record('PATROL_PHASE phase=run.runDartTest\n'),
          record('PATROL_RESULT name=a attempt=1 passed=false details=boom\n'),
        ].join('\n'),
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err('native phase: run.runDartTest (session session-1)')).called(1);
      verify(() => logger.err('failure: boom')).called(1);
    });

    test('reports queue timeout when the device was not allocated', () async {
      stubGet(sessionBody: session(status: 'queue_timeout', networkLogs: null));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('not allocated')))).called(1);
    });

    test('reports an assertion failure for a failed status', () async {
      stubGet(sessionBody: session(status: 'failed', networkLogs: null));

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verify(() => logger.err(any(that: contains('failed')))).called(1);
    });

    for (final marker in ['PATROL_SHARD_NOT_RUN', 'PATROL_SELECTION_COORDINATOR_FAILED']) {
      test('reports a shard that never reached the coordinator ($marker) as NOT RUN', () async {
        stubGet(
          sessionBody: session(status: 'failed', networkLogs: null),
          instrumentationBody: '$marker attempts=12 request failed: NSURLErrorDomain Code=-1004',
        );

        await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

        verify(() => logger.err(any(that: contains('likely reason: NOT RUN (infrastructure)')))).called(1);
        verifyNever(() => logger.err(any(that: contains('the test ran and failed'))));
      });
    }

    test('selects a failed session over an earlier passed session', () async {
      stubGet(
        sessionBody: '{"data":['
            '{"status_ind":"passed","device":"iPhone 17 Pro",'
            '"version":"26.0","duration":"21","video_url":"passed-video",'
            '"session_id":"session-passed","device_logs":"passed-device",'
            '"network_logs":null},'
            '{"status_ind":"failed","device":"Galaxy S23",'
            '"version":"13","duration":"45","video_url":"failed-video",'
            '"session_id":"session-failed","device_logs":"failed-device",'
            '"network_logs":null}'
            ']}',
        instrumentationBody: 'Bad state: fixture failure',
      );

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verify(() => logger.info(any(that: contains('Galaxy S23')))).called(1);
      verify(
        () => ltHttp.get(
          any(that: contains('/sessions/session-failed/log/instrumentation')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
      verifyNever(
        () => ltHttp.get(
          any(that: contains('/sessions/session-passed/log/instrumentation')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      );
    });

    test('diagnoses every failed session of the build, not only the first', () async {
      stubGet(
        sessionBody: '{"data":['
            '{"status_ind":"failed","device":"iPhone 16 Pro","session_id":"YAC","network_logs":null},'
            '{"status_ind":"passed","device":"iPhone 15","session_id":"OK1","network_logs":null},'
            '{"status_ind":"failed","device":"iPhone 15 Pro","session_id":"ZCI","network_logs":null}'
            ']}',
      );
      for (final (id, body) in [
        ('YAC', 'MPLATROL_TEST_SKIPPED coordinator shard method=testBSpanish NOT RUN: Dart test skipped at runtime'),
        ('ZCI', 'PATROL_RESULT name=depositsdk attempt=1 passed=false details=Patrol direct client error: timed out'),
      ]) {
        when(() => ltHttp.get(any(that: contains('/sessions/$id/log/instrumentation')),
            headers: any(named: 'headers'),
            timeout: any(named: 'timeout'))).thenAnswer((_) async => http.Response(body, 200));
      }

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.info('── session 1/2: YAC ──')).called(1);
      verify(() => logger.info('── session 2/2: ZCI ──')).called(1);
      verify(() => logger.err(any(
          that: startsWith('likely reason: NOT RUN (skipped at runtime: '
              'Dart test skipped at runtime, testBSpanish)')))).called(1);
      verify(() => logger.err(any(that: contains('likely reason: the test ran and failed')))).called(1);
      verifyNever(() => ltHttp.get(any(that: contains('/sessions/OK1/')),
          headers: any(named: 'headers'), timeout: any(named: 'timeout')));
    });

    test('diagnoses the first session when none failed, without a session header', () async {
      stubGet(
          sessionBody: '{"data":[{"status_ind":"passed","device":"Pixel 9","session_id":"p-1"},'
              '{"status_ind":"passed","device":"Pixel 8","session_id":"p-2"}]}');

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verify(() => logger.info(any(that: contains('device: Pixel 9')))).called(1);
      verifyNever(() => logger.info(any(that: contains('device: Pixel 8'))));
      verifyNever(() => logger.info(any(that: startsWith('── session'))));
    });

    for (final (evidence, reason) in [
      (
        'flutter: MPLATROL_TEST_SKIPPED SNAPSHOT_BIOMETRIC_DEEPLINK_UNAVAILABLE no_enrolled_biometrics\n'
            'MPLATROL_TEST_SKIPPED coordinator shard method=testBBio NOT RUN: Dart test skipped at runtime',
        'SNAPSHOT_BIOMETRIC_DEEPLINK_UNAVAILABLE no_enrolled_biometrics'
      ),
      (
        'MPLATROL_TEST_SKIPPED coordinator shard method=testBBio NOT RUN: Dart test skipped at runtime',
        'Dart test skipped at runtime, testBBio'
      ),
      (
        'INSTRUMENTATION_STATUS: stack=org.junit.AssumptionViolatedException: Dart test skipped at runtime',
        'Dart test skipped at runtime'
      ),
    ]) {
      test('describes a runtime skip as NOT RUN with its reason: $reason', () async {
        stubGet(sessionBody: session(status: 'failed', networkLogs: null), instrumentationBody: evidence);

        await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

        verify(() => logger.err('likely reason: NOT RUN (skipped at runtime: $reason): the test skipped '
            'itself, so it neither passed nor failed. The device log has its MPLATROL_TEST_SKIPPED reason.')).called(1);
        verifyNever(() => logger.err(any(that: contains('the test ran and failed'))));
      });
    }

    test('prints the failed instrumentation exception summary', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: '''
INSTRUMENTATION_STATUS: stack=java.lang.AssertionError: Dart test failed
The following StateError was thrown running a test:
Bad state: Could not read runtime E2E credentials
(url=http://localhost.lambdatest.com:49782/e2e-credentials,
asset=loaded): SocketException: Connection refused
When the exception was thrown, this was the stack:
''',
      );

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verify(
        () => logger.err(
          any(
            that: contains(
              'failure: Bad state: Could not read runtime E2E '
              'credentials',
            ),
          ),
        ),
      ).called(1);
    });

    test('prints an assertion stack when there is no Dart bad-state block', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: 'INSTRUMENTATION_STATUS: stack=java.lang.AssertionError: failed',
      );

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verify(() => logger.err(any(that: contains('failure: java.lang.AssertionError: failed')))).called(1);
    });

    test('prints the real iOS Patrol timeout and post-auth source frame in quiet errors', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: '''
PATROL_PHASE phase=run.runDartTest deadlineSeconds=180.0
PATROL_RESULT name=SDK test passed=false details=TimeoutException after 20s: Future not completed
#0 Future.timeout (dart:async/future_impl.dart:1042)
<asynchronous suspension>
#1 VideosdkNativeSdkPage._waitForWebViewBridge (videosdk_native_sdk_page.dart:497)
RunnerUITests.swift:796: error: native Dart test failed
''',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(any(that: contains('native phase: run.runDartTest'))),
      ).called(1);
      verify(
        () => logger.err(
          any(
            that: allOf(
              contains('failure: TimeoutException'),
              contains('videosdk_native_sdk_page.dart:497'),
            ),
          ),
        ),
      ).called(1);
    });

    test('prints native XCTest failures without a Dart result', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: 'RunnerUITests.swift:533: error: stale alert index 2\n#0 native frame',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(
          any(that: contains('failure: RunnerUITests.swift:533: error:')),
        ),
      ).called(1);
    });

    test('reports warning metadata without plaintext credentials or headers', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: 'warning: username=protected-user password=protected-password '
            'Authorization: Basic protected-header '
            'https://example.test/log?verify=protected-signature',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(any(that: contains('native warnings present: 1 line(s)'))),
      ).called(1);
      verifyNever(() => logger.err(any(that: contains('protected-'))));
      verifyNever(() => logger.info(any(that: contains('protected-'))));
    });

    test('emits one bounded warning message for an unbounded provider warning count', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        instrumentationBody: List.filled(1000, 'warning: protected-sdk-body').join('\n'),
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(
          any(that: contains('native warnings present: 1000 line(s)')),
        ),
      ).called(1);
      verifyNever(() => logger.err(any(that: contains('protected-sdk-body'))));
      verifyNever(() => logger.info(any(that: contains('protected-sdk-body'))));
    });

    for (final status in [403, 599]) {
      test('surfaces instrumentation HTTP $status without dumping the body', () async {
        stubGet(
          sessionBody: session(status: 'failed', networkLogs: null),
          instrumentationBody: 'protected provider response secret',
          instrumentationStatus: status,
        );

        await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

        verify(
          () => logger.err(
            any(that: contains('HTTP $status for session session-1')),
          ),
        ).called(1);
        verifyNever(() => logger.err(any(that: contains('secret'))));
      });
    }

    test('surfaces an empty instrumentation log rather than silently omitting it', () async {
      stubGet(sessionBody: session(status: 'failed', networkLogs: null));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(any(that: contains('no failure marker found'))),
      ).called(1);
    });

    test('surfaces thrown fetches without printing secret exception data', () async {
      stubGet(sessionBody: session(status: 'failed', networkLogs: null));
      when(
        () => ltHttp.get(
          any(that: contains('/log/instrumentation')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenThrow(Exception('protected secret'));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.err(any(that: contains('native instrumentation fetch failed'))),
      ).called(1);
      verifyNever(() => logger.err(any(that: contains('secret'))));
    });

    test('redacts signed LambdaTest artifact URLs in diagnostic output', () async {
      stubGet(
        sessionBody: session(
          status: 'failed',
          networkLogs: 'https://mobile-api.lambdatest.com/log/network?verify=secret',
          videoUrl: 'https://example.test/video.mp4?verify=secret&expires=tomorrow',
          deviceLogs: 'https://mobile-api.lambdatest.com/log/device?token=secret',
        ),
      );

      await diagnostics().report(buildId: '1', platform: 'Android', env: env);

      verifyNever(() => logger.info(any(that: contains('secret'))));
      verify(() => logger.info(any(that: contains('verify=<redacted>')))).called(greaterThanOrEqualTo(1));
      verify(() => logger.info(any(that: contains('token=<redacted>')))).called(1);
    });

    test('falls back to a generic reason for an unknown status', () async {
      stubGet(sessionBody: session(status: 'running', networkLogs: null));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('see the video')))).called(1);
    });

    test('tolerates a non-list network log (no egress summary)', () async {
      stubGet(
        sessionBody: session(status: 'failed'),
        networkBody: '{}',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verifyNever(() => logger.info(any(that: contains('requests completed'))));
      verify(() => logger.err(any(that: contains('failed')))).called(1);
    });

    test('tolerates a network log that fails to parse', () async {
      stubGet(
        sessionBody: session(status: 'failed'),
        networkBody: 'not json',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('failed')))).called(1);
    });

    test('prints the per-test breakdown parsed from the XML report', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        reportBody: "Test Case '-[RunnerUITests test_reaches_accounts]' "
            'passed (12.3 seconds).\n'
            "Test Case '-[RunnerUITests test_bad_credential]' "
            'failed (4.5 seconds).',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(
        () => logger.info(
          any(
            that: contains(
              'per-test results (1/2 '
              'passed)',
            ),
          ),
        ),
      ).called(1);
      verify(() => logger.info(any(that: contains('✅ reaches accounts')))).called(1);
      verify(() => logger.info(any(that: contains('❌ bad credential')))).called(1);
    });

    test('skips the breakdown when the report has no test-case lines', () async {
      stubGet(
        sessionBody: session(status: 'failed', networkLogs: null),
        reportBody: '<testsuites></testsuites>',
      );

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verifyNever(() => logger.info(any(that: contains('per-test results'))));
    });

    test('reports it could not read the session when data is empty', () async {
      when(
        () => ltHttp.get(
          any(that: contains('sessions?build_id')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => http.Response('{"data":[]}', 200));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('Could not read')))).called(1);
    });

    test('reports it could not read when the session row is not a map', () async {
      when(
        () => ltHttp.get(
          any(that: contains('sessions?build_id')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => http.Response('{"data":[5]}', 200));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('Could not read')))).called(1);
    });

    test('tolerates a thrown session fetch', () async {
      when(
        () => ltHttp.get(
          any(that: contains('sessions?build_id')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenThrow(Exception('network'));

      await diagnostics().report(buildId: '1', platform: 'iOS', env: env);

      verify(() => logger.err(any(that: contains('Could not read')))).called(1);
    });
  });

  group('parseLtTestOutcomes', () {
    test('parses each test-case line, humanising the method name', () {
      final outcomes = parseLtTestOutcomes(
        "Test Case '-[RunnerUITests test_fast_fails_on_a_backend_error]' "
        'passed (15.557 seconds).\n'
        "Test Case '-[RunnerUITests test_reaches_accounts_after_MFA]' "
        'failed (22.575 seconds).',
      );

      expect(outcomes, hasLength(2));
      expect(outcomes[0].name, 'fast fails on a backend error');
      expect(outcomes[0].passed, isTrue);
      expect(outcomes[0].seconds, '15.557');
      expect(outcomes[1].name, 'reaches accounts after MFA');
      expect(outcomes[1].passed, isFalse);
    });

    test('ignores Test Suite lines and "started" lines', () {
      final outcomes = parseLtTestOutcomes(
        "Test Case '-[RunnerUITests test_a]' started.\n"
        "Test Suite 'RunnerUITests' failed at 2026-06-05 17:08:55.\n"
        "Test Case '-[RunnerUITests test_a]' passed (1.0 seconds).",
      );

      expect(outcomes, hasLength(1));
      expect(outcomes.single.name, 'a');
    });

    test('returns empty for a null, empty, or test-case-free report', () {
      expect(parseLtTestOutcomes(null), isEmpty);
      expect(parseLtTestOutcomes(''), isEmpty);
      expect(parseLtTestOutcomes('<testsuites/>'), isEmpty);
    });
  });
}
