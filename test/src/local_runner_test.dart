import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_device_egress.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/android_permission_dialog.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/ios_device_egress.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_biometrics.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:mplatrol/src/upgrade/upgrade_leg.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _MockBiometricResponder extends Mock implements BiometricResponder {}

const _target = 'patrol_test/patrol_login_test.dart';
const _androidId = 'com.example.demo.staging';
const _iosBundleId = 'com.example.demo.staging.Runner';

/// Framework checks an emulator fails before mplatrol treats it as wedged and
/// reboots it: the initial probe plus the 30-poll wait for a just-booted one.
const _wedgedFrameworkChecks = 31;

String _encodedDefine(String define) => base64.encode(utf8.encode(define));

ProcessResultX _result({int exitCode = 0, String stdout = '', String stderr = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: stderr);

ProcessResultX _passedIosSummary() => _result(
        stdout: jsonEncode({
      'result': 'Passed',
      'totalTestCount': 1,
      'passedTests': 1,
      'failedTests': 0,
      'skippedTests': 0,
      'expectedFailures': 0,
    }));

ProcessResultX _successfulIosPatrolResult(String repo) {
  Directory(p.join(repo, 'build', 'ios_results_${DateTime.now().millisecondsSinceEpoch}.xcresult'))
      .createSync(recursive: true);
  return _result();
}

File _patrolCliSource(String home) => _patrolCliSourceInPubCache(p.join(home, '.pub-cache'));

File _patrolCliSourceInPubCache(String pubCache) =>
    File(p.join(pubCache, 'hosted', 'pub.dev', 'patrol_cli-4.8.0', 'lib', 'src', 'ios', 'ios_test_backend.dart'));

File _patrolCliAppOptionsSource(String home) => _patrolCliAppOptionsSourceInPubCache(p.join(home, '.pub-cache'));

File _patrolCliAppOptionsSourceInPubCache(String pubCache) =>
    File(p.join(pubCache, 'hosted', 'pub.dev', 'patrol_cli-4.8.0', 'lib', 'src', 'crossplatform', 'app_options.dart'));

File _patchedPatrolCliSource(String repo) =>
    File(p.join(repo, '.mplatrol', 'patched_packages', 'patrol_cli', 'lib', 'src', 'ios', 'ios_test_backend.dart'));

File _patchedPatrolCliAppOptionsSource(String repo) => File(
    p.join(repo, '.mplatrol', 'patched_packages', 'patrol_cli', 'lib', 'src', 'crossplatform', 'app_options.dart'));

File _patrolCliBundlerSourceInPubCache(String pubCache) =>
    File(p.join(pubCache, 'hosted', 'pub.dev', 'patrol_cli-4.8.0', 'lib', 'src', 'test_bundler.dart'));

File _patchedPatrolCliBundlerSource(String repo) =>
    File(p.join(repo, '.mplatrol', 'patched_packages', 'patrol_cli', 'lib', 'src', 'test_bundler.dart'));

String _patchedPubCache(String repo) => p.join(repo, '.mplatrol', 'patched_pub_cache');

String _patchedPatrolCliMain(String repo) =>
    p.join(repo, '.mplatrol', 'patched_packages', 'patrol_cli', 'bin', 'main.dart');

File _fvmBinary(String pubCache) => File(p.join(pubCache, 'bin', 'fvm'));

void _writePatchablePatrolCli({String? home, String? pubCache}) {
  assert(home != null || pubCache != null, 'home or pubCache must identify the fake pub cache root');
  final resolvedPubCache = pubCache ?? p.join(home!, '.pub-cache');
  _patrolCliSourceInPubCache(resolvedPubCache)
    ..createSync(recursive: true)
    ..writeAsStringSync(r'''
String selectXcTestRun(bool absolutePath, List<File> files) {
    if (absolutePath) {
      return files.first.absolute.path;
    }
    return files.first.path;
}

Future<void> buildSubject() async {
      process.listenStdOut((l) => _logger.detail('\t$l')).disposedBy(scope);
      process.listenStdErr((l) => _logger.err('\t$l')).disposedBy(scope);
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        task.complete('Completed building $subject');
      } else if (exitCode == _xcodebuildInterrupted) {
        const cause = 'xcodebuild was interrupted';
        task.fail('Failed to execute tests of $subject ($cause)');
        throwToolInterrupted(cause);
      } else {
        final cause = 'xcodebuild exited with code $exitCode';
        task.fail('Failed to build $subject ($cause)');
        throwToolExit(cause);
      }
}

Future<void> buildSubjectForFrameworkPatch() async {
      if (exitCode == 0) {
        task.complete('Completed building $subject');
      } else if (exitCode == _xcodebuildInterrupted) {
}

  /// Executes the tests of the given [options] on the given [device].
''');
  _patrolCliAppOptionsSourceInPubCache(resolvedPubCache)
    ..createSync(recursive: true)
    ..writeAsStringSync(r'''
    final destination = device.real
        ? 'platform=iOS,id=${device.id}'
        : 'platform=iOS Simulator,id=${device.id},OS=$osVersion';

    final cmd = [
      if (onlyTesting.isNotEmpty)
        for (final selector in onlyTesting) ...[
          '-only-testing',
          'RunnerUITests/$selector',
        ]
      else if (!staticRunner) ...[
        '-only-testing',
        'RunnerUITests/RunnerUITests',
      ],
      ...['-destination', destination],
    ];
        '--no-codesign',
      ...['-sdk', if (simulator) 'iphonesimulator' else 'iphoneos'],
      ...[
        '-destination',
        'generic/platform=${simulator ? 'iOS Simulator' : 'iOS'}',
      ],
      '-quiet',
''');
  File(p.join(resolvedPubCache, 'hosted', 'pub.dev', 'patrol_cli-4.8.0', 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('name: patrol_cli\nversion: 4.8.0\n');
  File(p.join(
      resolvedPubCache, 'hosted', 'pub.dev', 'patrol_cli-4.8.0', 'lib', 'src', 'android', 'android_test_backend.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(r'''
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        task.complete('Completed building $subject');
      } else if (exitCode == exitCodeInterrupted) {
              '--config-only',
''');
  _patrolCliBundlerSourceInPubCache(resolvedPubCache)
    ..createSync(recursive: true)
    ..writeAsStringSync('''
  File getBundledTestFile(String testDirectory, {bool web = false}) => web
      ? _projectRoot.childFile('test_bundle.dart')
      : _projectRoot
            .childDirectory(testDirectory)
            .childFile('test_bundle.dart');
''');
  _fvmBinary(resolvedPubCache)
    ..createSync(recursive: true)
    ..writeAsStringSync('#!/bin/sh\n');
}

void main() {
  late MplatrolShell shell;
  late FileSystem fileSystem;
  late LocalRunner runner;
  late Directory tempRoot;
  late String appFoundationPath;
  late String gradlePath;
  late String workspacePath;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    fileSystem = getDep<FileSystem>();
    runner = LocalRunner();

    tempRoot = Directory.systemTemp.createTempSync('local_runner');
    appFoundationPath = p.join(tempRoot.path, 'app');
    gradlePath = p.join(appFoundationPath, 'android', 'app', 'build.gradle');
    workspacePath = p.join(appFoundationPath, 'ios', 'Runner.xcworkspace');
    final homePath = p.join(tempRoot.path, 'home');
    when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': homePath});
    _writePatchablePatrolCli(home: homePath);
    when(
      () => getDep<IosCodesign>().installedProfileForBundleId(any()),
    ).thenAnswer(
      (invocation) async {
        final bundleId = invocation.positionalArguments.first as String;
        return IosProvisioningProfile(
          path: p.join(tempRoot.path, '$bundleId.mobileprovision'),
          name: '$bundleId Enterprise',
          applicationIdentifier: 'TEAMID1234.$bundleId',
        );
      },
    );
    when(
      () => getDep<IosCodesign>().installedXctrunnerDevelopmentProfile(),
    ).thenAnswer(
      (_) async => IosProvisioningProfile(
        path: p.join(tempRoot.path, 'runner.mobileprovision'),
        name: 'Runner Development',
        applicationIdentifier: 'TEAMID1234.$_iosBundleId.uitests.xctrunner',
      ),
    );
    // A Patrol test fixture so the runner-generation step (run before patrol
    // test) has something to generate from instead of throwing on an empty
    // suite. The generated runner is written under the temp tree and discarded.
    File(p.join(appFoundationPath, _target))
      ..createSync(recursive: true)
      ..writeAsStringSync("patrolTest('sample test', (\$) async {});\n");

    when(fileSystem.getAppDirectory).thenReturn(Directory(appFoundationPath));
    when(() => fileSystem.fileExistsSync(p.join(appFoundationPath, 'android/app/build.gradle.kts'))).thenReturn(false);
    // Android app id source: present and parseable by default.
    when(() => fileSystem.fileExistsSync(gradlePath)).thenReturn(true);
    when(() => fileSystem.readAsStringSync(gradlePath))
        .thenReturn('android { defaultConfig {\napplicationId "$_androidId"\n} }');
    // iOS bundle id source: xcodebuild returns a resolved id by default.
    when(
      () => shell.run(
        any(that: contains('xcodebuild -showBuildSettings')),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: false,
        silent: true,
      ),
    ).thenAnswer((_) async => _result(stdout: '    PRODUCT_BUNDLE_IDENTIFIER = $_iosBundleId\n'));
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        forceVerbose: any(named: 'forceVerbose'),
        quietBuild: any(named: 'quietBuild'),
        surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => _result());
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        silent: any(named: 'silent'),
        surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => _result());
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        forceVerbose: any(named: 'forceVerbose'),
        quietBuild: any(named: 'quietBuild'),
        surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((invocation) async {
      final args = invocation.positionalArguments[1] as List<String>;
      return args.contains(_patchedPatrolCliMain(appFoundationPath))
          ? _successfulIosPatrolResult(appFoundationPath)
          : _result();
    });
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        silent: any(named: 'silent'),
        surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async => _result());
    // A screenrecord segment (the only adb call with cancelOn) ends at once, so the chain stops.
    when(
      () => shell.runArgs('adb', any(),
          throwOnError: false, silent: true, timeout: any(named: 'timeout'), cancelOn: any(named: 'cancelOn')),
    ).thenAnswer((_) async => _result());
    when(
      () => shell.runArgs('adb', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
    ).thenAnswer((_) async => _result(stdout: 'ok\n'));
    when(
      () => shell.runArgs('adb', any(that: contains('sys.boot_completed')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')),
    ).thenAnswer((_) async => _result(stdout: '1\n'));
    when(
      () => shell.runArgs('adb', any(that: contains('ps')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')),
    ).thenAnswer((_) async => _result(stdout: 'ARGS\ninit second_stage\n'));
    when(
      () => shell.runArgs('adb', any(that: contains('get-state')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')),
    ).thenAnswer((_) async => _result(stdout: 'device\n'));
    when(
      () => shell.runArgs('xcrun', any(that: contains('simctl')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')),
    ).thenAnswer((invocation) async {
      final arguments = invocation.positionalArguments[1] as List<String>;
      if (arguments.contains('list')) {
        return _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Booted)
''');
      }
      return _result();
    });
    when(() => shell.runArgs('lsof', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')))
        .thenAnswer((_) async => _result());
    when(() => shell.runArgs(
          'xcrun',
          any(that: contains('summary')),
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        )).thenAnswer((_) async => _passedIosSummary());
    when(() => shell.runArgs(
          'env',
          any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
          workingDirectory: appFoundationPath,
          throwOnError: false,
          quietBuild: any(named: 'quietBuild'),
          surfaceFailureOutput: true,
          timeout: any(named: 'timeout'),
        )).thenAnswer((_) async => _successfulIosPatrolResult(appFoundationPath));
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  test('shared prepared CLI repairs missing Android mode exactly once', () async {
    final command = await runner.preparePatrolCliCommand(appFoundationPath);
    expect(command,
        [_fvmBinary(p.join(tempRoot.path, 'home/.pub-cache')).path, 'dart', _patchedPatrolCliMain(appFoundationPath)]);
    final backend = File(p.join(
        appFoundationPath, '.mplatrol/patched_packages/patrol_cli', 'lib/src/android/android_test_backend.dart'));
    const mode = "              '--\${options.buildMode.androidName.toLowerCase()}',\n";
    expect(backend.readAsStringSync(), contains(mode));
    File(p.join(appFoundationPath, '.mplatrol/patched_packages/patrol_cli', '.dart_tool/package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    final completeTime = backend.statSync().modified;
    expect(await runner.preparePatrolCliCommand(appFoundationPath), command);
    expect(backend.statSync().modified, completeTime);
    backend.writeAsStringSync(backend.readAsStringSync().replaceFirst(mode, ''));
    expect(await runner.preparePatrolCliCommand(appFoundationPath), command);
    expect(backend.readAsStringSync(), contains(mode));
  });

  group('LocalRunner.run', () {
    group('android', () {
      void stubBuildResult(ProcessResultX Function() result) {
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async => result());
      }

      Future<int> runAndroid({bool reuseLast = false}) => runner.run(
            variant: ItVariant.androidLocal,
            deviceId: 'emulator-5554',
            target: _target,
            reuseLast: reuseLast,
            env: const {'MPLATROL_E2E_RECORD_ANDROID': 'false'},
          );

      for (final (output, built) in [
        ('Gradle build failed with code 1', false),
        ('MPLATROL_ANDROID_BUILD_SUCCEEDED\nINSTALL_FAILED_INSUFFICIENT_STORAGE', true),
        ('previous: MPLATROL_ANDROID_BUILD_SUCCEEDED', false),
      ]) {
        test('Android build marker preserves failure: $output', () async {
          stubBuildResult(() => _result(exitCode: 70, stdout: output));
          expect(await runAndroid(), 70);
          expect(runner.androidBuildSucceeded, built);
          final backend = File(p.join(appFoundationPath, '.mplatrol', 'patched_packages', 'patrol_cli', 'lib', 'src',
                  'android', 'android_test_backend.dart'))
              .readAsStringSync();
          expect(backend, contains("_logger.info('MPLATROL_ANDROID_BUILD_SUCCEEDED')"));
        });
      }

      test('stops the biometric responder when the screen recorder cannot start', () async {
        final responder = _MockBiometricResponder();
        when(responder.stop).thenAnswer((_) async {});
        when(() => getDep<LocalBiometrics>().respondOnAndroidEmulator(any())).thenAnswer((_) async => responder);
        when(() => shell.runArgs('adb', ['-s', 'emulator-5554', 'shell', 'ps', '-A', '-o', 'ARGS'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'))).thenThrow(const ProcessException('adb', ['ps'], 'device offline'));
        stubBuildResult(() => _result(stdout: 'MPLATROL_ANDROID_BUILD_SUCCEEDED'));

        await expectLater(runAndroid(), throwsA(isA<ProcessException>()));

        verify(responder.stop).called(1);
      });

      test('Android final failed build resets an earlier success marker', () async {
        var attempt = 0;
        stubBuildResult(() => ++attempt == 1
            ? _result(
                exitCode: 70,
                stdout: 'MPLATROL_ANDROID_BUILD_SUCCEEDED\n',
                stderr: 'Repository maven2 is disabled due to earlier error')
            : _result(exitCode: 70, stderr: 'Gradle build failed with code 1'));
        expect(await runAndroid(), 70);
        expect(attempt, 2);
        expect(runner.androidBuildSucceeded, isFalse);
      });

      test('Android marker is not carried into a later run or reuse-only run', () async {
        stubBuildResult(() => _result(exitCode: 70, stdout: 'MPLATROL_ANDROID_BUILD_SUCCEEDED\n'));
        expect(await runAndroid(), 70);
        expect(runner.androidBuildSucceeded, isTrue);
        stubBuildResult(() => _result(exitCode: 70));
        expect(await runAndroid(), 70);
        expect(runner.androidBuildSucceeded, isFalse);
        expect(await runAndroid(reuseLast: true), ExitCode.software.code);
        expect(runner.androidBuildSucceeded, isNull);
      });

      test('Android timeout keeps current build evidence and failure exit', () async {
        stubBuildResult(() => _result(
            exitCode: ExitCode.tempFail.code,
            stdout: 'MPLATROL_ANDROID_BUILD_SUCCEEDED\n',
            stderr: 'Timed out after 780s: <redacted command>'));
        expect(await runAndroid(), ExitCode.tempFail.code);
        expect(runner.androidBuildSucceeded, isTrue);
      });

      test('concurrent runners share one patched CLI preparation', () async {
        var activations = 0;
        when(() => shell.runArgs(
              'env',
              any(that: contains('activate')),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              silent: true,
            )).thenAnswer((_) async {
          activations++;
          File(p.join(
              appFoundationPath, '.mplatrol', 'patched_packages', 'patrol_cli', '.dart_tool', 'package_config.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync('{"configVersion":2,"packages":[]}');
          return _result();
        });
        final codes = await Future.wait([
          runAndroid(),
          LocalRunner().run(variant: ItVariant.androidLocal, deviceId: 'emulator-5556', target: _target),
        ]);
        expect(codes, [0, 0]);
        expect(activations, 1);
      });
      String androidResultsDir() =>
          p.join(appFoundationPath, 'build', 'app', 'outputs', 'androidTest-results', 'connected', 'debug');

      void writeInstallCommitBrokenPipeReport() {
        File(
          p.join(
            androidResultsDir(),
            'Pixel_9_Pro_XL(AVD) - 17',
            'test-result.textproto',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'Failed to commit install session 1068957628 with command '
            'package install-commit 1068957628. Error: Unknown failure: '
            'cmd: Failure calling service package: Broken pipe (32)',
          );
      }

      void writeInstallPackageChangedReport() {
        File(
          p.join(
            androidResultsDir(),
            'Pixel_9_Pro_XL(AVD) - 17',
            'test-result.textproto',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'Failed to commit install session 1619174363 with command '
            'package install-commit 1619174363. Error: '
            'INSTALL_FAILED_PACKAGE_CHANGED: Package was removed before '
            'install could complete.',
          );
      }

      test('develop mode hands patrol develop the terminal instead of a batch run', () async {
        when(() => shell.runInteractive(any(), any(), workingDirectory: any(named: 'workingDirectory')))
            .thenAnswer((_) async => 9);

        final code = await runner.run(
            variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target, develop: true);

        expect(code, 9);
        final arguments = verify(() => shell.runInteractive('dart', captureAny(), workingDirectory: appFoundationPath))
            .captured
            .single as List<String>;
        expect(
            arguments,
            containsAllInOrder(
                ['exec', 'dart', _patchedPatrolCliMain(appFoundationPath), 'develop', '--target', _target]));
        expect(arguments, isNot(contains('test')));
        verifyNever(() => shell.runArgs('dart', any(that: contains('test')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: any(named: 'throwOnError'),
            quietBuild: any(named: 'quietBuild'),
            surfaceFailureOutput: any(named: 'surfaceFailureOutput')));
      });

      for (final (filter, minutes) in [
        (null, 22),
        ('one|two', 16),
        ('one', 13),
      ]) {
        test('Android Patrol timeout scales with selected tests: $filter', () async {
          File(p.join(appFoundationPath, _target)).writeAsStringSync(
            "patrolTest('one', (\$) async {});\n"
            "patrolTest('two', (\$) async {});\n"
            "patrolTest('three', (\$) async {});\n"
            "patrolTest('four', (\$) async {});\n",
          );

          final code = await runner.run(
            variant: ItVariant.androidLocal,
            deviceId: 'emulator-5554',
            target: _target,
            targetRegex: filter,
          );

          expect(code, ExitCode.success.code);
          final timeouts = verify(() => shell.runArgs(
                'dart',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: true,
                surfaceFailureOutput: true,
                timeout: captureAny(named: 'timeout'),
              )).captured;
          expect(timeouts, [Duration(minutes: minutes)]);
        });
      }

      test('Android Patrol timeout preserves failure and does not recover', () async {
        var attempts = 0;
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          attempts++;
          writeInstallCommitBrokenPipeReport();
          return _result(
            exitCode: ExitCode.tempFail.code,
            stdout: 'Repository maven2 is disabled due to earlier error',
            stderr: 'Timed out after 780s: <redacted command>',
          );
        });

        final code = await runner.run(
          variant: ItVariant.androidLocal,
          deviceId: 'emulator-5554',
          target: _target,
        );

        expect(code, ExitCode.tempFail.code);
        expect(attempts, 1);
        verify(() => getDep<MplatrolLogger>()
            .err(any(that: contains('[patrol-timeout] Local Patrol build/test exceeded 780s')))).called(1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('[build-retry]'))));
        verifyNever(() => shell.runArgs(
              'adb',
              ['-s', 'emulator-5554', 'reboot'],
              throwOnError: false,
              silent: true,
              timeout: any(named: 'timeout'),
            ));
      });

      for (final failureCode in [70, 75]) {
        test('current Android UTP cause is visible in quiet failure $failureCode', () async {
          when(() => shell.runArgs(
                'dart',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: true,
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              )).thenAnswer((_) async {
            // A real build takes time; without it Linux's coarse mtime clock
            // can stamp the report before the attempt start.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            final report = File(p.join(androidResultsDir(), 'device', 'test-result.textproto'));
            await report.create(recursive: true);
            await report.writeAsString('''
platform_error {
  error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
  error_message: "Failed to install APK: INSTALL_FAILED_INSUFFICIENT_STORAGE"
}
''');
            return _result(
                exitCode: failureCode, stderr: failureCode == 75 ? 'Timed out after 780s: <redacted>' : 'failed');
          });

          expect(
              await runner.run(
                variant: ItVariant.androidLocal,
                deviceId: 'emulator-5554',
                target: _target,
              ),
              failureCode);
          verify(() => getDep<MplatrolLogger>()
              .err(any(that: startsWith('[android-utp] INSTALL_FAILED_INSUFFICIENT_STORAGE:')))).called(1);
          verify(() => getDep<MplatrolLogger>().err(any(that: contains('Do not wipe the device automatically'))))
              .called(1);
        });
      }

      test('Android diagnostics do not attribute stale reports to this attempt', () async {
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          File(p.join(androidResultsDir(), 'device', 'test-result.textproto'))
            ..createSync(recursive: true)
            ..writeAsStringSync('''
platform_error {
  error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
  error_message: "Old installer error"
}
''')
            ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
          return _result(exitCode: 7);
        });

        expect(
            await runner.run(
              variant: ItVariant.androidLocal,
              deviceId: 'emulator-5554',
              target: _target,
            ),
            7);
        verifyNever(() => getDep<MplatrolLogger>().err(any(that: startsWith('[android-utp]'))));
      });

      for (final finalCode in [0, 7]) {
        test('Android diagnostics ignore an earlier retry report (exit $finalCode)', () async {
          var attempts = 0;
          when(() => shell.runArgs(
                'dart',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: true,
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              )).thenAnswer((_) async {
            if (++attempts == 1) {
              File(p.join(androidResultsDir(), 'device', 'test-result.textproto'))
                ..createSync(recursive: true)
                ..writeAsStringSync('''
platform_error {
  error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
  error_message: "Earlier attempt's installer error"
}
''');
              return _result(exitCode: 70, stderr: "Could not download 'example-sdk.jar' (connection dropped)");
            }
            return _result(exitCode: finalCode);
          });

          expect(
              await runner.run(
                variant: ItVariant.androidLocal,
                deviceId: 'emulator-5554',
                target: _target,
              ),
              finalCode);
          expect(attempts, 2);
          verifyNever(() => getDep<MplatrolLogger>().err(any(that: startsWith('[android-utp]'))));
        });
      }

      test('build observation occurs after preparation and before each attempt', () async {
        final events = <String>[];
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          events.add('run');
          return events.length == 2
              ? _result(exitCode: 70, stderr: "Could not download 'example-sdk.jar' (connection dropped)")
              : _result();
        });

        final code = await runner.run(
          variant: ItVariant.androidLocal,
          deviceId: 'emulator-5554',
          target: _target,
          targetRegex: 'sample',
          onBuildStarted: () {
            expect(File(p.join(appFoundationPath, 'patrol_test', 'mplatrol_filtered_test.dart')).existsSync(), isTrue);
            events.add('before build');
          },
        );

        expect(code, 0);
        expect(events, ['before build', 'run', 'before build', 'run']);
      });

      test('Android recovery attempt keeps the timeout and cannot retry a hang', () async {
        var attempts = 0;
        final budgets = <Duration>[];
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((invocation) async {
          budgets.add(invocation.namedArguments[#timeout] as Duration);
          if (++attempts == 1) {
            writeInstallCommitBrokenPipeReport();
            return _result(exitCode: ExitCode.software.code);
          }
          return _result(
            exitCode: ExitCode.tempFail.code,
            stderr: 'ActivityNotFoundException: Unable to find explicit activity class\n'
                'Timed out after 780s: <redacted command>',
          );
        });

        final code = await runner.run(
          variant: ItVariant.androidLocal,
          deviceId: 'emulator-5554',
          target: _target,
        );

        expect(code, ExitCode.tempFail.code);
        expect(attempts, 2);
        expect(budgets, [const Duration(minutes: 13), const Duration(minutes: 13)]);
        verifyNever(() => getDep<MplatrolLogger>().err(any(that: contains('not launchable'))));
      });

      test("an upgrade setup leg removes the app first; adb's failure text is logged", () async {
        when(() => shell.runArgs('adb', ['-s', 'emulator-5554', 'uninstall', _androidId],
                throwOnError: false, silent: true, timeout: any(named: 'timeout')))
            .thenAnswer((_) async => _result(exitCode: 1, stderr: 'Failure [DELETE_FAILED_INTERNAL_ERROR]'));

        final code = await runner.run(
            variant: ItVariant.androidLocal,
            deviceId: 'emulator-5554',
            target: _target,
            env: const {e2eUpgradeLegEnv: 'setup'});

        expect(code, ExitCode.success.code);
        verify(() => getDep<MplatrolLogger>().info('[upgrade-from] $_androidId was not removed from emulator-5554 '
            '(exit 1): Failure [DELETE_FAILED_INTERNAL_ERROR]')).called(1);
      });

      test('uses the given device id and the parsed applicationId', () async {
        File(p.join(appFoundationPath, defaultE2eDartDefineFile))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"E2E_ENVIRONMENT": "Dev"}');

        final code = await runner.run(
            variant: ItVariant.androidLocal, deviceId: 'emulator-5554', coverage: true, target: _target);

        expect(code, ExitCode.success.code);
        verify(
          () => getDep<MplatrolLogger>().info(any(that: contains('Generated 1 Android Patrol test method'))),
        ).called(1);
        verify(
          () => shell.runArgs(
            'dart',
            [
              'pub',
              'global',
              'run',
              'fvm:main',
              'exec',
              'dart',
              _patchedPatrolCliMain(appFoundationPath),
              'test',
              '--coverage',
              '--coverage-package=^app\$',
              '--coverage-ignore=**/*.g.dart',
              '--coverage-ignore=**/*.freezed.dart',
              '--coverage-ignore=**/lib/e2e/**',
              '--no-uninstall',
              '--no-label',
              '--target',
              _target,
              '-d',
              'emulator-5554',
              '--package-name',
              _androidId,
              '--dart-define=PATROL_APP_PACKAGE_NAME=$_androidId',
              '--dart-define=E2E_TEST_BRIDGE=true',
              '--dart-define=E2E_ENVIRONMENT=Dev',
            ],
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      group('seeded test order', () {
        setUp(() {
          File(p.join(appFoundationPath, _target)).writeAsStringSync(
            "patrolTest('one', (\$) async {});\n"
            "patrolTest('two', (\$) async {});\n"
            "patrolTest('three', (\$) async {});\n"
            "patrolTest('four', (\$) async {});\n",
          );
          getDep<ItTestOrder>().order = const TestOrder.random(42);
        });
        tearDown(() => getDep<ItTestOrder>().order = const TestOrder.declared(0));

        List<String> androidPatrolArgs() => verify(() => shell.runArgs(
              'env',
              captureAny(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).captured.single as List<String>;

        test('reaches the Android runner as MPLATROL_TEST_ORDER, shuffled by the seed', () async {
          final expected = const TestOrder.random(42)
              .apply(['four', 'one', 'three', 'two'].map((method) => 'PatrolLoginTest.$method').toList());

          final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

          expect(code, ExitCode.success.code);
          expect(androidPatrolArgs().take(4), ['$testOrderEnv=${expected.join(',')}', 'dart', 'pub', 'global']);
          verify(() =>
                  getDep<MplatrolLogger>().info(summariseTestOrder('Android order within each test file', expected)))
              .called(1);
          verify(() => getDep<MplatrolLogger>()
              .detail('[order] Android order within each test file: ${expected.join(', ')}')).called(1);
        });

        test('is not applied when Android keeps app data between tests', () async {
          final code = await runner.run(
              variant: ItVariant.androidLocal,
              deviceId: 'emulator-5554',
              target: _target,
              env: const {e2eKeepAppDataEnv: '1'});

          expect(code, ExitCode.success.code);
          verifyNever(() => shell.runArgs('env', any(),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout')));
          verify(() => getDep<MplatrolLogger>()
                  .info('[order] $e2eKeepAppDataEnv keeps Android tests in name order; the seed is not applied.'))
              .called(1);
        });
      });

      test('routes a USB phone through this Mac and builds with the app proxy enabled', () async {
        File(p.join(appFoundationPath, defaultE2eDartDefineFile))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"E2E_ENVIRONMENT": "Dev"}');
        final egress = getDep<AndroidDeviceEgress>();
        when(() => egress.around<int>(any(), any())).thenAnswer((invocation) {
          final run = invocation.positionalArguments[1] as Future<int> Function(Map<String, String>);
          return run(const {e2eDeviceProxyEnv: 'true'});
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: '54120DLAQ002QN', target: _target);

        expect(code, ExitCode.success.code);
        verify(() => egress.around<int>('54120DLAQ002QN', any())).called(1);
        verify(
          () => shell.runArgs(
            'dart',
            any(that: allOf(contains('54120DLAQ002QN'), contains('--dart-define=E2E_ENABLE_DEVELOPER_PROXY=true'))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('leaves emulators on the Mac network without routing', () async {
        await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        verifyNever(() => getDep<AndroidDeviceEgress>().around<int>(any(), any()));
        verifyNever(
          () => shell.runArgs(
            'dart',
            any(that: contains('--dart-define=E2E_ENABLE_DEVELOPER_PROXY=true')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: any(named: 'throwOnError'),
            quietBuild: any(named: 'quietBuild'),
            surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
            timeout: any(named: 'timeout'),
          ),
        );
      });

      for (final missing in [true, false]) {
        test('unresolved local Android package fails before Patrol missing=$missing', () async {
          if (missing) {
            when(() => fileSystem.fileExistsSync(gradlePath)).thenReturn(false);
          } else {
            when(() => fileSystem.readAsStringSync(gradlePath)).thenReturn('android { defaultConfig {} }');
          }
          final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);
          expect(code, ExitCode.config.code);
          verifyNever(() => shell.runArgs(any(), any(),
              workingDirectory: any(named: 'workingDirectory'),
              throwOnError: any(named: 'throwOnError'),
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
              timeout: any(named: 'timeout')));
        });
      }

      test('returns the patrol exit code on failure', () async {
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.software.code));

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.software.code);
      });

      test('reboots and retries once when package install commit breaks', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          if (patrolRuns == 1) {
            writeInstallCommitBrokenPipeReport();
            return _result(exitCode: ExitCode.software.code);
          }
          return _result();
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(patrolRuns, 2);
        verify(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('reboots and retries once when install package changes', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          if (patrolRuns == 1) {
            writeInstallPackageChangedReport();
            return _result(exitCode: ExitCode.software.code);
          }
          return _result();
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(patrolRuns, 2);
        verify(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('does not reboot from a stale Android install report', () async {
        writeInstallCommitBrokenPipeReport();
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(exitCode: ExitCode.software.code);
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.software.code);
        expect(patrolRuns, 1);
        expect(Directory(androidResultsDir()).existsSync(), isFalse);
        verifyNever(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        );
      });

      test('retries the build once on a transient dependency failure', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          if (patrolRuns == 1) {
            return _result(
              exitCode: ExitCode.software.code,
              stdout: 'Failed to list versions for '
                  'com.adobe.marketing.mobile:core.\n'
                  'Repository maven2 is disabled due to earlier error',
            );
          }
          return _result();
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(patrolRuns, 2);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('[build-retry]')))).called(1);
      });

      test('retries a transient build failure up to the attempt budget', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.software.code,
            stderr: "Could not download 'example-sdk.jar' (connection dropped)",
          );
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.software.code);
        // Initial attempt plus the two build retries, each preceded by a
        // back-off warning.
        expect(patrolRuns, 3);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('[build-retry]')))).called(2);
      });

      test('does not retry a real (non-transient) build failure', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.software.code,
            stderr: "lib/main.dart:3:1: Error: Expected ';' after this.",
          );
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.software.code);
        expect(patrolRuns, 1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('[build-retry]'))));
      });

      test('reports the lesson for a recognized local failure', () async {
        when(() => shell.runArgs(
                  'dart',
                  any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                  workingDirectory: appFoundationPath,
                  throwOnError: false,
                  quietBuild: true,
                  surfaceFailureOutput: true,
                  timeout: any(named: 'timeout'),
                ))
            .thenAnswer((_) async => _result(
                exitCode: 1, stdout: 'texts[Unauthorized network location|Try again later from a secure network.]'));

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, isNot(ExitCode.success.code));
        verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson networkAllowlist (observed 1): '))))
            .called(1);
      });

      test('keeps the full output and results in the leg, and blames a system crash on other adb clients', () async {
        final leg = p.join(tempRoot.path, 'legs', 'globex_android');
        when(() => getDep<PlatformWrapper>().environment)
            .thenReturn({'HOME': p.join(tempRoot.path, 'home'), 'MPLATROL_IT_LEG_DIR': leg});
        when(() => shell.runArgs('adb', any(that: contains('ps')),
                throwOnError: false, silent: true, timeout: any(named: 'timeout')))
            .thenAnswer((_) async => _result(stdout: 'ARGS\nscreenrecord /sdcard/a.mp4\nscreenrecord /sdcard/b.mp4\n'));
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          File(p.join(
              appFoundationPath, 'build/app/outputs/androidTest-results/connected/debug/avd', 'test-result.textproto'))
            ..createSync(recursive: true)
            ..writeAsStringSync('name: "INSTRUMENTATION_FAILED"\n  message: "Expected 31 tests, received 2. '
                'INSTRUMENTATION_ABORTED: System has crashed."');
          return _result(exitCode: 1, stdout: 'line 1 of 2000\nGradle test execution failed with code 1');
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, 1);
        expect(File(p.join(leg, 'build.log')).readAsStringSync(), contains('line 1 of 2000'));
        expect(
            File(p.join(leg, 'android', 'androidTest-results', 'avd', 'test-result.textproto')).existsSync(), isTrue);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('LOCAL_DEVICE_CONTENTION: 2 screenrecord'))))
            .called(1);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('INSTRUMENTATION_ABORTED: System has crashed'))))
            .called(1);
        verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson localDeviceContention')))).called(1);
        verifyNever(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson androidSystemCrashed'))));
      });

      // Regression 2026-10-15 : the leg's own timed-out segment kept recording on the device and was
      // counted as another adb client, so the system crash was blamed on contention for 73 tests.
      test("does not blame a system crash on mplatrol's own leftover recorder", () async {
        final leg = p.join(tempRoot.path, 'legs', 'globex_android');
        when(() => getDep<PlatformWrapper>().environment)
            .thenReturn({'HOME': p.join(tempRoot.path, 'home'), 'MPLATROL_IT_LEG_DIR': leg});
        when(() => shell.runArgs('adb', any(that: contains('ps')),
                throwOnError: false, silent: true, timeout: any(named: 'timeout')))
            .thenAnswer((_) async => _result(
                stdout: 'ARGS\nscreenrecord --time-limit 180 /sdcard/mplatrol-e2e-2026-10-15T08-30-03-seg04.mp4\n'));
        when(() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          File(p.join(
              appFoundationPath, 'build/app/outputs/androidTest-results/connected/debug/avd', 'test-result.textproto'))
            ..createSync(recursive: true)
            ..writeAsStringSync('name: "INSTRUMENTATION_FAILED"\n  message: "Expected 31 tests, received 2. '
                'INSTRUMENTATION_ABORTED: System has crashed."');
          return _result(exitCode: 1, stdout: 'line 1 of 2000\nGradle test execution failed with code 1');
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, 1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('LOCAL_DEVICE_CONTENTION'))));
        verify(() => getDep<MplatrolLogger>().info(any(that: contains('stopped a leftover mplatrol screenrecord'))))
            .called(greaterThanOrEqualTo(1));
        verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson androidSystemCrashed')))).called(1);
        verifyNever(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson localDeviceContention'))));
      });

      test('waits for boot to complete after a reboot before running tests', () async {
        // One readiness check, then the 30-poll framework wait, all before the reboot.
        const bootChecksBeforeReboot = 31;
        var bootChecks = 0;
        var rebooted = false;
        when(
          () => shell.runArgs('adb', ['-s', 'emulator-5554', 'reboot'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async {
          rebooted = true;
          return _result();
        });
        when(
          () => shell.runArgs('adb', ['-s', 'emulator-5554', 'shell', 'getprop', 'sys.boot_completed'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async {
          bootChecks++;
          // Wedged before the reboot; still booting for two polls after it, then booted.
          if (!rebooted) {
            return _result(stdout: '0\n');
          }
          return _result(stdout: bootChecks > bootChecksBeforeReboot + 2 ? '1\n' : '\n');
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(rebooted, isTrue);
        // Two still-booting polls, the booted one, and the online check right before Gradle.
        expect(bootChecks, bootChecksBeforeReboot + 4);
      });

      group('online right before Gradle', () {
        const offline = 'error: device offline';
        late List<String> states;

        setUp(() {
          states = [];
          when(
            () => shell.runArgs('adb', any(that: contains('get-state')),
                throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          ).thenAnswer((invocation) async {
            final state = states.isEmpty ? 'device' : states.removeAt(0);
            return state.startsWith('error: ')
                ? _result(exitCode: 1, stderr: '$state\n')
                : _result(stdout: state.isEmpty ? '' : '$state\n');
          });
          when(
            () => shell.runArgs('adb', ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
                throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          ).thenAnswer((_) async => _result(stdout: 'mplatrol_e2e_pixel9\nOK\n'));
        });

        Future<ProcessResultX> gradle() => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            );

        void verifyReconnects(String serial, int times) => verify(
              () => shell.runArgs('adb', ['-s', serial, 'reconnect'],
                  throwOnError: false, silent: true, timeout: any(named: 'timeout')),
            ).called(times);

        test('reconnects an emulator left offline after reboot instead of letting Gradle lose it', () async {
          states = [offline, offline, offline];

          final code = await runAndroid();

          expect(code, ExitCode.success.code);
          verifyReconnects('emulator-5554', 1);
          verifyNever(() => shell.startDetached(any(), any()));
          verifyNever(() => shell.runArgs('adb', any(that: contains('54120DLAQ002QN')),
              throwOnError: any(named: 'throwOnError'), silent: any(named: 'silent'), timeout: any(named: 'timeout')));
          verify(() => getDep<MplatrolLogger>()
              .warn(any(that: contains('emulator-5554 is not ready (device offline) right before Gradle')))).called(1);
          verify(gradle).called(1);
        });

        test('cold-starts the same AVD without its snapshot when reconnect does not bring it back', () async {
          states = List.filled(13, offline, growable: true);

          final code = await runAndroid();

          expect(code, ExitCode.success.code);
          verifyReconnects('emulator-5554', 1);
          verifyInOrder([
            () => shell.runArgs('adb', ['-s', 'emulator-5554', 'emu', 'kill'],
                throwOnError: false, silent: true, timeout: any(named: 'timeout')),
            () => shell.startDetached('emulator', ['-avd', 'mplatrol_e2e_pixel9', '-no-snapshot-load']),
          ]);
          verify(gradle).called(1);
        });

        test('fails fast as a device failure when the emulator stays offline after a cold start', () async {
          states = List.filled(14, offline, growable: true);

          final code = await runAndroid();

          expect(code, ExitCode.unavailable.code);
          verifyNever(gradle);
          verify(() => getDep<MplatrolLogger>().err(any(
              that: allOf(contains('ANDROID_DEVICE_NOT_READY: emulator-5554 is not ready (device offline)'),
                  contains('mplatrol devices --setup'))))).called(1);
          verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson emulatorOffline')))).called(1);
        });

        test('fails fast when the cold start itself fails', () async {
          states = List.filled(13, 'error: device unauthorized.', growable: true);
          when(() => shell.startDetached('emulator', any())).thenThrow(const ProcessException('emulator', []));

          final code = await runAndroid();

          expect(code, ExitCode.unavailable.code);
          verifyNever(gradle);
          verify(() => getDep<MplatrolLogger>()
              .err(any(that: contains('emulator-5554 is not ready (device unauthorized.) before Gradle')))).called(1);
        });

        for (final (state, problem) in [
          ('', 'not answering adb (exit 0)'),
          ('bootloader', 'bootloader'),
          ("error: device 'emulator-5554' not found", "device 'emulator-5554' not found"),
        ]) {
          test('names the adb state "$problem" when the emulator never comes back', () async {
            states = List.filled(14, state, growable: true);
            when(() => shell.startDetached('emulator', any())).thenThrow(const ProcessException('emulator', []));

            expect(await runAndroid(), ExitCode.unavailable.code);
            verify(() => getDep<MplatrolLogger>().err(any(that: contains('is not ready ($problem) before Gradle'))))
                .called(1);
          });
        }

        test('reports an emulator that is online but not booted after its cold start', () async {
          var booted = true;
          var bootChecks = 0;
          states = List.filled(13, offline, growable: true);
          when(
            () => shell.runArgs('adb', ['-s', 'emulator-5554', 'shell', 'getprop', 'sys.boot_completed'],
                throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          ).thenAnswer((_) async {
            bootChecks++;
            // Ready for _ensureAndroidDeviceReady and the cold-start framework wait, then unset.
            if (bootChecks > 2) {
              booted = false;
            }
            return _result(stdout: booted ? '1\n' : '\n');
          });

          expect(await runAndroid(), ExitCode.unavailable.code);
          verifyNever(gradle);
          verify(() => getDep<MplatrolLogger>()
                  .err(any(that: contains('is not ready (not booted (sys.boot_completed=unset)) before Gradle'))))
              .called(1);
        });

        test('never reconnects or reboots a physical device that is not ready', () async {
          when(
            () => shell.runArgs('adb', ['-s', '54120DLAQ002QN', 'get-state'],
                throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          ).thenAnswer((_) async => _result(exitCode: 1, stderr: 'error: device unauthorized.\n'));

          final code = await runner.run(
            variant: ItVariant.androidLocal,
            deviceId: '54120DLAQ002QN',
            target: _target,
            env: const {'MPLATROL_E2E_RECORD_ANDROID': 'false'},
          );

          expect(code, ExitCode.unavailable.code);
          verifyNever(gradle);
          verifyNever(() => shell.runArgs('adb', any(that: anyOf(contains('reconnect'), contains('reboot'))),
              throwOnError: any(named: 'throwOnError'), silent: any(named: 'silent'), timeout: any(named: 'timeout')));
          verify(() => getDep<MplatrolLogger>().err(any(
              that: allOf(contains('ANDROID_DEVICE_NOT_READY: 54120DLAQ002QN is not ready (device unauthorized.)'),
                  contains('accept the USB debugging prompt'))))).called(1);
        });

        test('stops before the install-recovery rerun when the rebooted emulator stays offline', () async {
          var patrolRuns = 0;
          when(
            () => shell.runArgs(
              'dart',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: any(named: 'workingDirectory'),
              throwOnError: false,
              quietBuild: true,
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            ),
          ).thenAnswer((_) async {
            patrolRuns++;
            writeInstallCommitBrokenPipeReport();
            states = List.filled(14, offline, growable: true);
            return _result(exitCode: ExitCode.software.code);
          });

          expect(await runAndroid(), ExitCode.unavailable.code);
          expect(patrolRuns, 1);
          verify(() => shell.runArgs('adb', ['-s', 'emulator-5554', 'reboot'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout'))).called(1);
        });
      });

      test('waits for a just-booted emulator instead of rebooting it', () async {
        var packageChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => ++packageChecks <= 3
            ? _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package")
            : _result(stdout: 'package:android\n'));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'activity', 'get-current-user'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: '0\n'));

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(packageChecks, 4);
        verify(() => getDep<MplatrolLogger>()
            .info(any(that: contains('not answering on emulator-5554 yet; waiting up to 60s')))).called(1);
        verifyNever(() => shell.runArgs('adb', ['-s', 'emulator-5554', 'reboot'],
            throwOnError: any(named: 'throwOnError'), silent: any(named: 'silent'), timeout: any(named: 'timeout')));
      });

      test('reboots an emulator once when Android services are unavailable', () async {
        var packageChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          packageChecks++;
          if (packageChecks <= _wedgedFrameworkChecks) {
            return _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package");
          }
          return _result(stdout: 'package:android\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'activity', 'get-current-user'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: '0\n'));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(packageChecks, _wedgedFrameworkChecks + 1);
        verify(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
        verify(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('reboots an emulator whose service list hangs', () async {
        var serviceListChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'service', 'list'],
            throwOnError: false,
            silent: true,
            timeout: const Duration(seconds: 15),
          ),
        ).thenAnswer((_) async {
          serviceListChecks++;
          if (serviceListChecks <= _wedgedFrameworkChecks) {
            return _result(exitCode: ExitCode.tempFail.code, stderr: 'Timed out after 15s: adb shell service list');
          }
          return _result(stdout: 'Found 314 services:\n');
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(serviceListChecks, _wedgedFrameworkChecks + 1);
        verify(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('bounds adb checks while recovering Android framework services', () async {
        var packageChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          packageChecks++;
          if (packageChecks < 3) {
            return _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package");
          }
          return _result(stdout: 'package:android\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        verify(
          () => shell.runArgs(
            'adb',
            any(),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout', that: isNotNull),
          ),
        ).called(greaterThanOrEqualTo(3));
      });

      test('cold-starts an emulator when reboot leaves Android unbooted', () async {
        var packageChecks = 0;
        var activityChecks = 0;
        var deviceListChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          packageChecks++;
          if (packageChecks <= _wedgedFrameworkChecks) {
            return _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package");
          }
          return _result(stdout: 'package:android\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'activity', 'get-current-user'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          activityChecks++;
          if (activityChecks <= 30) {
            return _result(exitCode: ExitCode.tempFail.code);
          }
          return _result(stdout: '0\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: 'Pixel_9_Pro_XL\nOK\n'));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'kill'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async {
          deviceListChecks++;
          return _result(
            stdout: deviceListChecks == 1
                ? 'List of devices attached\nemulator-5554\tdevice\n'
                : 'List of devices attached\n',
          );
        });

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        expect(deviceListChecks, 2);
        verifyInOrder([
          () => shell.runArgs(
                'adb',
                ['-s', 'emulator-5554', 'emu', 'kill'],
                throwOnError: false,
                silent: true,
                timeout: any(named: 'timeout'),
              ),
          () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
          () => shell.startDetached('emulator', ['-avd', 'Pixel_9_Pro_XL', '-no-snapshot-load']),
        ]);
        verify(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('falls back to an available Pixel AVD when emulator name is gone', () async {
        var packageChecks = 0;
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          packageChecks++;
          if (packageChecks <= _wedgedFrameworkChecks) {
            return _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package");
          }
          return _result(stdout: 'package:android\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        when(
          () => shell.runArgs(
            'emulator',
            ['-list-avds'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: 'Medium_Phone_API_36.0\nPixel_9_Pro_XL\nmplatrol_e2e_pixel9\n'));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'kill'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        var adbDevicesCalls = 0;
        when(
          () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async {
          adbDevicesCalls++;
          if (adbDevicesCalls == 1) {
            return _result(stdout: 'List of devices attached\n');
          }
          return _result(stdout: 'List of devices attached\nemulator-5554\tdevice\n');
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.success.code);
        verify(() => shell.startDetached('emulator', ['-avd', 'mplatrol_e2e_pixel9', '-no-snapshot-load'])).called(1);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('using the spec AVD "mplatrol_e2e_pixel9"'))))
            .called(1);
      });

      test(
          'returns the original patrol failure when install recovery cannot '
          'resolve an AVD', () async {
        when(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          writeInstallCommitBrokenPipeReport();
          return _result(exitCode: ExitCode.software.code);
        });
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        when(
          () => shell.runArgs(
            'emulator',
            ['-list-avds'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.software.code);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('could not resolve the AVD name')))).called(1);
      });

      test('logs and fails when cold-start cannot launch the resolved AVD', () async {
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer(
          (_) async => _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package"),
        );
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: 'Pixel_9_Pro_XL\nOK\n'));
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'emulator-5554', 'emu', 'kill'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: 'List of devices attached\nemulator-5554\tdevice\n'));
        when(() => shell.startDetached('emulator', any())).thenThrow(const ProcessException('emulator', [], 'boom'));

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

        expect(code, ExitCode.unavailable.code);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('was still listed by adb')))).called(1);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed to cold-start AVD')))).called(1);
      });

      test('does not reboot physical devices with unavailable services', () async {
        when(
          () => shell.runArgs(
            'adb',
            ['-s', 'R3CN30ABCDE', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer(
          (_) async => _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package"),
        );

        final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'R3CN30ABCDE', target: _target);

        expect(code, ExitCode.unavailable.code);
        verifyNever(
          () => shell.runArgs(
            'adb',
            any(that: contains('reboot')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        );
        verifyNever(
          () => shell.runArgs(
            'dart',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        );
      });
    });

    group('ios', () {
      for (final (output, processCode, expectedBuild) in [
        ('MPLATROL_IOS_BUILD_SUCCEEDED\nFailed: 1', 65, true),
        ('MPLATROL_IOS_BUILD_SUCCEEDED\nAll tests: Skipped: 2 done', 0, true),
        ('Failed to build app\nFailed: 1', 65, false),
        ('Test summary:\nFailed: 1', 65, false),
      ]) {
        test('tracks current iOS build independently of test exit: $output', () async {
          Directory(p.join(appFoundationPath, 'build', 'stale.xcresult')).createSync(recursive: true);
          File(p.join(appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'stale.xctestrun'))
            ..createSync(recursive: true)
            ..writeAsStringSync('MPLATROL_IOS_BUILD_SUCCEEDED');
          when(() => shell.runArgs(
                'env',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: any(named: 'quietBuild'),
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              )).thenAnswer((_) async => _result(exitCode: processCode, stdout: output));

          final code = await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: 'physical-device',
            target: _target,
          );

          expect(code, processCode == 0 ? ExitCode.software.code : processCode);
          expect(runner.iosBuildSucceeded, expectedBuild);
          expect(_patchedPatrolCliSource(appFoundationPath).readAsStringSync(),
              contains("_logger.info('MPLATROL_IOS_BUILD_SUCCEEDED');"));
        });
      }

      test('links Flutter.framework into RunnerUITests before a simulator build', () async {
        final pods = File(p.join(appFoundationPath, 'ios', 'Pods', 'Target Support Files', 'Pods-Runner-RunnerUITests',
            'Pods-Runner-RunnerUITests.debug.xcconfig'))
          ..createSync(recursive: true)
          ..writeAsStringSync('OTHER_LDFLAGS = \$(inherited) -ObjC\n');
        File(p.join(appFoundationPath, 'ios', 'Flutter', 'Generated.xcconfig'))
          ..createSync(recursive: true)
          ..writeAsStringSync('FLUTTER_ROOT=/fvm/versions/3.41.6\n');

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(pods.readAsStringSync(),
            contains('MPLATROL_SIM_FLUTTER_LDFLAGS[sdk=iphonesimulator*] = -framework Flutter'));
        verify(() => getDep<MplatrolLogger>()
            .info(any(that: startsWith('[ios-sim-link] RunnerUITests links Flutter.framework')))).called(1);
      });

      test('routes a physical iPhone through this Mac but leaves simulators alone', () async {
        final egress = getDep<IosDeviceEgress>();

        await runner.run(variant: ItVariant.iosLocal, deviceId: '00008140-000435880C8B001C', target: _target);
        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(() => egress.around<int>('00008140-000435880C8B001C', any())).called(1);
        verifyNever(() => egress.around<int>('11111111-2222-3333-4444-555555555555', any()));
        verifyNever(() => getDep<AndroidDeviceEgress>().around<int>(any(), any()));
      });

      test('final simulator retry build failure supersedes an earlier build', () async {
        var attempts = 0;
        when(() => shell.runArgs(
              'env',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async => _result(
              exitCode: 65,
              stdout: attempts++ == 0 ? 'MPLATROL_IOS_BUILD_SUCCEEDED\nSimulator disconnected' : 'Failed to build app',
            ));

        final code = await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: '11111111-2222-3333-4444-555555555555',
          target: _target,
        );

        expect(code, 65);
        expect(attempts, 2);
        expect(runner.iosBuildSucceeded, isFalse);
      });

      test('reuse-only run clears a previous fresh iOS build signal', () async {
        when(() => shell.runArgs(
              'env',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async => _result(exitCode: 65, stdout: 'MPLATROL_IOS_BUILD_SUCCEEDED'));
        await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: 'physical-device',
          target: _target,
        );
        expect(runner.iosBuildSucceeded, isTrue);

        final code = await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: 'physical-device',
          target: null,
          reuseLast: true,
        );

        expect(code, ExitCode.usage.code);
        expect(runner.iosBuildSucceeded, isNull);
      });

      test('copies and patches patrol_cli in the app repo', () async {
        final home = p.join(tempRoot.path, 'home');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home});
        _writePatchablePatrolCli(home: home);

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        final patchedSource = _patchedPatrolCliSource(appFoundationPath).readAsStringSync();
        expect(patchedSource, contains('mplatrol-patch: prefer complete xctestrun'));
        expect(patchedSource, contains('whereType<File>()'));
        expect(patchedSource, contains('<key>TestBundlePath</key>'));
        expect(patchedSource, contains('<key>TestHostPath</key>'));
        expect(
          _patchedPatrolCliAppOptionsSource(appFoundationPath).readAsStringSync(),
          contains('RunnerUITests/LoginE2ETests'),
        );
        final patchedAppOptions = _patchedPatrolCliAppOptionsSource(appFoundationPath).readAsStringSync();
        expect(patchedAppOptions, contains("'platform=iOS Simulator,id=\${device.id}';"));
        expect(patchedAppOptions, isNot(contains('OS=\$osVersion')));
        expect(patchedAppOptions, isNot(contains('RunnerUITests/RunnerUITests')));
        verify(
          () => shell.runArgs(
            'env',
            any(that: contains('PUB_CACHE=${_patchedPubCache(appFoundationPath)}')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            silent: true,
          ),
        ).called(1);
      });

      test('reuses an already patched and activated repo-local patrol_cli', () async {
        final home = p.join(tempRoot.path, 'home');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home});
        _writePatchablePatrolCli(home: home);

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        // The activate step produces the repo-local package config; recreate it
        // so the second run sees a complete patched copy to reuse.
        File(p.join(
            appFoundationPath, '.mplatrol', 'patched_packages', 'patrol_cli', '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(
          () => getDep<MplatrolLogger>().info(any(that: contains('reusing repo-local patched patrol_cli'))),
        ).called(1);
        // The activation only runs for the first (unpatched) preparation.
        verify(
          () => shell.runArgs(
            'env',
            any(that: contains('PUB_CACHE=${_patchedPubCache(appFoundationPath)}')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            silent: true,
          ),
        ).called(1);
      });

      test('rebuilds a repo-local patched patrol_cli from another version', () async {
        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);
        final patchedPackage = p.join(appFoundationPath, '.mplatrol', 'patched_packages', 'patrol_cli');
        File(p.join(patchedPackage, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        final patchedPubspec = File(p.join(patchedPackage, 'pubspec.yaml'))
          ..writeAsStringSync('name: patrol_cli\nversion: 4.4.0\n');

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verifyNever(
          () => getDep<MplatrolLogger>().info(any(that: contains('reusing repo-local patched patrol_cli'))),
        );
        expect(patchedPubspec.readAsStringSync(), contains('version: 4.8.0'));
        verify(
          () => shell.runArgs(
            'env',
            any(that: contains('PUB_CACHE=${_patchedPubCache(appFoundationPath)}')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            silent: true,
          ),
        ).called(2);
      });

      test('replaces an existing repo-local patched patrol_cli copy', () async {
        final staleFile = File(p.join(appFoundationPath, '.mplatrol', 'patched_packages', 'patrol_cli', 'stale.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('stale');

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(staleFile.existsSync(), isFalse);
        expect(
          _patchedPatrolCliSource(appFoundationPath).readAsStringSync(),
          contains('mplatrol-patch: prefer complete xctestrun'),
        );
      });

      test('reads patrol_cli from PUB_CACHE when it is set', () async {
        final home = p.join(tempRoot.path, 'home');
        final pubCache = p.join(tempRoot.path, 'custom-pub-cache');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home, 'PUB_CACHE': pubCache});
        _writePatchablePatrolCli(pubCache: pubCache);

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(
          _patchedPatrolCliSource(appFoundationPath).readAsStringSync(),
          contains('mplatrol-patch: prefer complete xctestrun'),
        );
        expect(
          _patchedPatrolCliAppOptionsSource(appFoundationPath).readAsStringSync(),
          contains('RunnerUITests/LoginE2ETests'),
        );
      });

      test('returns software when patrol_cli sources are missing', () async {
        final home = p.join(tempRoot.path, 'home');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home});
        Directory(p.join(home, '.pub-cache')).deleteSync(recursive: true);

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        verify(
          () => getDep<MplatrolLogger>().err(any(that: contains('source not found'))),
        ).called(greaterThanOrEqualTo(1));
      });

      test('returns software when a copied patrol_cli patch target is missing', () async {
        final home = p.join(tempRoot.path, 'home');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home});
        _patrolCliAppOptionsSource(home).deleteSync();

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('source not found in repo-local copy'))))
            .called(greaterThanOrEqualTo(1));
      });

      test('returns software when patched patrol_cli activation fails', () async {
        when(
          () => shell.runArgs(
            'env',
            any(that: allOf(contains('global'), contains('activate'))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            silent: true,
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.software.code));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        verify(
          () => getDep<MplatrolLogger>().err(any(that: contains('failed to activate repo-local patrol_cli'))),
        ).called(1);
      });

      test('returns software when patrol_cli sources have an unknown shape', () async {
        final home = p.join(tempRoot.path, 'home');
        final platform = getDep<PlatformWrapper>();
        when(() => platform.environment).thenReturn({'HOME': home});
        _patrolCliSource(home)
          ..createSync(recursive: true)
          ..writeAsStringSync('String selectXcTestRun() => "unexpected";');
        _patrolCliAppOptionsSource(home)
          ..createSync(recursive: true)
          ..writeAsStringSync('final args = <String>["unexpected"];');

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('shape changed'))))
            .called(greaterThanOrEqualTo(1));
      });

      test('scales the local iOS patrol timeout with the selected test count', () async {
        File(p.join(appFoundationPath, _target)).writeAsStringSync(
          "patrolTest('one', (\$) async {});\n"
          "patrolTest('two', (\$) async {});\n"
          "patrolTest('three', (\$) async {});\n"
          "patrolTest('four', (\$) async {});\n",
        );

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        final timeouts = verify(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            forceVerbose: any(named: 'forceVerbose'),
            quietBuild: any(named: 'quietBuild'),
            surfaceFailureOutput: true,
            timeout: captureAny(named: 'timeout'),
          ),
        ).captured;
        // 10 minute build allowance + 3 minutes for each of the 4 tests.
        expect(timeouts, [const Duration(minutes: 22)]);
      });

      group('own Patrol bundle', () {
        late File androidBundle;
        late File androidWrapper;
        late List<List<String>> patrolRuns;

        List<String> bundleTargets(List<String> args) => [
              for (var i = 0; i < args.length - 1; i++)
                if (args[i] == '--target') args[i + 1],
            ];

        setUp(() {
          final testDir = p.join(appFoundationPath, 'patrol_test');
          File(p.join(testDir, 'login_faults_test.dart'))
              .writeAsStringSync("patrolTest('fault case', (\$) async {});\n");
          androidBundle = File(p.join(testDir, 'test_bundle.dart'))..writeAsStringSync('// android bundle');
          androidWrapper = File(p.join(testDir, 'mplatrol_filtered_test.dart'))
            ..writeAsStringSync('// android wrapper');
          patrolRuns = [];
          // The concurrent local Android arm of `mplatrol run all` regenerates
          // Patrol's shared bundle and its filtered wrapper mid iOS build.
          when(() => shell.runArgs(
                'env',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                forceVerbose: any(named: 'forceVerbose'),
                quietBuild: any(named: 'quietBuild'),
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              )).thenAnswer((invocation) async {
            patrolRuns.add(invocation.positionalArguments[1] as List<String>);
            expect(androidWrapper.readAsStringSync(), '// android wrapper');
            androidBundle.writeAsStringSync('// android rebuilt bundle');
            androidWrapper.writeAsStringSync('// android rebuilt wrapper');
            return _successfulIosPatrolResult(appFoundationPath);
          });
        });

        // Regression: `mplatrol run all` builds local iOS concurrently with
        // local Android. iOS used to retarget and compile Patrol's shared
        // test_bundle.dart around mplatrol_filtered_test.dart, so it could build
        // Android's selection or lose the wrapper Android was compiling.
        test('filtered iOS compiles only its own selection, not Android files', () async {
          final code = await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: '11111111-2222-3333-4444-555555555555',
            target: null,
            targetRegex: 'sample',
          );

          expect(code, ExitCode.success.code);
          final args = patrolRuns.single;
          expect(args, contains('-D$patrolTestBundleDefine=$iosPatrolTestBundleFile'));
          expect(args.indexOf('-D$patrolTestBundleDefine=$iosPatrolTestBundleFile'),
              lessThan(args.indexOf(_patchedPatrolCliMain(appFoundationPath))));
          expect(bundleTargets(args), [_target]);
          expect(androidBundle.readAsStringSync(), '// android rebuilt bundle');
          expect(androidWrapper.readAsStringSync(), '// android rebuilt wrapper');
          verifyNever(() => getDep<MplatrolLogger>().info(any(that: contains('[bundle] local filtered run target'))));
        });

        test('unfiltered iOS bundles every selected file and keeps the wrapper', () async {
          final code = await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: '11111111-2222-3333-4444-555555555555',
            target: null,
          );

          expect(code, ExitCode.success.code);
          expect(bundleTargets(patrolRuns.single), [
            'patrol_test/login_faults_test.dart',
            _target,
          ]);
          expect(androidWrapper.existsSync(), isTrue);
          expect(androidWrapper.readAsStringSync(), '// android rebuilt wrapper');
        });

        test('Android still owns the shared bundle and filtered wrapper', () async {
          await runner.run(
            variant: ItVariant.androidLocal,
            deviceId: 'emulator-5554',
            target: null,
          );

          expect(androidWrapper.existsSync(), isFalse);
        });

        test('patched patrol_cli names its bundle from the define', () async {
          await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: '11111111-2222-3333-4444-555555555555',
            target: _target,
          );

          final bundler = _patchedPatrolCliBundlerSource(appFoundationPath).readAsStringSync();
          expect(
            bundler,
            contains('const String.fromEnvironment(\n'
                "                '$patrolTestBundleDefine',\n"
                "                defaultValue: 'test_bundle.dart',"),
          );
          expect(bundler, isNot(contains(".childFile('test_bundle.dart');")));
        });

        test('refuses an unknown patrol_cli bundler shape', () async {
          _patrolCliBundlerSourceInPubCache(p.join(tempRoot.path, 'home', '.pub-cache'))
              .writeAsStringSync('File getBundledTestFile() => unexpected;');

          final code = await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: '11111111-2222-3333-4444-555555555555',
            target: _target,
          );

          expect(code, ExitCode.software.code);
          expect(patrolRuns, isEmpty);
          verify(() => getDep<MplatrolLogger>().err(any(that: contains('bundle file name define shape changed'))))
              .called(1);
        });
      });

      test('hands a seeded random order to XCTest through TEST_RUNNER_MPLATROL_TEST_ORDER', () async {
        File(p.join(appFoundationPath, _target)).writeAsStringSync(
          "patrolTest('one', (\$) async {});\n"
          "patrolTest('two', (\$) async {});\n"
          "patrolTest('three', (\$) async {});\n"
          "patrolTest('four', (\$) async {});\n",
        );
        getDep<ItTestOrder>().order = const TestOrder.random(42);
        addTearDown(() => getDep<ItTestOrder>().order = const TestOrder.declared(0));
        final expected = const TestOrder.random(42).apply(['testAFour', 'testAOne', 'testAThree', 'testATwo']);

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        final args = verify(() => shell.runArgs(
              'env',
              captureAny(that: contains('ONLY_ACTIVE_ARCH=YES')),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              forceVerbose: any(named: 'forceVerbose'),
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).captured.single as List<String>;
        expect(args.take(2), ['ONLY_ACTIVE_ARCH=YES', 'TEST_RUNNER_$testOrderEnv=${expected.join(',')}']);
        verify(() => getDep<MplatrolLogger>().info(summariseTestOrder('iOS run order', expected))).called(1);
        verify(() => getDep<MplatrolLogger>().detail('[order] iOS run order: ${expected.join(', ')}')).called(1);
      });

      test('bakes COVERAGE_ENABLED into the xcconfig dart-defines only for a coverage run', () async {
        Future<String> debugXcconfig({required bool coverage}) async {
          await runner.run(
              variant: ItVariant.iosLocal,
              deviceId: '11111111-2222-3333-4444-555555555555',
              coverage: coverage,
              target: _target);
          return File(p.join(appFoundationPath, 'ios', 'Flutter', 'Debug.xcconfig')).readAsStringSync();
        }

        expect(await debugXcconfig(coverage: false), isNot(contains(_encodedDefine('COVERAGE_ENABLED=true'))));
        expect(await debugXcconfig(coverage: true), contains(_encodedDefine('COVERAGE_ENABLED=true')));
      });

      group('upgrade legs', () {
        const simulator = '11111111-2222-3333-4444-555555555555';

        List<String> patrolArguments() => verify(() => shell.runArgs(
              'env',
              captureAny(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              forceVerbose: any(named: 'forceVerbose'),
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).captured.single as List<String>;

        test('the setup leg removes the app first and leaves the previous release installed', () async {
          final code = await runner.run(
              variant: ItVariant.iosLocal,
              deviceId: simulator,
              target: _target,
              env: const {e2eUpgradeLegEnv: 'setup'});

          expect(code, ExitCode.success.code);
          verify(() => shell.runArgs('xcrun', ['simctl', 'uninstall', simulator, _iosBundleId],
              throwOnError: false, silent: true, timeout: any(named: 'timeout'))).called(1);
          verify(() => getDep<MplatrolLogger>()
                  .info('[upgrade-from] removed $_iosBundleId from $simulator before installing the previous release'))
              .called(1);
          expect(patrolArguments(), contains('--no-uninstall'));
          expect(File(p.join(appFoundationPath, 'ios', 'Flutter', 'Debug.xcconfig')).readAsStringSync(),
              contains(_encodedDefine('$e2eUpgradeLegDefine=setup')));
        });

        test('the verify leg installs over the previous release without removing it', () async {
          await runner.run(
              variant: ItVariant.iosLocal,
              deviceId: simulator,
              target: _target,
              env: const {e2eUpgradeLegEnv: 'verify'});

          verifyNever(() => shell.runArgs('xcrun', ['simctl', 'uninstall', simulator, _iosBundleId],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')));
          expect(patrolArguments(), contains('--no-uninstall'));
        });

        test('a physical iPhone setup leg removes the app with devicectl and logs a failed removal', () async {
          when(() => shell.runArgs('xcrun', any(that: contains('devicectl')),
                  throwOnError: false, silent: true, timeout: any(named: 'timeout')))
              .thenAnswer((_) async => _result(exitCode: 1, stdout: 'app not installed'));

          await runner.run(
              variant: ItVariant.iosLocal,
              deviceId: 'REAL-IOS-DEVICE',
              target: _target,
              env: const {e2eUpgradeLegEnv: 'setup'});

          verify(() => shell.runArgs(
              'xcrun', ['devicectl', 'device', 'uninstall', 'app', '--device', 'REAL-IOS-DEVICE', _iosBundleId],
              throwOnError: false, silent: true, timeout: any(named: 'timeout'))).called(1);
          verify(() => getDep<MplatrolLogger>().info(
                  '[upgrade-from] $_iosBundleId was not removed from REAL-IOS-DEVICE (exit 1): app not installed'))
              .called(1);
        });
      });

      test('uses the given device id and the resolved bundle id', () async {
        final debugXcconfig = File(p.join(appFoundationPath, 'ios', 'Flutter', 'Debug.xcconfig'))
          ..createSync(recursive: true)
          ..writeAsStringSync('OTHER_SETTING=true\nDART_DEFINES=ZHVtbXk=\n');

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        verify(() => getDep<MplatrolLogger>().info(any(that: contains('Generated 1 iOS Patrol test method'))))
            .called(1);
        expect(
          File(p.join(appFoundationPath, 'ios', 'RunnerUITests', 'RunnerUITests.swift')).readAsStringSync(),
          contains('static let targetBundleId = "$_iosBundleId"'),
        );
        for (final name in ['Debug.xcconfig', 'Profile.xcconfig', 'Release.xcconfig']) {
          final xcconfig = File(p.join(appFoundationPath, 'ios', 'Flutter', name)).readAsStringSync();
          expect(xcconfig, contains('DART_DEFINES='));
          expect(xcconfig, contains(_encodedDefine('E2E_TEST_BRIDGE=true')));
          expect(xcconfig, contains(_encodedDefine('PATROL_HOST=127.0.0.1')));
          expect(xcconfig, contains(_encodedDefine('PATROL_APP_BUNDLE_ID=$_iosBundleId')));
        }
        expect(debugXcconfig.readAsStringSync(), contains('OTHER_SETTING=true'));
        expect(debugXcconfig.readAsStringSync(), isNot(contains('ZHVtbXk=')));
        verify(
          () => shell.runArgs(
            'env',
            [
              'ONLY_ACTIVE_ARCH=YES',
              _fvmBinary(p.join(tempRoot.path, 'home', '.pub-cache')).path,
              'dart',
              '-D$patrolTestBundleDefine=$iosPatrolTestBundleFile',
              _patchedPatrolCliMain(appFoundationPath),
              'test',
              '--no-label',
              '--target',
              _target,
              '-d',
              '11111111-2222-3333-4444-555555555555',
              '--bundle-id',
              _iosBundleId,
              '--dart-define=PATROL_APP_BUNDLE_ID=$_iosBundleId',
              '--dart-define=MPLATROL_E2E_LOCAL_IOS_SIMULATOR=true',
              '--dart-define=E2E_TEST_BRIDGE=true',
              '--dart-define=PATROL_HOST=127.0.0.1',
            ],
            workingDirectory: appFoundationPath,
            throwOnError: false,
            forceVerbose: any(named: 'forceVerbose'),
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
        verify(
          () => shell.run(
            any(that: contains('-workspace $workspacePath')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            silent: true,
          ),
        ).called(1);
      });

      test(
          'reuse-last uninstalls physical iOS apps before '
          'test-without-building', () async {
        const deviceId = 'REAL-IOS-DEVICE';
        const testHostBundleId = 'com.example.demo.uitests.xctrunner';
        const credentialsUrl = 'http://192.168.86.249:64015/e2e-credentials?token=t';
        final xctestRun = File(
            p.join(appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Runner_iphoneos26.2-arm64.xctestrun'))
          ..createSync(recursive: true)
          ..writeAsStringSync('plist');
        final runtimeConfig = File(p.join(
          appFoundationPath,
          'build',
          'ios_integ',
          'Build',
          'Products',
          'Release-iphoneos',
          'Runner.app',
          'Frameworks',
          'App.framework',
          'flutter_assets',
          runtimeE2eAssetConfigFile,
        ))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"E2E_CREDENTIALS_URL":"stale"}');

        when(
          () => shell.runArgs(
            'plutil',
            any(),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(stdout: '$testHostBundleId\n'));
        when(
          () => shell.runArgs(
            'xcrun',
            any(that: contains('devicectl')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());
        when(
          () => shell.runArgs(
            'xcrun',
            any(that: contains('xcresulttool')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((invocation) async {
          final args = invocation.positionalArguments[1] as List<String>;
          return args.contains('summary') ? _passedIosSummary() : _result();
        });
        when(
          () => shell.runArgs(
            'xcodebuild',
            any(that: contains('test-without-building')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: deviceId,
          target: null,
          env: {
            'MPLATROL_E2E_ENVIRONMENT': 'Staging',
            e2eCredentialsUrlEnv: credentialsUrl,
          },
          reuseLast: true,
        );

        expect(code, ExitCode.success.code);
        expect(runtimeConfig.readAsStringSync(), contains(credentialsUrl));
        verifyInOrder([
          () => shell.runArgs(
                'xcrun',
                [
                  'devicectl',
                  'device',
                  'uninstall',
                  'app',
                  '--device',
                  deviceId,
                  _iosBundleId,
                ],
                throwOnError: false,
                silent: true,
                timeout: any(named: 'timeout'),
              ),
          () => shell.runArgs(
                'xcrun',
                [
                  'devicectl',
                  'device',
                  'uninstall',
                  'app',
                  '--device',
                  deviceId,
                  testHostBundleId,
                ],
                throwOnError: false,
                silent: true,
                timeout: any(named: 'timeout'),
              ),
          () => shell.runArgs(
                'xcodebuild',
                any(that: contains('test-without-building')),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              ),
        ]);
        expect(xctestRun.existsSync(), isTrue);
      });

      test('shuts down other booted simulators before running Patrol', () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Booted)
    iPhone 17 Pro (66666666-7777-8888-9999-AAAAAAAAAAAA) (Booted)
'''));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'shutdown', '66666666-7777-8888-9999-AAAAAAAAAAAA'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
        verifyNever(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'shutdown', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        );
      });

      test('stops an app a finished run left on Patrol ports on another simulator', () async {
        const stale = '/Users/u/Library/Developer/CoreSimulator/Devices/5AF38FF0-C789-4E53-9A95-029BAA42D136/data/'
            'Containers/Bundle/Application/X/Runner.app/Runner';
        const own = '/Users/u/Library/Developer/CoreSimulator/Devices/11111111-2222-3333-4444-555555555555/data/'
            'Containers/Bundle/Application/Y/Runner.app/Runner';
        when(() => shell.runArgs('lsof', ['-nP', '-iTCP:8081', '-iTCP:8082', '-sTCP:LISTEN', '-Fp'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'))).thenAnswer((_) async => _result(stdout: 'p25445\np300\np400\n'));
        for (final (pid, path) in [('25445', stale), ('300', own), ('400', '/usr/sbin/httpd')]) {
          when(() => shell.runArgs('lsof', ['-nP', '-a', '-p', pid, '-d', 'txt', '-Fn'],
              throwOnError: false,
              silent: true,
              timeout: any(named: 'timeout'))).thenAnswer((_) async => _result(stdout: 'p$pid\nftxt\nn$path\n'));
        }
        when(() => shell.runArgs('kill', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')))
            .thenAnswer((_) async => _result(exitCode: 1));

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(() =>
                shell.runArgs('kill', ['25445'], throwOnError: false, silent: true, timeout: any(named: 'timeout')))
            .called(1);
        verifyNever(
            () => shell.runArgs('kill', ['300'], throwOnError: false, silent: true, timeout: any(named: 'timeout')));
        verify(() => getDep<MplatrolLogger>().info('[ios-sim] stopped Runner (pid 25445) on simulator '
            '5AF38FF0-C789-4E53-9A95-029BAA42D136: it held Patrol port 8081/8082 (kill exit 1)')).called(1);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('process 400 listens on Patrol port'))))
            .called(1);
      });

      test("a run on an agent's own simulator leaves the spec simulator running", () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Booted)
    mplatrol-upgrade-ip17pro (66666666-7777-8888-9999-AAAAAAAAAAAA) (Booted)
'''));

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '66666666-7777-8888-9999-AAAAAAAAAAAA', target: _target);

        verifyNever(() => shell.runArgs('xcrun', ['simctl', 'shutdown', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')));
      });

      test("leaves another agent's own booted simulator running", () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Booted)
    mplatrol-aioskips-ip17pro (66666666-7777-8888-9999-AAAAAAAAAAAA) (Booted)
'''));

        expect(
            await runner.run(
                variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target),
            ExitCode.success.code);
        verifyNever(() => shell.runArgs('xcrun', ['simctl', 'shutdown', '66666666-7777-8888-9999-AAAAAAAAAAAA'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')));
      });

      test('a run on a shut-down spec simulator shuts down only the booted copies of it', () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Shutdown)
    iPhone 17 Pro (66666666-7777-8888-9999-AAAAAAAAAAAA) (Booted)
    iPhone 17 Pro (BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF) (Shutdown)
'''));
        Future<ProcessResultX> simctl(List<String> arguments) => shell.runArgs('xcrun', ['simctl', ...arguments],
            throwOnError: false, silent: true, timeout: any(named: 'timeout'));

        expect(
            await runner.run(
                variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target),
            ExitCode.success.code);

        verify(() => simctl(['shutdown', '66666666-7777-8888-9999-AAAAAAAAAAAA'])).called(1);
        verifyNever(() => simctl(['shutdown', 'BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF']));
        verify(() => simctl(['boot', '11111111-2222-3333-4444-555555555555'])).called(1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('simctl shutdown'))));
      });

      test('stops the biometric responder when the simulator log capture cannot start', () async {
        final responder = _MockBiometricResponder();
        when(responder.stop).thenAnswer((_) async {});
        when(() => getDep<LocalBiometrics>().respondOnIosSimulator(any())).thenAnswer((_) async => responder);
        // The log capture's directory cannot be created where a file is in the way.
        File(p.join(appFoundationPath, 'build', 'e2e-logs')).createSync(recursive: true);

        await expectLater(
            runner.run(variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target),
            throwsA(isA<FileSystemException>()));

        verify(responder.stop).called(1);
        verify(() => shell.runArgs('xcrun', ['simctl', 'listapps', '11111111-2222-3333-4444-555555555555', '--json'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout'))).called(2);
      });

      test('omits --bundle-id when xcodebuild fails', () async {
        when(
          () => shell.run(
            any(that: contains('xcodebuild -showBuildSettings')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            silent: true,
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.software.code));

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(
          () => shell.runArgs(
            'env',
            [
              'ONLY_ACTIVE_ARCH=YES',
              _fvmBinary(p.join(tempRoot.path, 'home', '.pub-cache')).path,
              'dart',
              '-D$patrolTestBundleDefine=$iosPatrolTestBundleFile',
              _patchedPatrolCliMain(appFoundationPath),
              'test',
              '--no-label',
              '--target',
              _target,
              '-d',
              '11111111-2222-3333-4444-555555555555',
              '--dart-define=E2E_TEST_BRIDGE=true',
              '--dart-define=PATROL_HOST=127.0.0.1',
            ],
            workingDirectory: appFoundationPath,
            throwOnError: false,
            forceVerbose: any(named: 'forceVerbose'),
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('omits --bundle-id when no PRODUCT_BUNDLE_IDENTIFIER is present', () async {
        when(
          () => shell.run(
            any(that: contains('xcodebuild -showBuildSettings')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            silent: true,
          ),
        ).thenAnswer((_) async => _result(stdout: 'BUILD SETTINGS\n  SDKROOT = x\n'));

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(
          () => shell.runArgs(
            'env',
            any(that: allOf(contains(_patchedPatrolCliMain(appFoundationPath)), isNot(contains('--bundle-id')))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            forceVerbose: any(named: 'forceVerbose'),
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('omits --bundle-id when PRODUCT_BUNDLE_IDENTIFIER is empty', () async {
        when(
          () => shell.run(
            any(that: contains('xcodebuild -showBuildSettings')),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: false,
            silent: true,
          ),
        ).thenAnswer((_) async => _result(stdout: '    PRODUCT_BUNDLE_IDENTIFIER = \n'));

        await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        verify(
          () => shell.runArgs(
            'env',
            any(that: allOf(contains(_patchedPatrolCliMain(appFoundationPath)), isNot(contains('--bundle-id')))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            forceVerbose: any(named: 'forceVerbose'),
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('restarts once after an explicit pre-test simulator disconnection', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.software.code,
            stderr: 'Simulator disconnected',
          );
        });
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _successfulIosPatrolResult(appFoundationPath);
        });
        when(
          () => shell.runArgs(
            'xcrun',
            any(that: contains('11111111-2222-3333-4444-555555555555')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        expect(patrolRuns, 2);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('retrying local iOS once')))).called(1);
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'shutdown', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout', that: isNotNull),
          ),
        ).called(1);
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'boot', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout', that: isNotNull),
          ),
        ).called(1);
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'bootstatus', '11111111-2222-3333-4444-555555555555', '-b'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout', that: isNotNull),
          ),
        ).called(2);
      });

      test('does not retry local iOS when Patrol reported failed tests', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: any(named: 'quietBuild'),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.software.code,
            stdout: 'Test summary:\n📝 Total: 9\n✅ Successful: 2\n❌ Failed: 7\n',
          );
        });

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        expect(patrolRuns, 1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('retrying local iOS once'))));
      });

      test('logs simctl failures while still retrying local iOS', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.software.code,
            stderr: 'Simulator disconnected',
          );
        });
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _successfulIosPatrolResult(appFoundationPath);
        });
        when(
          () => shell.runArgs(
            'xcrun',
            any(that: contains('11111111-2222-3333-4444-555555555555')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        expect(patrolRuns, 2);
        verify(() => getDep<MplatrolLogger>()
            .warn(any(that: contains('simctl shutdown 11111111-2222-3333-4444-555555555555')))).called(1);
        verify(() =>
                getDep<MplatrolLogger>().warn(any(that: contains('simctl boot 11111111-2222-3333-4444-555555555555'))))
            .called(1);
        verify(() => getDep<MplatrolLogger>()
            .warn(any(that: contains('simctl bootstatus 11111111-2222-3333-4444-555555555555')))).called(2);
      });

      test('returns the retry exit code when local iOS fails twice', () async {
        var patrolRuns = 0;
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: any(named: 'quietBuild', that: isFalse),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(
            exitCode: ExitCode.tempFail.code,
            stderr: 'Simulator disconnected',
          );
        });
        when(
          () => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async {
          patrolRuns++;
          return _result(exitCode: ExitCode.software.code);
        });
        when(
          () => shell.runArgs(
            'xcrun',
            any(that: contains('11111111-2222-3333-4444-555555555555')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result());

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.software.code);
        expect(patrolRuns, 2);
      });

      for (final output in [
        'Failed to no matches found for Descendants matching type Alert',
        'Test summary:\nTotal: 1\nFailed: 0\nSimulator disconnected',
        'MPLATROL_TEST_START\nSimulator disconnected',
        "Test Case '-[RunnerUITests testJourney]' started\nSimulator disconnected",
        'Authentication failed',
        'Failed to build app',
        '',
      ]) {
        test('does not rebuild after a non-infrastructure failure: $output', () async {
          var patrolRuns = 0;
          when(() => shell.runArgs(
                'env',
                any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: any(named: 'quietBuild'),
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              )).thenAnswer((_) async {
            patrolRuns++;
            return _result(exitCode: 65, stderr: output);
          });

          final code = await runner.run(
            variant: ItVariant.iosLocal,
            deviceId: '11111111-2222-3333-4444-555555555555',
            target: _target,
          );

          expect(code, 65);
          expect(patrolRuns, 1);
          verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('retrying local iOS once'))));
        });
      }

      test('does not retry a disconnection with a fresh native result bundle', () async {
        var patrolRuns = 0;
        when(() => shell.runArgs(
              'env',
              any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
              workingDirectory: appFoundationPath,
              throwOnError: false,
              quietBuild: any(named: 'quietBuild'),
              surfaceFailureOutput: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async {
          patrolRuns++;
          final stamp = DateTime.now().millisecondsSinceEpoch;
          Directory(p.join(appFoundationPath, 'build', 'ios_results_$stamp.xcresult')).createSync(recursive: true);
          return _result(exitCode: 65, stderr: 'Simulator disconnected');
        });

        final code = await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: '11111111-2222-3333-4444-555555555555',
          target: _target,
        );

        expect(code, 65);
        expect(patrolRuns, 1);
        verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('retrying local iOS once'))));
      });

      test('warns and continues when simctl list devices fails', () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        verify(() => getDep<MplatrolLogger>().warn(any(that: contains('simctl list devices exited')))).called(1);
        // A failed list yields no booted set, so the target is booted here.
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'boot', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
      });

      test('warns when shutting down another booted simulator fails', () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (11111111-2222-3333-4444-555555555555) (Booted)
    iPhone 17 Pro (66666666-7777-8888-9999-AAAAAAAAAAAA) (Booted)
'''));
        when(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'shutdown', '66666666-7777-8888-9999-AAAAAAAAAAAA'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        verify(() => getDep<MplatrolLogger>()
            .warn(any(that: contains('simctl shutdown 66666666-7777-8888-9999-AAAAAAAAAAAA exited')))).called(1);
      });

      test('boots the target simulator and warns when boot fails', () async {
        when(
          () => shell.runArgs('xcrun', ['simctl', 'list', 'devices'],
              throwOnError: false, silent: true, timeout: any(named: 'timeout')),
        ).thenAnswer((_) async => _result(stdout: '''
== Devices ==
-- iOS 26.2 --
'''));
        when(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'boot', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

        final code = await runner.run(
            variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

        expect(code, ExitCode.success.code);
        verify(
          () => shell.runArgs(
            'xcrun',
            ['simctl', 'boot', '11111111-2222-3333-4444-555555555555'],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ),
        ).called(1);
        verify(() => getDep<MplatrolLogger>()
            .warn(any(that: contains('simctl boot 11111111-2222-3333-4444-555555555555 exited')))).called(1);
      });
    });
  });

  group('LocalRunner.run coverage - recovery and reuse', () {
    String home() => p.join(tempRoot.path, 'home');

    File apkFile() => File(p.join(appFoundationPath, 'build/app/outputs/apk/debug/app-debug.apk'));

    void stubPatrol(Future<ProcessResultX> Function(int call) answer) {
      var calls = 0;
      when(
        () => shell.runArgs(
          'dart',
          any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          quietBuild: true,
          surfaceFailureOutput: true,
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => answer(++calls));
    }

    for (final (flags, message) in [
      ('pkgFlags=[ HAS_CODE ]', 'installed app is not debuggable'),
      ('pkgFlags=[ HAS_CODE DEBUGGABLE ]', 'matching APK signatures'),
      ('', 'could not verify installed package debug eligibility'),
    ]) {
      test('fresh Android downgrade stops safely: $message', () async {
        var builds = 0;
        stubPatrol((_) async => _result(exitCode: 1, stdout: 'INSTALL_FAILED_VERSION_DOWNGRADE'));
        when(() => shell.runArgs(
              'adb',
              ['-s', 'R3CN30ABCDE', 'shell', 'dumpsys', 'package', _androidId],
              throwOnError: false,
              silent: true,
              timeout: any(named: 'timeout'),
            )).thenAnswer((_) async => _result(stdout: flags));

        expect(
          await runner.run(
            variant: ItVariant.androidLocal,
            deviceId: 'R3CN30ABCDE',
            target: _target,
            onBuildStarted: () => builds++,
          ),
          1,
        );
        expect(builds, 1);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains(message)))).called(1);
        verifyNever(() => shell.runArgs(
              'adb',
              any(that: anyOf(contains('install'), contains('uninstall'), contains('clear'), contains('reboot'))),
              throwOnError: any(named: 'throwOnError'),
              silent: any(named: 'silent'),
              timeout: any(named: 'timeout'),
            ));
      });
    }

    test('stale downgrade report does not block current missing-app recovery', () async {
      apkFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('apk');
      stubPatrol((call) async {
        if (call != 1) {
          return _result();
        }
        final stale = File(p.join(appFoundationPath, 'build/app/outputs/androidTest-results/connected/debug/old.xml'));
        stale
          ..createSync(recursive: true)
          ..writeAsStringSync('INSTALL_FAILED_VERSION_DOWNGRADE')
          ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
        return _result(
            exitCode: 1,
            stderr: 'ActivityNotFoundException: Unable to find explicit '
                'activity class {com.example/.MainActivity}');
      });

      expect(
        await runner.run(
          variant: ItVariant.androidLocal,
          deviceId: 'R3CN30ABCDE',
          target: _target,
        ),
        ExitCode.success.code,
      );
      verify(() => shell.runArgs(
            'adb',
            ['-s', 'R3CN30ABCDE', 'install', '-r', '-d', apkFile().path],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          )).called(1);
      verifyNever(() => shell.runArgs(
            'adb',
            any(that: contains('dumpsys')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ));
    });

    test('current stdout downgrade with missing flags fails actionably', () async {
      stubPatrol((_) async => _result(exitCode: 7, stdout: 'INSTALL_FAILED_VERSION_DOWNGRADE'));
      when(() => shell.runArgs(
            'adb',
            ['-s', 'R3CN30ABCDE', 'shell', 'dumpsys', 'package', _androidId],
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => _result());

      expect(
        await runner.run(
          variant: ItVariant.androidLocal,
          deviceId: 'R3CN30ABCDE',
          target: _target,
        ),
        7,
      );
      verify(() =>
              getDep<MplatrolLogger>().err(any(that: contains('could not verify installed package debug eligibility'))))
          .called(1);
    });

    test('reuse-last on android requires cached APKs before instrumentation', () async {
      final code = await runner.run(
          variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target, reuseLast: true);

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('cached APK missing')))).called(1);
    });

    void writeCachedAndroidApks({bool includeTestApk = true}) {
      apkFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('app');
      if (includeTestApk) {
        File(p.join(appFoundationPath, 'build/app/outputs/apk/androidTest', 'debug/app-debug-androidTest.apk'))
          ..createSync(recursive: true)
          ..writeAsStringSync('test');
      }
    }

    void stubCachedAndroidCommands({
      ProcessResultX? installResult,
      ProcessResultX? clearResult,
      ProcessResultX? instrumentResult,
      ProcessResultX? logResetResult,
      ProcessResultX? logMarkerResult,
      ProcessResultX? logDumpResult,
    }) {
      when(() => shell.runArgs(
            'adb',
            any(that: allOf(contains('logcat'), contains('-c'))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => logResetResult ?? _result());
      when(() => shell.runArgs(
            'adb',
            any(that: contains('log')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => logMarkerResult ?? _result());
      when(() => shell.runArgs(
            'adb',
            any(that: allOf(contains('logcat'), contains('-d'))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => logDumpResult ?? _result(stdout: 'I mplatrol: MPLATROL_TEST_START\n'));
      when(() => shell.runArgs(
            'adb',
            any(that: contains('install')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => installResult ?? _result(stdout: 'Success\n'));
      when(() => shell.runArgs(
            'adb',
            any(that: contains('clear')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
          )).thenAnswer((_) async => clearResult ?? _result(stdout: 'Success\n'));
      when(() => shell.runArgs(
                'adb',
                any(that: contains('instrument')),
                workingDirectory: appFoundationPath,
                throwOnError: false,
                quietBuild: true,
                surfaceFailureOutput: true,
                timeout: any(named: 'timeout'),
              ))
          .thenAnswer((_) async =>
              instrumentResult ?? _result(stdout: 'INSTRUMENTATION_STATUS_CODE: 0\nINSTRUMENTATION_CODE: -1\n'));
    }

    Future<int> runCachedAndroid({
      String deviceId = 'emulator-5554',
      String? target = _target,
    }) =>
        runner.run(
          variant: ItVariant.androidLocal,
          deviceId: deviceId,
          target: target,
          reuseLast: true,
          env: const {'MPLATROL_E2E_RECORD_ANDROID': 'false'},
        );

    test('cached Android run executes its tests in the seeded order', () async {
      File(p.join(appFoundationPath, _target)).writeAsStringSync(
        "patrolTest('one', (\$) async {});\n"
        "patrolTest('two', (\$) async {});\n"
        "patrolTest('three', (\$) async {});\n",
      );
      writeCachedAndroidApks();
      stubCachedAndroidCommands();
      getDep<ItTestOrder>().order = const TestOrder.random(42);
      addTearDown(() => getDep<ItTestOrder>().order = const TestOrder.declared(0));
      final expected = const TestOrder.random(42)
          .apply(['one', 'three', 'two'])
          .map((method) => 'mplatrol.e2e.PatrolLoginTest#$method')
          .toList();

      expect(await runCachedAndroid(), ExitCode.success.code);
      final instrumented = verify(() => shell.runArgs(
            'adb',
            captureAny(that: contains('instrument')),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: true,
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).captured.cast<List<String>>();
      expect([for (final args in instrumented) args[args.indexOf('class') + 1]], expected);
      expect(expected, isNot(['one', 'three', 'two'].map((method) => 'mplatrol.e2e.PatrolLoginTest#$method')));
    });

    test('cached Android run installs APKs and executes a concrete test', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands();

      expect(await runCachedAndroid(), ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().info(any(that: contains('1/1 test(s) passed')))).called(1);
    });

    test('cached Android run fails when the test APK is missing', () async {
      writeCachedAndroidApks(includeTestApk: false);
      stubCachedAndroidCommands();

      expect(await runCachedAndroid(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('cached APK missing')))).called(1);
    });

    test('cached Android run fails when APK installation fails', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        installResult: _result(exitCode: 1, stderr: 'INSTALL_FAILED'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed to install')))).called(1);
    });

    test('cached Android run fails when app data cannot be cleared', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        clearResult: _result(exitCode: 1, stderr: 'clear failed'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('could not clear')))).called(1);
    });

    test('cached Android run fails on instrumentation failure', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        instrumentResult: _result(
            stdout: 'INSTRUMENTATION_STATUS_CODE: -2\n'
                'INSTRUMENTATION_RESULT: shortMsg=boom\n'
                'INSTRUMENTATION_CODE: -1\n'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed (adb exit')))).called(1);
    });

    test('cached Android run does not count a skipped test as passing', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        logDumpResult: _result(
            stdout: 'I mplatrol: MPLATROL_TEST_START\n'
                'I/flutter: MPLATROL_TEST_SKIPPED missing_credentials\n'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
    });

    test('cached Android run fails when logcat cannot be cleared', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        logResetResult: _result(exitCode: 1, stderr: 'logcat denied'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
    });

    test('cached Android run fails when logcat cannot be marked', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        logMarkerResult: _result(exitCode: 1, stderr: 'log denied'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
    });

    test('cached Android run fails when logcat cannot be read', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(
        logDumpResult: _result(exitCode: 1, stderr: 'logcat denied'),
      );

      expect(await runCachedAndroid(), ExitCode.software.code);
    });

    test('cached Android run fails when logcat lacks the test marker', () async {
      writeCachedAndroidApks();
      stubCachedAndroidCommands(logDumpResult: _result());

      expect(await runCachedAndroid(), ExitCode.software.code);
    });

    test('cached Android run rejects a missing application id', () async {
      when(() => fileSystem.fileExistsSync(gradlePath)).thenReturn(false);

      expect(await runCachedAndroid(), ExitCode.config.code);
    });

    test('cached Android run rejects an empty selected suite', () async {
      File(p.join(appFoundationPath, 'patrol_test/empty_test.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// no patrol tests\n');

      expect(
        await runCachedAndroid(target: 'patrol_test/empty_test.dart'),
        ExitCode.usage.code,
      );
    });

    test('cached Android run rejects an unready physical device', () async {
      when(() => shell.runArgs(
            'adb',
            any(that: contains('package')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async => _result(exitCode: 1));

      expect(
        await runCachedAndroid(deviceId: 'R3CN30ABCDE'),
        ExitCode.unavailable.code,
      );
    });

    test('filtered android run retargets the bundle and logs the target', () async {
      final code = await runner.run(
          variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target, targetRegex: 'sample');

      expect(code, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().info(any(that: contains('[bundle] local filtered run target')))).called(1);
      expect(
        File(p.join(appFoundationPath, 'patrol_test', 'mplatrol_filtered_test.dart')).existsSync(),
        isTrue,
      );
    });

    test('treats a passing run with skipped tests as a failure', () async {
      stubPatrol((_) async => _result(stdout: 'All tests: Skipped: 2 done'));

      final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('skipped test(s); treating')))).called(1);
    });

    group('CI results', () {
      const leg = ItRunLeg(tenant: 'demo', environment: 'Dev', variant: 'android');

      Future<(int, List<ItTestResult>)> runInLeg(String stdout, {int exitCode = 0}) async {
        stubPatrol((_) async => _result(exitCode: exitCode, stdout: stdout));
        final results = getDep<ItRunResults>();
        final code = await results.withLeg(
            leg, () => runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target),
            device: 'emulator-5554');
        return (code, results.resultsOf(leg));
      }

      test('records the verdict Patrol printed for each selected test', () async {
        final (code, results) = await runInLeg('✅ sample test (patrol_test/patrol_login_test.dart) (7s)');
        expect(code, ExitCode.success.code);
        expect(results.single.outcome, ItTestOutcome.pass);
        expect(results.single.file, 'patrol_login_test');
        expect(results.single.device, 'emulator-5554');
      });

      test('a single test that ran against mocks is MOCKED', () async {
        final (_, results) = await runInLeg('MPLATROL_MOCKED scope=api mock=origin\n✅ sample test (7s)');
        expect(results.single.outcome, ItTestOutcome.mocked);
      });

      test('a run where every test skipped exits non-zero and reports NOT RUN, never green', () async {
        final (code, results) = await runInLeg('⏩ patrol_login_test sample test\nAll tests: Skipped: 1 done');
        expect(code, isNot(ExitCode.success.code));
        expect(results.single.outcome, ItTestOutcome.notRun);
        expect(results.single.runtimeSkip, isTrue);
      });

      test('a skip keeps the reason the xcresult action log gives for it', () async {
        final log = jsonEncode({
          'title': 'Test',
          'subsections': [
            {
              'title': 'Run test case testASampleTest()',
              'messages': [
                {'title': 'Test skipped - DEVICE_NO_BIOMETRICS no enrolled biometrics'},
              ],
            },
          ],
        });
        final (_, results) = await runInLeg('⏩ patrol_login_test sample test\n$log\nAll tests: Skipped: 1 done');
        expect(results.single.reason, '$itRuntimeSkipReason (DEVICE_NO_BIOMETRICS no enrolled biometrics)');
        expect(results.single.runtimeSkip, isTrue);
      });

      test('a failed test carries the error Patrol printed under it', () async {
        final (code, results) =
            await runInLeg('❌ sample test (patrol_test/patrol_login_test.dart)\nBad state: no form', exitCode: 1);
        expect(code, isNot(ExitCode.success.code));
        expect((results.single.outcome, results.single.reason), (ItTestOutcome.fail, 'Bad state: no form'));
      });

      test('a missing Patrol test directory leaves the selection empty', () async {
        Directory(p.join(appFoundationPath, 'patrol_test')).deleteSync(recursive: true);
        final results = getDep<ItRunResults>();
        await results.withLeg(leg, () async {
          await expectLater(runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target),
              throwsStateError);
        });
        expect(results.resultsOf(leg), isEmpty);
      });
    });

    test('installs the built apk and retries when target app is missing', () async {
      apkFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('apk');
      stubPatrol((call) async => call == 1
          ? _result(
              exitCode: ExitCode.software.code,
              stderr: 'ActivityNotFoundException: Unable to find explicit '
                  'activity class {com.example/.MainActivity}')
          : _result());

      final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs(
          'adb',
          ['-s', 'emulator-5554', 'install', '-r', '-d', apkFile().path],
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
    });

    test('fails to recover a missing target app when the apk is absent', () async {
      stubPatrol((_) async => _result(
          exitCode: ExitCode.software.code,
          stderr: 'ActivityNotFoundException: Unable to find explicit '
              'activity class {com.example/.MainActivity}'));

      final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('does not exist. Rebuild')))).called(1);
    });

    test('reports when installing the recovery apk fails', () async {
      apkFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('apk');
      stubPatrol((_) async => _result(
          exitCode: ExitCode.software.code,
          stderr: 'ActivityNotFoundException: Unable to find explicit '
              'activity class {com.example/.MainActivity}'));
      when(
        () => shell.runArgs(
          'adb',
          ['-s', 'emulator-5554', 'install', '-r', '-d', apkFile().path],
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.software.code, stderr: 'no'));

      final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed to install')))).called(1);
    });

    test('reverses the credential port for a physical android device', () async {
      final code = await runner.run(
        variant: ItVariant.androidLocal,
        deviceId: 'R3CN30ABCDE',
        target: _target,
        env: {
          'MPLATROL_E2E_RECORD_ANDROID': 'false',
          e2eCredentialsUrlEnv: 'http://10.0.0.5:8080/creds',
        },
      );

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs(
          'adb',
          ['-s', 'R3CN30ABCDE', 'reverse', 'tcp:8080', 'tcp:8080'],
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
      verify(() => getDep<MplatrolLogger>().info(any(that: contains('adb reverse tcp:8080')))).called(1);
    });

    test('warns when the physical android credential port is unusable', () async {
      final code = await runner.run(
        variant: ItVariant.androidLocal,
        deviceId: 'R3CN30ABCDE',
        target: _target,
        env: {
          'MPLATROL_E2E_RECORD_ANDROID': 'false',
          e2eCredentialsUrlEnv: 'creds-without-port',
        },
      );

      expect(code, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('adb reverse failed')))).called(1);
    });

    test('reuse-last iOS reports when no cached xctestrun exists', () async {
      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: 'REAL-IOS-DEVICE',
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('no cached local iOS .xctestrun')))).called(1);
    });

    test('reuse-last iOS reports when no runtime config values are available', () async {
      File(p.join(appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Runner_iphoneos26.2-arm64.xctestrun'))
        ..createSync(recursive: true)
        ..writeAsStringSync('plist');

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: 'REAL-IOS-DEVICE',
        target: null,
        reuseLast: true,
        env: const {},
      );

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('no E2E runtime config values were available'))))
          .called(1);
    });

    test('reuse-last iOS reports when the cached artifact lacks the config file', () async {
      File(p.join(appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Runner_iphoneos26.2-arm64.xctestrun'))
        ..createSync(recursive: true)
        ..writeAsStringSync('plist');

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: 'REAL-IOS-DEVICE',
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('does not contain')))).called(1);
    });

    test('errors when cold start connects no device after wait-for-device', () async {
      when(
        () => shell.runArgs(
          'adb',
          ['-s', 'emulator-5554', 'shell', 'cmd', 'package', 'list', 'packages', 'android'],
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.software.code, stderr: "cmd: Can't find service: package"));
      when(
        () => shell.runArgs('adb', ['-s', 'emulator-5554', 'reboot'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
      when(
        () => shell.runArgs('adb', ['-s', 'emulator-5554', 'emu', 'avd', 'name'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'Pixel_9_Pro_XL\nOK\n'));
      when(
        () => shell.runArgs('adb', ['-s', 'emulator-5554', 'emu', 'kill'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result());
      when(
        () => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'List of devices attached\n'));
      when(
        () => shell.runArgs('adb', ['-s', 'emulator-5554', 'wait-for-device'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

      final code = await runner.run(variant: ItVariant.androidLocal, deviceId: 'emulator-5554', target: _target);

      expect(code, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('did not connect after cold')))).called(1);
    });

    test('returns config when the FVM executable is missing for iOS', () async {
      _fvmBinary(p.join(home(), '.pub-cache')).deleteSync();

      final code = await runner.run(
          variant: ItVariant.iosLocal, deviceId: '11111111-2222-3333-4444-555555555555', target: _target);

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('FVM executable not found')))).called(1);
    });
  });

  group('authoritative current iOS xcresult summary', () {
    late String? currentBundle;
    late ProcessResultX summary;
    late int processCode;
    late String processOutput;
    late bool produceBundle;

    Map<String, Object> testSummary({
      String status = 'Passed',
      int passed = 1,
      int failed = 0,
      int skipped = 0,
      int expected = 0,
    }) =>
        {
          'result': status,
          'totalTestCount': passed + failed + skipped + expected,
          'passedTests': passed,
          'failedTests': failed,
          'skippedTests': skipped,
          'expectedFailures': expected,
        };

    setUp(() {
      currentBundle = null;
      summary = _result(stdout: jsonEncode(testSummary()));
      processCode = 0;
      processOutput = 'MPLATROL_IOS_BUILD_SUCCEEDED';
      produceBundle = true;
      when(() => shell.runArgs(
            'env',
            any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
            workingDirectory: appFoundationPath,
            throwOnError: false,
            quietBuild: any(named: 'quietBuild'),
            surfaceFailureOutput: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((_) async {
        if (produceBundle) {
          currentBundle =
              p.join(appFoundationPath, 'build', 'ios_results_${DateTime.now().millisecondsSinceEpoch}.xcresult');
          Directory(currentBundle!).createSync(recursive: true);
        }
        return _result(exitCode: processCode, stdout: processOutput);
      });
      when(() => shell.runArgs(
            'xcrun',
            any(that: contains('summary')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          )).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        expect(args.last, currentBundle);
        return summary;
      });
    });

    Future<int> runIos() => runner.run(
          variant: ItVariant.iosLocal,
          deviceId: 'physical-device',
          target: _target,
        );

    test('accepts actual passed tests from the current result bundle', () async {
      expect(await runIos(), ExitCode.success.code);
    });

    test('expected failure is not green and does not assert SDK failure', () async {
      summary = _result(stdout: jsonEncode(testSummary(status: 'Expected Failure', passed: 0, expected: 1)));

      expect(await runIos(), ExitCode.software.code);
      expect(runner.iosBuildSucceeded, isTrue);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('expected failure, not a verified test pass'))))
          .called(1);
    });

    test('expected failures mixed with passes are still not green', () async {
      summary = _result(stdout: jsonEncode(testSummary(expected: 1)));
      expect(await runIos(), ExitCode.software.code);
    });

    test('zero passed tests cannot produce success', () async {
      summary = _result(stdout: jsonEncode(testSummary(passed: 0)));
      expect(await runIos(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('zero passed tests')))).called(1);
    });

    test('native skips have a distinct failure diagnostic', () async {
      summary = _result(stdout: jsonEncode(testSummary(skipped: 1)));
      expect(await runIos(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('skipped test(s); a skip is not a pass'))))
          .called(1);
    });

    test('Dart skips still fail even with a passed native summary', () async {
      processOutput = 'MPLATROL_IOS_BUILD_SUCCEEDED\nAll tests: Skipped: 2 done';
      expect(await runIos(), ExitCode.software.code);
    });

    test('actual summary failures are visible even when process exits zero', () async {
      summary = _result(
          stdout: jsonEncode({
        ...testSummary(status: 'Failed', passed: 0, failed: 1),
        'testFailures': [
          {'testName': 'Login journey', 'failureText': 'Login assertion failed'},
        ],
      }));
      expect(await runIos(), ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err('[xcresult] Login journey: Login assertion failed')).called(1);
    });

    test('preserves an existing real failure exit code', () async {
      processCode = 65;
      summary = _result(stdout: jsonEncode(testSummary(status: 'Expected Failure', passed: 0, expected: 1)));
      expect(await runIos(), 65);
    });

    for (final output in [
      'not-json',
      '[]',
      '{}',
      jsonEncode({...testSummary(), 'passedTests': '1'}),
      jsonEncode({...testSummary(), 'totalTestCount': 2}),
      jsonEncode({...testSummary(), 'failedTests': -1}),
    ]) {
      test('unverifiable summary fails closed: $output', () async {
        summary = _result(stdout: output);
        expect(await runIos(), ExitCode.software.code);
      });
    }

    test('xcresulttool failure cannot produce success', () async {
      summary = _result(exitCode: 1);
      expect(await runIos(), ExitCode.software.code);
    });

    test('old bundles cannot supply a pass even when recently modified', () async {
      produceBundle = false;
      Directory(p.join(
              appFoundationPath, 'build', 'ios_results_${DateTime.now().millisecondsSinceEpoch + 60000}.xcresult'))
          .createSync(recursive: true);
      expect(await runIos(), ExitCode.software.code);
      verifyNever(() => shell.runArgs(
            'xcrun',
            any(that: contains('summary')),
            throwOnError: false,
            silent: true,
            timeout: any(named: 'timeout'),
          ));
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('No current-run iOS result bundle')))).called(1);
    });

    test('missing result bundle preserves a real build failure', () async {
      produceBundle = false;
      processCode = 65;
      expect(await runIos(), 65);
    });
  });

  group('LocalRunner.run coverage - iOS simulator observer', () {
    const simId = '11111111-2222-3333-4444-555555555555';
    late String home;

    setUp(() {
      home = p.join(tempRoot.path, 'home');
      // Disable the real xcrun screen/log recorders so the simulator observer
      // does not spawn host processes during coverage runs.
      when(() => getDep<PlatformWrapper>().environment).thenReturn({
        'HOME': home,
        'MPLATROL_E2E_RECORD_IOS': 'false',
        'MPLATROL_E2E_LOG_IOS': 'false',
      });
    });

    void stubXctestrun(String platform) {
      File(p.join(
          appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Runner_$platform' '26.2-arm64.xctestrun'))
        ..createSync(recursive: true)
        ..writeAsStringSync('plist');
    }

    void stubRuntimeConfig(String buildDirName) {
      File(p.join(
        appFoundationPath,
        'build',
        'ios_integ',
        'Build',
        'Products',
        buildDirName,
        'Runner.app',
        'Frameworks',
        'App.framework',
        'flutter_assets',
        runtimeE2eAssetConfigFile,
      ))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"E2E_CREDENTIALS_URL":"stale"}');
    }

    void stubReuseShellCommands() {
      when(
        () => shell.runArgs('plutil', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'com.example.demo.xctrunner\n'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));
      when(
        () => shell.runArgs(
          'xcodebuild',
          any(that: contains('test-without-building')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result());
    }

    test('appends the latest iOS result bundle after a non-reuse run', () async {
      for (final name in ['ios_results_a.xcresult', 'ios_results_b.xcresult']) {
        Directory(p.join(appFoundationPath, 'build', name)).createSync(recursive: true);
      }
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));

      final code = await runner.run(variant: ItVariant.iosLocal, deviceId: simId, target: _target);

      expect(code, ExitCode.success.code);
    });

    test('reuse-last on a booted simulator uninstalls cached apps', () async {
      stubXctestrun('iphonesimulator');
      stubRuntimeConfig('Release-iphonesimulator');
      stubReuseShellCommands();

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: simId,
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs(
          'xcrun',
          ['simctl', 'uninstall', simId, _iosBundleId],
          throwOnError: false,
          silent: true,
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
    });

    test('reuse-last simulator warns when a cached uninstall fails', () async {
      stubXctestrun('iphonesimulator');
      stubRuntimeConfig('Release-iphonesimulator');
      stubReuseShellCommands();
      when(
        () => shell.runArgs('xcrun', ['simctl', 'uninstall', simId, _iosBundleId],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: simId,
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('could not uninstall cached reuse app'))))
          .called(1);
    });

    test('reuse-last appends xcresult action log and issue summary', () async {
      stubXctestrun('iphonesimulator');
      stubRuntimeConfig('Release-iphonesimulator');
      when(
        () => shell.runArgs('plutil', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'com.example.demo.xctrunner\n'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));
      when(
        () => shell.runArgs(
          'xcodebuild',
          any(that: contains('test-without-building')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result(stdout: 'run output'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('xcresulttool')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.contains('summary')) {
          return _passedIosSummary();
        }
        if (args.contains('object')) {
          return _result(
              stdout: jsonEncode({
            'issues': {
              '_values': [
                {
                  '_type': {'_name': 'IssueSummary'},
                  'issueType': {'_value': 'Warning'},
                  'message': {'_value': 'boom happened'},
                }
              ]
            }
          }));
        }
        if (args.contains('log')) {
          return _result(stdout: 'ACTION LOG LINE');
        }
        return _result();
      });

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: simId,
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.success.code);
    });

    test('reuse-last failure logs the xcresult issue summary', () async {
      stubXctestrun('iphonesimulator');
      stubRuntimeConfig('Release-iphonesimulator');
      when(
        () => shell.runArgs('plutil', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'com.example.demo.xctrunner\n'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));
      when(
        () => shell.runArgs(
          'xcodebuild',
          any(that: contains('test-without-building')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result(exitCode: 65, stdout: 'run output'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('xcresulttool')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.contains('summary')) {
          return _passedIosSummary();
        }
        if (args.contains('object')) {
          return _result(
              stdout: jsonEncode({
            'issues': {
              '_values': [
                {
                  '_type': {'_name': 'IssueSummary'},
                  'issueType': {'_value': 'Error'},
                  'message': {'_value': 'boom happened'},
                }
              ]
            }
          }));
        }
        if (args.contains('log')) {
          return _result(stdout: 'ACTION LOG LINE');
        }
        return _result();
      });

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: simId,
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, isNot(ExitCode.success.code));
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('[xcresult] Error: boom happened')))).called(1);
    });

    test('reuse-last tolerates malformed xcresult issue json', () async {
      stubXctestrun('iphonesimulator');
      stubRuntimeConfig('Release-iphonesimulator');
      when(
        () => shell.runArgs('plutil', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'com.example.demo.xctrunner\n'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));
      when(
        () => shell.runArgs(
          'xcodebuild',
          any(that: contains('test-without-building')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result());
      when(
        () => shell.runArgs('xcrun', any(that: contains('xcresulttool')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.contains('summary')) {
          return _passedIosSummary();
        }
        if (args.contains('object')) {
          return _result(stdout: 'garbage{');
        }
        if (args.contains('log')) {
          return _result(stdout: 'ACTION LOG LINE');
        }
        return _result();
      });

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: simId,
        target: null,
        reuseLast: true,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.2:9000/creds'},
      );

      expect(code, ExitCode.success.code);
    });

    test('removes stale XCUITest runner apps before running', () async {
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(
              stdout: jsonEncode({
            'com.foo.RunnerUITests.xctrunner': {'CFBundleName': 'Runner UITests'},
            'com.bar.app': 'not a map',
            'com.baz.app': {'CFBundleDisplayName': 'RunnerUITests Host'},
            'com.normal.app': {'CFBundleName': 'Normal'},
          })));
      when(
        () => shell.runArgs('xcrun', ['simctl', 'uninstall', simId, 'com.baz.app'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

      final code = await runner.run(variant: ItVariant.iosLocal, deviceId: simId, target: _target);

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs('xcrun', ['simctl', 'uninstall', simId, 'com.foo.RunnerUITests.xctrunner'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).called(greaterThanOrEqualTo(1));
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('failed to uninstall stale XCUITest runner'))))
          .called(greaterThanOrEqualTo(1));
    });

    test('warns when Simulator.app cannot be opened', () async {
      when(
        () => shell.runArgs('open', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
      when(
        () => shell.runArgs('xcrun', any(that: contains('listapps')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '{}'));

      final code = await runner.run(variant: ItVariant.iosLocal, deviceId: simId, target: _target);

      expect(code, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('failed to open Simulator.app')))).called(1);
    });
  });

  group('LocalRunner.run coverage - physical iOS signing', () {
    const deviceId = 'REAL-IOS-DEVICE';
    final signEnv = {e2eCredentialsUrlEnv: 'http://192.168.0.9:9000/creds'};

    test('without a signing command, a missing profile fails with the fix', () async {
      when(() => getDep<IosCodesign>().installedProfileForBundleId(any())).thenAnswer((_) async => null);

      final code = await runner.run(variant: ItVariant.iosLocal, deviceId: deviceId, target: _target, env: signEnv);

      expect(code, ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(
              that: allOf(
            contains('no provisioning profile is installed for'),
            contains(iosSigningCommandEnv),
          )))).called(1);
    });

    test('runs the signing command with the bundle id when a profile is missing', () async {
      when(() => getDep<IosCodesign>().installedProfileForBundleId(any())).thenAnswer((_) async => null);
      final commands = <(List<String>, Map<String, String>?)>[];
      GetIt.I.unregister<ProcessRunFunction>();
      GetIt.I.registerSingleton<ProcessRunFunction>((executable, arguments, {workingDirectory, environment}) async {
        commands.add((arguments, environment));
        return ProcessResult(0, 0, '', '');
      });

      await runner.run(
          variant: ItVariant.iosLocal,
          deviceId: deviceId,
          target: _target,
          env: {...signEnv, iosSigningCommandEnv: 'install-profile.sh'});

      final signing = commands.firstWhere((command) => command.$1.contains('install-profile.sh'));
      expect(signing.$1, ['-c', 'install-profile.sh']);
      expect(signing.$2?['MPLATROL_BUNDLE_ID'], isNotEmpty);
    });

    test('fails when no installed xctrunner development profile exists', () async {
      when(() => getDep<IosCodesign>().installedXctrunnerDevelopmentProfile()).thenAnswer((_) async => null);

      final code = await runner.run(variant: ItVariant.iosLocal, deviceId: deviceId, target: _target, env: signEnv);

      expect(code, ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('no installed iOS App Development')))).called(1);
    });

    test('warns when the host has no reachable non-loopback IPv4 address', () async {
      when(getDep<PlatformWrapper>().localNetworkHost).thenAnswer((_) async => null);
      when(() => getDep<IosCodesign>().installedProfileForBundleId(any())).thenAnswer((_) async => null);

      await runner.run(variant: ItVariant.iosLocal, deviceId: deviceId, target: _target, env: signEnv);

      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('no non-loopback IPv4 address found')))).called(1);
    });
  });

  group('LocalRunner.run coverage - reuse-last resign', () {
    const deviceId = 'REAL-IOS-DEVICE';
    final reuseEnv = {e2eCredentialsUrlEnv: 'http://192.168.0.9:9000/creds'};
    late Directory runnerApp;

    void writeXctestruns(int count) {
      for (var i = 0; i < count; i++) {
        File(p.join(
            appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Runner_iphoneos26.2-$i-arm64.xctestrun'))
          ..createSync(recursive: true)
          ..writeAsStringSync('plist');
      }
    }

    void writeRuntimeConfig() {
      final file = File(p.join(
        appFoundationPath,
        'build',
        'ios_integ',
        'Build',
        'Products',
        'Release-iphoneos',
        'Runner.app',
        'Frameworks',
        'App.framework',
        'flutter_assets',
        runtimeE2eAssetConfigFile,
      ))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"E2E_CREDENTIALS_URL":"stale"}');
      runnerApp = Directory(
          p.join(appFoundationPath, 'build', 'ios_integ', 'Build', 'Products', 'Release-iphoneos', 'Runner.app'));
      // Silence unused warning about file handle.
      expect(file.existsSync(), isTrue);
    }

    void stubReuseCommands() {
      when(
        () => shell.runArgs('plutil', any(), throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'com.example.demo.xctrunner\n'));
      when(
        () => shell.runArgs('xcrun', any(that: contains('devicectl')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result());
      when(
        () => shell.runArgs('xcrun', any(that: contains('xcresulttool')),
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        return args.contains('summary') ? _passedIosSummary() : _result();
      });
      when(
        () => shell.runArgs(
          'xcodebuild',
          any(that: contains('test-without-building')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          surfaceFailureOutput: any(named: 'surfaceFailureOutput'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async => _result());
    }

    test('re-signs with a distribution identity from an embedded profile', () async {
      writeXctestruns(2);
      writeRuntimeConfig();
      File(p.join(runnerApp.path, 'embedded.mobileprovision')).writeAsStringSync('profile-bytes');
      stubReuseCommands();
      when(
        () => shell.runArgs('security', any(that: contains('cms')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(
          stdout: '<plist><dict><key>ProvisionsAllDevices</key><true/>'
              '</dict></plist>'));
      when(
        () => shell.runArgs('security', any(that: contains('find-identity')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(stdout: '''
  1) 1111111111111111111111111111111111111111 "iPhone Developer: Someone (T1)"
  2) NOHEX "Apple Distribution: NoHex Co"
  3) 2222222222222222222222222222222222222222 "Apple Distribution: Example LLC (T2)"
'''));
      when(
        () => shell.runArgs('codesign', any(that: contains('--force')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result());

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: deviceId,
        target: null,
        reuseLast: true,
        env: reuseEnv,
      );

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs(
            'codesign', any(that: allOf(contains('--force'), contains('2222222222222222222222222222222222222222'))),
            throwOnError: false, silent: true),
      ).called(greaterThanOrEqualTo(1));
    });

    test('fails to re-sign when no distribution identity is installed', () async {
      writeXctestruns(1);
      writeRuntimeConfig();
      File(p.join(runnerApp.path, 'embedded.mobileprovision')).writeAsStringSync('profile-bytes');
      when(
        () => shell.runArgs('security', any(that: contains('cms')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(stdout: '<plist><dict><key>Name</key></dict></plist>'));
      when(
        () => shell.runArgs('security', any(that: contains('find-identity')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: deviceId,
        target: null,
        reuseLast: true,
        env: reuseEnv,
      );

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('could not find a signing identity')))).called(1);
    });

    test('re-signs with the current identity but fails on a codesign error', () async {
      writeXctestruns(1);
      writeRuntimeConfig();
      File(p.join(runnerApp.path, 'embedded.mobileprovision')).writeAsStringSync('profile-bytes');
      when(
        () => shell.runArgs('security', any(that: contains('cms')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));
      when(
        () => shell.runArgs('codesign', any(that: contains('-dv')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(stderr: '''
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Development: Jane Doe (TEAM123)
Authority=Apple Root CA
'''));
      when(
        () => shell.runArgs('codesign', any(that: contains('--force')), throwOnError: false, silent: true),
      ).thenAnswer((_) async => _result(exitCode: ExitCode.tempFail.code));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: deviceId,
        target: null,
        reuseLast: true,
        env: reuseEnv,
      );

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed to re-sign')))).called(1);
    });
  });

  group('LocalRunner.run coverage - android permission watcher', () {
    const deviceId = 'emulator-5554';

    void delayPatrol(Duration delay) {
      when(
        () => shell.runArgs(
          'dart',
          any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          quietBuild: true,
          surfaceFailureOutput: true,
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async {
        await Future<void>.delayed(delay);
        return _result();
      });
    }

    test('taps the focused permission dialog allow button by element while patrol runs', () async {
      delayPatrol(const Duration(milliseconds: 1800));
      when(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', androidFocusCommand],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '''
  mCurrentFocus=Window{a u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity}
  mFocusedApp=ActivityRecord{b u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity t9}
'''));
      when(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', 'dumpsys', 'window', 'windows'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '''
  Window #1 Window{a u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity}:
    Frames: parent=[0,0][1080,2424] display=[0,0][1080,2424] frame=[100,200][900,900] last=[100,200][900,900]
'''));
      when(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', 'dumpsys', 'activity', 'top'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '''
  ACTIVITY com.google.android.permissioncontroller/.ui.GrantPermissionsActivity 5d1 pid=4242
    View Hierarchy:
      com.android.internal.policy.DecorView{1 V.E...... R....... 0,0-800,700}[GrantPermissionsActivity]
        android.widget.Button{2 VFED..C.. ........ 0,300-800,400 #7f0a0250 app:id/permission_allow_button}
        android.widget.Button{3 VFED..C.. ........ 0,400-800,500 #7f0a0251 app:id/permission_deny_button}
'''));
      when(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', 'getprop', 'ro.build.version.release'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: '16\n'));

      final code = await runner.run(
        variant: ItVariant.androidLocal,
        deviceId: deviceId,
        target: _target,
        env: {'MPLATROL_E2E_RECORD_ANDROID': 'false'},
      );

      expect(code, ExitCode.success.code);
      verify(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', 'input', 'tap', '500', '550'],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).called(greaterThanOrEqualTo(1));
      verify(() => getDep<MplatrolLogger>()
              .info(any(that: allOf(contains('permission_allow_button at 500,550'), contains('on Android 16')))))
          .called(greaterThanOrEqualTo(1));
      verifyNever(() => shell.runArgs('adb', any(that: contains('uiautomator')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')));
    });

    test('reports a permission dialog it cannot answer in the failed run lessons', () async {
      when(
        () => shell.runArgs(
          'dart',
          any(that: contains(_patchedPatrolCliMain(appFoundationPath))),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          quietBuild: true,
          surfaceFailureOutput: true,
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 4500));
        return _result(exitCode: 1, stdout: 'Gradle test execution failed');
      });
      when(
        () => shell.runArgs('adb', ['-s', deviceId, 'shell', androidFocusCommand],
            throwOnError: false, silent: true, timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => _result(stdout: 'mCurrentFocus=Window{a b com.android.permissioncontroller/X}\n'));

      final code = await runner.run(
        variant: ItVariant.androidLocal,
        deviceId: deviceId,
        target: _target,
        env: {'MPLATROL_E2E_RECORD_ANDROID': 'false'},
      );

      expect(code, 1);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('PERMISSION_DIALOG_UNANSWERED')))).called(1);
      verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson permissionDialogUnanswered')))).called(1);
      verifyNever(() => shell.runArgs('adb', any(that: contains('tap')),
          throwOnError: false, silent: true, timeout: any(named: 'timeout')));
    });
  });

  group('LocalRunner.run coverage - misc signing and activation', () {
    test('physical iOS fails when the app bundle id cannot be resolved', () async {
      when(
        () => shell.run(
          any(that: contains('xcodebuild -showBuildSettings')),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          silent: true,
        ),
      ).thenAnswer((_) async => _result(stdout: 'BUILD SETTINGS\n'));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: 'REAL-IOS-DEVICE',
        target: _target,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.9:9000/creds'},
      );

      expect(code, ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('could not determine the iOS app bundle id'))))
          .called(1);
    });

    test('physical iOS warns when the runner profile lacks an xctrunner id', () async {
      when(() => getDep<IosCodesign>().installedXctrunnerDevelopmentProfile())
          .thenAnswer((_) async => IosProvisioningProfile(
                path: p.join(tempRoot.path, 'bad.mobileprovision'),
                name: 'Bad Runner',
                applicationIdentifier: '${IosCodesign.teamId}.com.demo.notrunner',
              ));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: 'REAL-IOS-DEVICE',
        target: _target,
        env: {e2eCredentialsUrlEnv: 'http://192.168.0.9:9000/creds'},
      );

      expect(code, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('does not have an .xctrunner application'))))
          .called(1);
    });

    test('logs the tail of a long patrol_cli activation failure', () async {
      when(
        () => shell.runArgs(
          'env',
          any(that: allOf(contains('global'), contains('activate'))),
          workingDirectory: appFoundationPath,
          throwOnError: false,
          silent: true,
        ),
      ).thenAnswer((_) async => _result(
          exitCode: ExitCode.software.code, stdout: List.generate(120, (i) => 'activation-line-$i').join('\n')));

      final code = await runner.run(
        variant: ItVariant.iosLocal,
        deviceId: '11111111-2222-3333-4444-555555555555',
        target: _target,
      );

      expect(code, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(
              any(that: allOf(contains('failed to activate repo-local patrol_cli'), contains('activation-line-119')))))
          .called(1);
    });
  });
}
