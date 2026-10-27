import 'dart:io';

import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;

  String genDir() => p.join(repo.path, 'android', 'app', 'src', 'androidTest', 'java', 'mplatrol', 'e2e');
  String generated(String file) => File(p.join(genDir(), file)).readAsStringSync();
  File gradleFile() => File(p.join(repo.path, 'android', 'app', 'build.gradle'));

  setUp(() {
    repo = Directory.systemTemp.createTempSync('android_gen');
    Directory(p.join(repo.path, 'patrol_test')).createSync();
  });

  tearDown(() => repo.deleteSync(recursive: true));

  void writeTest(String name, String body) => File(p.join(repo.path, 'patrol_test', name)).writeAsStringSync(body);

  void writeGradle([String runner = '']) {
    gradleFile()
      ..createSync(recursive: true)
      ..writeAsStringSync('''
android {
    namespace 'com.example'

    defaultConfig {
        applicationId "com.example"
        minSdkVersion 31
        targetSdkVersion 35
${runner.isEmpty ? '' : '        testInstrumentationRunner "$runner"\n'}
    }
}

dependencies {
    implementation "androidx.appcompat:appcompat:1.7.0"
}
''');
  }

  test('uses the prepared package and rejects unresolved identities', () {
    writeGradle();
    expect(androidPatrolPackageName(repo.path), 'com.example');
    gradleFile().writeAsStringSync("android {\n // applicationId 'com.old'\n"
        " applicationId = 'com.example.wccu.staging'\n}\n");
    expect(androidPatrolPackageName(repo.path), 'com.example.wccu.staging');
    gradleFile().writeAsStringSync('android { applicationId project.packageName }');
    expect(() => androidPatrolPackageName(repo.path), throwsFormatException);
  });

  test('excludes duplicate JVM manifests idempotently with existing packaging', () {
    writeGradle();
    for (final existing in [false, true]) {
      writeGradle();
      if (existing) {
        gradleFile().writeAsStringSync(
            gradleFile().readAsStringSync().replaceFirst('android {', 'android {\n packagingOptions {\n }'));
      }
      ensureAndroidPatrolGradleConfig(repo.path);
      final first = gradleFile().readAsStringSync();
      expect(first, contains('exclude "META-INF/versions/9/OSGI-INF/MANIFEST.MF"'));
      ensureAndroidPatrolGradleConfig(repo.path);
      expect(gradleFile().readAsStringSync(), first);
    }
  });

  test('rejects a handwritten duplicate without deleting user code', () {
    writeTest('chatsdk_test.dart', "patrolTest('authorization');");
    final manual = File(p.join(genDir(), 'LegacyChat.java'));
    manual.parent.createSync(recursive: true);
    const source = 'class LegacyChat extends PatrolDartTest {\n'
        'protected String dartFileGroup() { return "chatsdk_test"; }\n'
        '@Test public void authorization() {} }';
    manual.writeAsStringSync(source);
    expect(() => generateAndroidPatrolRunner(repo.path), throwsFormatException);
    expect(manual.readAsStringSync(), source);
    writeTest('other_test.dart', "patrolTest('other');");
    expect(generateAndroidPatrolRunner(repo.path, target: 'patrol_test/other_test.dart'), 1);
    expect(manual.readAsStringSync(), source);
  });

  test('throws when there are no patrol tests', () {
    writeTest('empty_test.dart', 'void main() {}');
    expect(() => generateAndroidPatrolRunner(repo.path), throwsStateError);
  });

  test('includes targetRegex in the error message when no tests match', () {
    writeTest('login_test.dart', "patrolTest('login');");
    expect(
      () => generateAndroidPatrolRunner(repo.path, targetRegex: 'no_such_sdk'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('matching /no_such_sdk/'),
      )),
    );
  });

  test('includes sdk in the error message when no tests match', () {
    writeTest('login_test.dart', "patrolTest('login');");
    expect(
      () => generateAndroidPatrolRunner(repo.path, sdk: 'no_such_sdk'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('for SDK "no_such_sdk"'),
      )),
    );
  });

  test('generates a base + one class per file and returns the total count', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing'); patrolTest('another thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final count = generateAndroidPatrolRunner(repo.path);

    expect(count, 3);
    final base = generated('PatrolDartTest.java');
    expect(base, contains('abstract class PatrolDartTest'));
    expect(
      base.indexOf('Automator.Companion.getInstance().initialize();'),
      lessThan(base.indexOf('instrumentation.setUp(mainActivity);')),
    );
    expect(base, contains('instrumentation.runDartTest(matches.get(0));'));
    expect(base, isNot(contains('UiAutomation')));
    expect(base, isNot(contains('grantRuntimePermission')));
    expect(base, isNot(contains('grantDeclaredRuntimePermissions')));
    expect(
      base.indexOf('grantLocation(instrumentation, appPackage);'),
      allOf(
        greaterThan(base.indexOf('Automator.Companion.getInstance().initialize();')),
        lessThan(base.indexOf('instrumentation.setUp(mainActivity);')),
      ),
    );

    final faults = generated('LoginFaultsTest.java');
    expect(faults, contains('public class LoginFaultsTest extends PatrolDartTest'));
    expect(faults, contains('return "login_faults_test";'));
    expect(faults, contains('runDartTest("a thing");'));
    expect(faults, contains('runDartTest("another thing");'));

    expect(generated('PatrolLoginTest.java'), contains('runDartTest("happy path");'));
  });

  group('location pre-grant exemption', () {
    void writeManifest(Object? flag) {
      File(p.join(repo.path, 'patrol_test', 'sdk_requirements.json')).writeAsStringSync('''
{"schema": 1, "tests": [
  {"file": "patrol_test/beaconsdk_location_journey_test.dart",
   "realPermissionDialogs": $flag},
  {"file": "patrol_test/patrol_login_test.dart"}
]}''');
    }

    setUp(() {
      writeTest('beaconsdk_location_journey_test.dart', "patrolTest('enables');");
      writeTest('patrol_login_test.dart', "patrolTest('happy path');");
    });

    test('opts out only journeys flagged realPermissionDialogs', () {
      writeManifest(true);

      generateAndroidPatrolRunner(repo.path);

      expect(generated('BeaconSdkLocationJourneyTest.java'),
          contains('protected boolean pregrantLocation() {\n        return false;'));
      expect(generated('PatrolLoginTest.java'), isNot(contains('pregrantLocation')));
    });

    test('keeps the pre-grant when the flag is false', () {
      writeManifest(false);

      generateAndroidPatrolRunner(repo.path);

      expect(generated('BeaconSdkLocationJourneyTest.java'), isNot(contains('pregrantLocation')));
    });

    test('rejects a non-boolean flag', () {
      writeManifest('"yes"');

      expect(() => generateAndroidPatrolRunner(repo.path),
          throwsA(isA<StateError>().having((error) => error.message, 'message', contains('realPermissionDialogs'))));
    });
  });

  test('defaults the @Test timeout to 240000, overridable via env', () {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateAndroidPatrolRunner(repo.path);
    expect(generated('PatrolLoginTest.java'), contains('@Test(timeout = 240000)'));

    generateAndroidPatrolRunner(repo.path, env: const {e2eTestTimeoutMsEnv: '600000'});
    expect(generated('PatrolLoginTest.java'), contains('@Test(timeout = 600000)'));
  });

  test('diagnostic boundary preserves local and LT selection without a manifest', () {
    writeTest('probe_test.dart', "patrolTest('probe');");
    writeGradle();
    final identity = androidPatrolGeneratorIdentity();
    expect(generateAndroidPatrolRunner(repo.path), 1);
    final local = generated('PatrolDartTest.java');
    expect(generateAndroidPatrolRunner(repo.path, patrolRunner: androidLambdaTestPatrolRunner), 1);
    expect(generated('PatrolDartTest.java'), local);
    expect(androidPatrolGeneratorIdentity(), identity);
    expect(gradleFile().readAsStringSync(), contains(androidLambdaTestPatrolRunner));
    expect(File(p.join(repo.path, 'android/app/src/androidTest/AndroidManifest.xml')).existsSync(), isFalse);
    expect(generated('ProbeTest.java').split('@Test(').length - 1, 1);
    expect(local, contains('finally {\n            cleanup.run();'));
    expect(local.indexOf('Runnable cleanup = installNativeDiagnostics(instrumentation);'),
        lessThan(local.indexOf('executeDartTest(instrumentation, appPackage, mainActivity, description);')));
  });

  test('resolveAndroidTestTimeoutMs parses the env or falls back to default', () {
    expect(resolveAndroidTestTimeoutMs(null), 240000);
    expect(resolveAndroidTestTimeoutMs(const {}), 240000);
    expect(resolveAndroidTestTimeoutMs(const {e2eTestTimeoutMsEnv: '600000'}), 600000);
    // Non-positive and non-numeric fall back to the default.
    expect(resolveAndroidTestTimeoutMs(const {e2eTestTimeoutMsEnv: '0'}), 240000);
    expect(resolveAndroidTestTimeoutMs(const {e2eTestTimeoutMsEnv: 'nope'}), 240000);
  });

  test('target generates only that file', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final count = generateAndroidPatrolRunner(repo.path, target: 'patrol_test/patrol_login_test.dart');

    expect(count, 1);
    expect(File(p.join(genDir(), 'PatrolLoginTest.java')).existsSync(), isTrue);
    expect(File(p.join(genDir(), 'LoginFaultsTest.java')).existsSync(), isFalse);
  });

  test('targetRegex generates every selected Patrol test method', () {
    writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('tenant one'); patrolTest('tenant two');");
    writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('VideoSdk one');");

    final count = generateAndroidPatrolRunner(repo.path, targetRegex: 'tenant_sdk');

    expect(count, 2);
    expect(generated('TenantSdkMatrixSmokeTest.java'), contains('runDartTest("tenant one");'));
    expect(generated('TenantSdkMatrixSmokeTest.java'), contains('runDartTest("tenant two");'));
    expect(File(p.join(genDir(), 'VideosdkSdkSmokeTest.java')).existsSync(), isFalse);
  });

  test('sdk generates only matching SDK Patrol test methods', () {
    writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('tenant one');");
    writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('VideoSdk one');");

    final count = generateAndroidPatrolRunner(repo.path, sdk: 'videosdk');

    expect(count, 1);
    expect(generated('VideosdkSdkSmokeTest.java'), contains('runDartTest("VideoSdk one");'));
    expect(File(p.join(genDir(), 'TenantSdkMatrixSmokeTest.java')).existsSync(), isFalse);
  });

  test('deletes previously generated classes but keeps hand-written files', () {
    Directory(genDir()).createSync(recursive: true);
    File(p.join(genDir(), 'IPv4PatrolJUnitRunner.java')).writeAsStringSync('// a hand-written custom runner\n');
    File(p.join(genDir(), 'stale_test.java')).writeAsStringSync('// GENERATED by `mplatrol` — old class\n');
    writeTest('new_test.dart', "patrolTest('x');");

    generateAndroidPatrolRunner(repo.path);

    expect(
      File(p.join(genDir(), 'IPv4PatrolJUnitRunner.java')).existsSync(),
      isTrue,
      reason: 'hand-written files must be preserved',
    );
    expect(
      File(p.join(genDir(), 'stale_test.java')).existsSync(),
      isFalse,
      reason: 'previously generated classes must be removed',
    );
    expect(File(p.join(genDir(), 'NewTest.java')).existsSync(), isTrue);
  });

  test('orders methods by name only when app data is kept', () {
    writeTest('chain_test.dart', "patrolTest('step 2'); patrolTest('step 1');");

    generateAndroidPatrolRunner(repo.path);
    final defaultOrder = generated('ChainTest.java');
    generateAndroidPatrolRunner(repo.path, env: const {e2eKeepAppDataEnv: '1'});
    final nameOrder = generated('ChainTest.java');

    expect(defaultOrder, isNot(contains('FixMethodOrder')));
    expect(defaultOrder, contains('@RunWith(JUnit4.class)\n@OrderWith(MplatrolTestOrder.class)\npublic class'),
        reason: 'other runs order their tests at runtime by the seeded instrumentation argument');
    expect(nameOrder, contains('@FixMethodOrder(MethodSorters.NAME_ASCENDING)\npublic class'));
    expect(nameOrder, isNot(contains('OrderWith')), reason: 'JUnit rejects @OrderWith with @FixMethodOrder');
  });

  test('escapes quotes in a description for the Java string literal', () {
    writeTest('q_test.dart', "patrolTest('say \"hi\"');");

    generateAndroidPatrolRunner(repo.path);

    expect(generated('QTest.java'), contains(r'runDartTest("say \"hi\"");'));
  });

  group('Gradle config', () {
    test('adds Patrol runner and orchestrator settings', () {
      writeGradle();
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path);

      final gradle = gradleFile().readAsStringSync();
      expect(gradle, contains('testInstrumentationRunner "pl.leancode.patrol.PatrolJUnitRunner"'));
      expect(gradle, contains('testInstrumentationRunnerArguments clearPackageData: "true"'));
      expect(gradle, contains('execution "ANDROIDX_TEST_ORCHESTRATOR"'));
      expect(gradle, contains('androidTestUtil "androidx.test:orchestrator:1.5.1"'));
      expect(gradle, isNot(contains('ndkVersion')));
      // The seeded order is read from the environment at run time, so the
      // file (and the build) is the same for every seed.
      expect(
          gradle,
          contains('testInstrumentationRunnerArguments clearPackageData: "true", '
              'mplatrolTestOrder: (System.getenv("MPLATROL_TEST_ORDER") ?: "declared")\n'));
    });

    test('generates the runtime test ordering class', () {
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path);

      final ordering = generated('MplatrolTestOrder.java');
      expect(ordering, startsWith('// GENERATED by `mplatrol`'));
      expect(ordering, contains('public final class MplatrolTestOrder implements Ordering.Factory'));
      expect(ordering, contains('arguments.getString("mplatrolTestOrder")'));
    });

    test('keeps app data between tests when MPLATROL_E2E_KEEP_APP_DATA is set', () {
      writeGradle();
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path, env: const {e2eKeepAppDataEnv: 'true'});
      final kept = gradleFile().readAsStringSync();
      generateAndroidPatrolRunner(repo.path, env: const {e2eKeepAppDataEnv: ''});
      final cleared = gradleFile().readAsStringSync();

      expect(kept, contains('testInstrumentationRunnerArguments clearPackageData: "false"'));
      expect(kept, isNot(contains('clearPackageData: "true"')));
      expect(RegExp('clearPackageData').allMatches(cleared), hasLength(1),
          reason: 'the line is replaced, never duplicated');
      expect(RegExp('mplatrolTestOrder').allMatches(cleared), hasLength(1));
      expect(cleared, contains('testInstrumentationRunnerArguments clearPackageData: "true"'));
    });

    test('reads MPLATROL_E2E_KEEP_APP_DATA as 1 or true only', () {
      expect(resolveAndroidKeepAppData(const {e2eKeepAppDataEnv: '1'}), isTrue);
      expect(resolveAndroidKeepAppData(const {e2eKeepAppDataEnv: ' TRUE '}), isTrue);
      expect(resolveAndroidKeepAppData(const {e2eKeepAppDataEnv: 'yes'}), isFalse);
      expect(resolveAndroidKeepAppData(const {}), isFalse);
      expect(resolveAndroidKeepAppData(null), isFalse);
    });

    test('can pin the LambdaTest Patrol runner for real-device builds', () {
      writeGradle();
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path, patrolRunner: 'pl.leancode.patrol.LambdaTestPatrolJUnitRunner');

      expect(
        gradleFile().readAsStringSync(),
        contains('testInstrumentationRunner "pl.leancode.patrol.LambdaTestPatrolJUnitRunner"'),
      );
    });

    test('LambdaTest builds keep only arm64 and local builds drop the filter', () {
      writeGradle();
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path, patrolRunner: androidLambdaTestPatrolRunner);
      generateAndroidPatrolRunner(repo.path, patrolRunner: androidLambdaTestPatrolRunner);
      final lambdaTest = gradleFile().readAsStringSync();
      generateAndroidPatrolRunner(repo.path);
      final local = gradleFile().readAsStringSync();

      expect("ndk.abiFilters 'arm64-v8a'".allMatches(lambdaTest).length, 1);
      expect(local, isNot(contains('abiFilters')));
    });

    test('replaces a legacy runner and remains idempotent', () {
      writeGradle('android.test.InstrumentationTestRunner');
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path);
      final first = gradleFile().readAsStringSync();
      generateAndroidPatrolRunner(repo.path);
      final second = gradleFile().readAsStringSync();

      expect(second, equals(first));
      expect(first, isNot(contains('android.test.InstrumentationTestRunner')));
      expect('testInstrumentationRunner'.allMatches(first).length, equals(2), reason: 'runner plus runner arguments');
      expect('androidTestUtil "androidx.test:orchestrator:1.5.1"'.allMatches(first).length, equals(1));
    });

    test('adds orchestrator execution inside an existing testOptions block', () {
      gradleFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('''
android {
    namespace 'com.example'

    defaultConfig {
        applicationId "com.example"
    }

    testOptions {
        animationsDisabled = true
    }
}

dependencies {
}
''');
      writeTest('login_test.dart', "patrolTest('happy path');");

      generateAndroidPatrolRunner(repo.path);

      final gradle = gradleFile().readAsStringSync();
      expect(gradle, contains('testOptions {'));
      expect(gradle, contains('animationsDisabled = true'));
      expect(gradle, contains('execution "ANDROIDX_TEST_ORCHESTRATOR"'));
      expect('testOptions'.allMatches(gradle).length, equals(1));
    });
  });
}
