import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

/// One real-looking line of run output per lesson, and the lesson it must be recognized as.
const _evidence = <String, TestLesson>{
  'getLaunchIntentForPackage returned null': TestLesson.appPackage,
  'InvalidCredentials': TestLesson.credentials,
  'SocketException: Connection refused': TestLesson.proxy,
  'E AndroidRuntime: FATAL EXCEPTION: main\nProcess: com.example.app': TestLesson.appProcessCrashed,
  'META-INF/versions/9/OSGI-INF/MANIFEST.MF': TestLesson.duplicateManifest,
  "Couldn't resolve native function 'DOBJC_initializeApi'": TestLesson.nativeAssetsMissing,
  'UiAutomation already registered': TestLesson.automationOwner,
  'texts[Unauthorized network location|Try again later from a secure network.]': TestLesson.networkAllowlist,
  '[android-utp] UNDETERMINED: Android device (54120DLAQ002QN) is not found.': TestLesson.gradleDaemonEnvironment,
  '[android-utp] UNDETERMINED: Android device (emulator-5554) is not found.': TestLesson.emulatorOffline,
  'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]': TestLesson.emulatorStorage,
  'androidx.test.services was killed, which is usually due to low memory': TestLesson.emulatorMemory,
  'LOCAL_DEVICE_CONTENTION: 12 screenrecord processes this leg did not start': TestLesson.localDeviceContention,
  'INSTRUMENTATION_ABORTED: System has crashed.': TestLesson.androidSystemCrashed,
  "SYSTEM_NOT_RESPONDING: System UI isn't responding": TestLesson.androidSystemNotResponding,
  'PERMISSION_DIALOG_UNANSWERED: no allow button': TestLesson.permissionDialogUnanswered,
  r'Undefined symbols: "_OBJC_CLASS_$_FlutterStandardMessageCodec"': TestLesson.iosSimulatorFlutterLink,
  '"Allow “Example” to use your location?"': TestLesson.locationAlert,
  'never finished: no task started or finished for 5 min (limit 5 min)': TestLesson.lambdaTestCapacity,
  'Failed to extract test cases from device': TestLesson.lambdaTestDiscovery,
  'error: Provisioning profile "Example Development" expired on Sep 19, 2026.': TestLesson.iosProvisioningExpired,
  'Authentication loading error -1: net::ERR_BLOCKED_BY_ORB': TestLesson.authPageScriptsBlocked,
  'Bad state: Could not read runtime E2E credentials (url=http://localhost.lambdatest.com:47236/e2e-credentials): '
      'TimeoutException after 0:00:05.000000': TestLesson.runtimeCredentialsUnreachable,
  'Access Denied. Your current IP address is not authorized to access this page.': TestLesson.ipAllowlistBlocked,
  'error    app update failed - Error setting up framework.': TestLesson.lambdaTestFrameworkSetup,
  'LambdaTest upload of Runner.ipa failed after 6 attempts (HTTP 599)': TestLesson.lambdaTestUpload,
  'failed - PATROL_SHARD_NOT_RUN iOS shard coordinator unreachable': TestLesson.iosShardCoordinatorUnreachable,
  'patrol binding=_DriverBinding': TestLesson.iosDriverBindingReplacesPatrol,
  '** TEST BUILD INTERRUPTED **': TestLesson.xcodebuildInterrupted,
  'ERR::TUN::1 tunnel failed': TestLesson.lambdaTestTunnel,
  'None of your spec sources contain a spec satisfying the dependency': TestLesson.cocoaPodsSpecsOutdated,
  "Error: Couldn't resolve the package 'some_sdk' in 'package:some_sdk/some_sdk.dart'":
      TestLesson.e2eImportsOptionalPackage,
  'Undefined symbols for architecture arm64:': TestLesson.staleIosDerivedData,
  'failure=STEP login_form: ERRPAGE:chrome-error://chromewebdata/.': TestLesson.loginErrorPage,
  'java.lang.NoSuchMethodError: No method getWebkitToCompatConverter() in WebViewProviderFactoryBoundaryInterface':
      TestLesson.outdatedSystemWebView,
  'XCTAssert failed: Application com.apple.Preferences is not running': TestLesson.iosSettingsAppNotRunning,
  'Failed to open the default app for a URL: Timed out': TestLesson.iosOpenUrlTimeout,
  'Patrol direct client error: Error Domain=PatrolDirectClient Code=2 "Timed out waiting for runDartTest response."':
      TestLesson.patrolClientTimeout,
};

void main() {
  late Directory repo;
  setUp(() => repo = Directory.systemTemp.createTempSync('mplatrol_lessons'));
  tearDown(() => repo.deleteSync(recursive: true));

  test('recognizes each lesson from its run output', () {
    for (final MapEntry(key: evidence, value: lesson) in _evidence.entries) {
      expect(recognizeTestLessons(evidence), contains(lesson), reason: evidence);
    }
  });

  test('leaves unknown errors unclassified', () {
    expect(recognizeTestLessons('HTTP 403 unrelated service'), isEmpty);
    expect(recognizeTestLessons('Expected: true\n  Actual: <false>'), isEmpty);
  });

  test('a more specific lesson supersedes the general one it explains', () {
    expect(recognizeTestLessons('PATROL_SHARD_NOT_RUN: connect: connection refused'),
        {TestLesson.iosShardCoordinatorUnreachable});
    expect(recognizeTestLessons('Android device (emulator-5554) is not found'), {TestLesson.emulatorOffline});
    expect(recognizeTestLessons('LOCAL_DEVICE_CONTENTION\nINSTRUMENTATION_ABORTED: System has crashed'),
        {TestLesson.localDeviceContention});
  });

  test('every lesson has a recognizer and a remedy', () {
    for (final lesson in TestLesson.values) {
      expect(lesson.remedy, isNotEmpty, reason: lesson.name);
      expect(lesson.symptom, isNotEmpty, reason: lesson.name);
      if (lesson != TestLesson.emptyCoverage) {
        // emptyCoverage is recorded by the coverage collector, not recognized in output.
        expect(_evidence.values, contains(lesson), reason: '${lesson.name} has no evidence sample in this test');
      }
    }
  });

  test('every lesson has a category that explains a result, never pass or a verdict without a cause', () {
    const verdictsOnly = {
      ItResultCategory.pass,
      ItResultCategory.notRun,
      ItResultCategory.notVerified,
      ItResultCategory.notSelected,
    };
    for (final lesson in TestLesson.values) {
      expect(verdictsOnly, isNot(contains(lesson.category)), reason: lesson.name);
      expect(lesson.appDefect, lesson.category == ItResultCategory.appDefect, reason: lesson.name);
    }
  });

  test('maps infrastructure lessons to their category', () {
    expect(TestLesson.lambdaTestTunnel.category, ItResultCategory.ltTunnelErr);
    expect(TestLesson.lambdaTestCapacity.category, ItResultCategory.ltFailure);
    expect(TestLesson.emulatorMemory.category, ItResultCategory.deviceFailure);
    expect(TestLesson.credentials.category, ItResultCategory.credFailure);
    expect(TestLesson.cocoaPodsSpecsOutdated.category, ItResultCategory.buildFailure);
    expect(TestLesson.locationAlert.category, ItResultCategory.testFailure);
  });

  test('finds the evidence line a lesson was recognized on', () {
    const evidence = 'starting\n  E/flutter: InvalidCredentials for user  \nteardown';
    expect(lessonKeyErrorLine(TestLesson.credentials, evidence), 'E/flutter: InvalidCredentials for user');
    expect(lessonKeyErrorLine(TestLesson.proxy, evidence), isNull);
  });

  test('reporting lessons logs their remedy with the count', () async {
    await scaffoldMockDependencies();

    reportTestLessons('InvalidCredentials', repo: repo.path, logger: getDep<MplatrolLogger>());

    verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson credentials (observed 1)')))).called(1);
  });

  test('reporting lessons in a leg explains its tests that end without a result', () async {
    await scaffoldMockDependencies();
    const leg = ItRunLeg(tenant: 'acme', environment: 'staging', variant: 'lt-ios');
    final results = getDep<ItRunResults>();

    await results.withLeg(leg, () async {
      results.selectTests([const ItSelectedTest(id: 'a', file: 'f', description: 'a')]);
      reportTestLessons('ERR::TUN::1', repo: repo.path, logger: getDep<MplatrolLogger>());
    });

    expect(results.resultsOf(leg).single.categoryName, 'lt-tunnel-err');
  });

  test('a lesson history it cannot save is a warning; the remedy is still logged', () async {
    await scaffoldMockDependencies();
    final notADirectory = File('${repo.path}/file')..writeAsStringSync('');

    reportTestLessons('InvalidCredentials', repo: notADirectory.path, logger: getDep<MplatrolLogger>());

    verify(() => getDep<MplatrolLogger>().warn('Could not save mplatrol lesson history: FileSystemException.'))
        .called(1);
    verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson credentials (observed 1)')))).called(1);
  });

  test('learns recurrence without retaining secret evidence', () {
    final history = TestLessonHistory(repo.path);
    final lessons = recognizeTestLessons('InvalidCredentials password=private otp=123456');
    expect(history.record(lessons)[TestLesson.credentials], 1);
    expect(TestLessonHistory(repo.path).record(lessons)[TestLesson.credentials], 2);
    final contents = history.file.readAsStringSync();
    expect(contents, isNot(contains('private')));
    expect(contents, isNot(contains('123456')));
    expect(history.read(), {TestLesson.credentials: 2});
  });

  test('unknown failures create no history; malformed history fails explicitly', () {
    final history = TestLessonHistory(repo.path);
    expect(history.record({}), isEmpty);
    expect(history.file.existsSync(), isFalse);
    history.file.parent.createSync(recursive: true);
    history.file.writeAsStringSync('{"schemaVersion":1,"lessons":{"proxy":{"count":0}}}');
    expect(history.read, throwsFormatException);
    history.file.writeAsStringSync('{}');
    expect(history.read, throwsFormatException);
  });

  group('project lessons', () {
    tearDown(clearRegisteredTestLessons);

    TestLesson sandboxDown({String name = 'paymentsSandboxDown', String pattern = r'payments sandbox returned 50\d'}) =>
        TestLesson.custom(
          name: name,
          category: ItResultCategory.envFailure,
          symptom: 'The payments sandbox answers HTTP 5xx',
          remedy: 'The sandbox is down; rerun when its status page is green.',
          pattern: pattern,
        );

    test('a registered lesson is recognized after the built-in ones and counted in the history', () {
      final lesson = sandboxDown();
      expect(recognizeTestLessons('Payments sandbox returned 503'), isEmpty);

      registerTestLessons([lesson]);

      expect(recognizeTestLessons('Payments sandbox returned 503'), {lesson});
      expect(
          recognizeTestLessons('InvalidCredentials\npayments sandbox returned 502'), {TestLesson.credentials, lesson});
      expect(TestLesson.values.last, lesson);
      expect(lessonKeyErrorLine(lesson, 'a\n  payments sandbox returned 500 x\nb'), 'payments sandbox returned 500 x');
      final history = TestLessonHistory(repo.path);
      history.record({lesson});
      expect(TestLessonHistory(repo.path).read(), {lesson: 1});
    });

    test('a registered lesson explains a leg like a built-in one', () async {
      await scaffoldMockDependencies();
      final lesson = sandboxDown();
      registerTestLessons([lesson]);
      const leg = ItRunLeg(tenant: 'acme', environment: 'qa', variant: 'android');
      final results = getDep<ItRunResults>();

      await results.withLeg(leg, () async {
        results.selectTests([const ItSelectedTest(id: 'a', file: 'f', description: 'pays')]);
        reportTestLessons('payments sandbox returned 503', repo: repo.path, logger: getDep<MplatrolLogger>());
      });

      expect(results.resultsOf(leg).single.categoryName, 'qa-env-failure');
      expect(results.resultsOf(leg).single.lesson, lesson);
    });

    test('registering the same lesson twice is a no-op; another lesson with a taken name is refused', () {
      final lesson = sandboxDown();
      registerTestLessons([lesson, lesson]);
      expect(TestLesson.values.where((known) => known == lesson), hasLength(1));
      expect(() => registerTestLessons([sandboxDown()]), throwsArgumentError);
      expect(() => registerTestLessons([sandboxDown(name: 'credentials')]), throwsArgumentError);
      expect(() => registerTestLessons([TestLesson.proxy]), throwsArgumentError);
    });

    test('an invalid project lesson is refused when it is created', () {
      expect(() => sandboxDown(name: 'two words'), throwsArgumentError);
      expect(() => sandboxDown(pattern: ' '), throwsArgumentError);
      expect(() => sandboxDown(pattern: '('), throwsArgumentError);
      expect(
          () => TestLesson.custom(name: 'x', category: ItResultCategory.pass, symptom: 's', remedy: 'r', pattern: 'p'),
          throwsArgumentError);
    });
  });
}
