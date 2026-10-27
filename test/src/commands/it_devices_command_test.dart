// ignore_for_file: no_adjacent_strings_in_list, missing_whitespace_between_adjacent_strings

import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

final _expectedUsage = [
  'List local devices/simulators and the configured LambdaTest devices to target.\n'
      '\n'
      'Usage: mplatrol devices [arguments]\n'
      '-h, --help     Print this usage information.\n'
      '    --setup    Create the spec emulator and simulator if missing and repair drift '
      '(${LocalDeviceSpec.summary}). Prints what it changed; safe to rerun.\n'
      '\n'
      'Run "mplatrol help" to see global options.',
];

ProcessResultX _resultWithStdout(String stdout) => ProcessResultX.from(ProcessResult(0, 0, stdout, ''));

void _stubShellRun(MplatrolShell shell, String script, String stdout) {
  when(
    () => shell.run(
      script,
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
      forceVerbose: any(named: 'forceVerbose'),
      workingDirectory: any(named: 'workingDirectory'),
    ),
  ).thenAnswer((_) async => _resultWithStdout(stdout));
}

void main() {
  setUp(() async {
    await scaffoldMockDependencies();
  });

  group('devices', () {
    test(
      'help',
      overridePrint((printLogs) async {
        final commandRunner = MplatrolCommandRunner();
        final result = await commandRunner.run('devices --help'.split(' '));
        expect(printLogs, equals(_expectedUsage));
        expect(result, equals(ExitCode.success.code));

        printLogs.clear();

        final resultAbbr = await commandRunner.run('devices -h'.split(' '));
        expect(printLogs, equals(_expectedUsage));
        expect(resultAbbr, equals(ExitCode.success.code));
      }),
    );

    group('--setup', () {
      test('prints each change and how to boot the AVD', () async {
        when(() => getDep<LocalDeviceService>().setup()).thenAnswer((_) async => ['created AVD mplatrol_e2e_pixel9']);

        final result = await MplatrolCommandRunner().run('devices --setup'.split(' '));

        expect(result, ExitCode.success.code);
        final logger = getDep<MplatrolLogger>();
        verify(() => logger.info('  created AVD mplatrol_e2e_pixel9')).called(1);
        verify(() => logger.info(any(that: contains('emulator -avd mplatrol_e2e_pixel9')))).called(1);
        verifyNever(() => logger.info('Local Android physical devices (flutter/adb):'));
      });

      test('refuses to change the local devices while another run holds one', () async {
        when(() => getDep<LocalDeviceLeases>().heldElsewhere('ios')).thenReturn('initech:ios (pid 7)');

        final result = await MplatrolCommandRunner().run('devices --setup'.split(' '));

        expect(result, ExitCode.tempFail.code);
        verify(() => getDep<MplatrolLogger>().err(
                '[local-device] not changing the local devices while a run uses them: '
                'the local ios device is leased by initech:ios (pid 7). Rerun `mplatrol devices --setup` when it finishes.'))
            .called(1);
        verifyNever(() => getDep<LocalDeviceService>().setup());
      });

      test('fails with the setup error message', () async {
        when(() => getDep<LocalDeviceService>().setup())
            .thenThrow(const LocalDeviceSetupException('install the system image'));

        final result = await MplatrolCommandRunner().run('devices --setup'.split(' '));

        expect(result, ExitCode.unavailable.code);
        verify(() => getDep<MplatrolLogger>().err('install the system image')).called(1);
      });
    });

    group('local Android', () {
      test('says which local device another run holds', () async {
        when(() => getDep<LocalDeviceLeases>().heldElsewhere('android')).thenReturn('globex:android (pid 9)');
        _stubShellRun(getDep<MplatrolShell>(), 'adb devices -l', 'List of devices attached\n');

        await MplatrolCommandRunner().run('devices'.split(' '));

        verify(() => getDep<MplatrolLogger>()
            .info('[local-device] the local android device is leased by globex:android (pid 9)')).called(1);
      });

      test('lists physical devices from the Android picker', () async {
        final shell = getDep<MplatrolShell>();
        final logger = getDep<MplatrolLogger>();
        final devicePicker = getDep<DevicePicker>();
        when(devicePicker.localAndroidRealDevices).thenAnswer(
          (_) async => [
            LocalDevice(id: 'R3CN30ABCDE', label: 'Galaxy (R3CN30ABCDE)'),
          ],
        );
        _stubShellRun(shell, 'adb devices -l', 'List of devices attached\n');

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(
          () => logger.info('Local Android physical devices (flutter/adb):'),
        ).called(1);
        verify(() => logger.info('  Galaxy (R3CN30ABCDE)')).called(1);
      });

      test('lists attached devices when adb output is non-empty', () async {
        final shell = getDep<MplatrolShell>();
        final logger = getDep<MplatrolLogger>();
        _stubShellRun(
          shell,
          'adb devices -l',
          'List of devices attached\n'
              'emulator-5554 device product:sdk_gphone64\n',
        );

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(() => logger.info('Local Android (adb devices):')).called(1);
        verify(() => logger.info(any(that: contains('emulator-5554 device product:sdk_gphone64')))).called(1);
        verifyNever(() => logger.info(any(that: contains('boot an emulator or attach a device'))));
      });

      test('logs the empty message when adb lists no devices', () async {
        final shell = getDep<MplatrolShell>();
        final logger = getDep<MplatrolLogger>();
        _stubShellRun(shell, 'adb devices -l', 'List of devices attached\n');

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(() => logger.info(any(that: contains('boot an emulator or attach a device')))).called(1);
      });
    });

    group('local iOS (mac)', () {
      test('lists booted and shutdown iPhone simulators on mac', () async {
        final shell = getDep<MplatrolShell>();
        final logger = getDep<MplatrolLogger>();
        final devicePicker = getDep<DevicePicker>();
        final platformWrapper = getDep<PlatformWrapper>();
        when(() => platformWrapper.isMac).thenReturn(true);
        when(devicePicker.localIosSimulators).thenAnswer(
          (_) async => [
            LocalDevice(id: 'ABC-123', label: 'iPhone 17 Pro (ABC-123) (Booted)'),
            LocalDevice(id: 'DEF-456', label: 'iPhone 16 (DEF-456) (Shutdown)'),
          ],
        );
        _stubShellRun(
          shell,
          'xcrun simctl list devices available',
          '-- iOS 26.0 --\n'
              '    iPhone 17 Pro (ABC-123) (Booted)\n'
              '    iPhone 16 (DEF-456) (Shutdown)\n'
              '    iPad Pro (GHI-789) (Shutdown)\n',
        );

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(() => logger.info('Local iOS simulators (xcrun simctl, available):')).called(1);
        verify(() => logger.info(any(that: contains('iPhone 17 Pro (ABC-123) (Booted)')))).called(1);
        verify(() => logger.info(any(that: contains('iPhone 16 (DEF-456) (Shutdown)')))).called(1);
        verifyNever(() => logger.info(any(that: contains('iPad Pro (GHI-789) (Shutdown)'))));
      });

      test('logs the empty message when no iPhone simulators match', () async {
        final shell = getDep<MplatrolShell>();
        final logger = getDep<MplatrolLogger>();
        final devicePicker = getDep<DevicePicker>();
        final platformWrapper = getDep<PlatformWrapper>();
        when(() => platformWrapper.isMac).thenReturn(true);
        when(devicePicker.localIosSimulators).thenAnswer((_) async => const []);
        _stubShellRun(
          shell,
          'xcrun simctl list devices available',
          '-- iOS 26.0 --\n'
              '    iPad Pro (GHI-789) (Shutdown)\n',
        );

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(() => logger.info(any(that: contains('(none available)')))).called(1);
      });
    });

    test('skips the iOS block when not on mac', () async {
      final shell = getDep<MplatrolShell>();
      final logger = getDep<MplatrolLogger>();
      final platformWrapper = getDep<PlatformWrapper>();
      when(() => platformWrapper.isMac).thenReturn(false);
      _stubShellRun(shell, 'xcrun simctl list devices available', '    iPhone 17 Pro (ABC-123) (Booted)\n');

      final commandRunner = MplatrolCommandRunner();
      await commandRunner.run('devices'.split(' '));

      verifyNever(
        () => shell.run(
          'xcrun simctl list devices available',
          throwOnError: any(named: 'throwOnError'),
          silent: any(named: 'silent'),
          forceVerbose: any(named: 'forceVerbose'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      verifyNever(() => logger.info('Local iOS simulators (xcrun simctl, available):'));
    });

    group('LambdaTest', () {
      test('prints the LT_USERNAME hint when it is not set', () async {
        final logger = getDep<MplatrolLogger>();
        final platformWrapper = getDep<PlatformWrapper>();
        when(() => platformWrapper.environment).thenReturn({});

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(
          () => logger.info(any(that: contains('set LT_USERNAME + LT_ACCESS_KEY to use the lt-* variants'))),
        ).called(1);
      });

      test('omits the hint when LT_USERNAME is set', () async {
        final logger = getDep<MplatrolLogger>();
        final platformWrapper = getDep<PlatformWrapper>();
        when(() => platformWrapper.environment).thenReturn({'LT_USERNAME': 'ci-user'});

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verifyNever(() => logger.info(any(that: contains('set LT_USERNAME + LT_ACCESS_KEY to use the lt-* variants'))));
      });

      test('prints the configured LT android and iOS device defaults', () async {
        final logger = getDep<MplatrolLogger>();

        final commandRunner = MplatrolCommandRunner();
        await commandRunner.run('devices'.split(' '));

        verify(() => logger.info(any(that: allOf(contains('lt-android'), contains('Galaxy S23-13'))))).called(1);
        verify(() => logger.info(any(that: allOf(contains('lt-ios'), contains('iPhone 16 Pro-18'))))).called(1);
      });
    });
  });
}
