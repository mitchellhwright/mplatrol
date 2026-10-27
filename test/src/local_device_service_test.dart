import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/doctor/doctor_checks.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _configPath = '/home/dev/.android/avd/mplatrol_e2e_pixel9.avd/config.ini';
const _drifted =
    'hw.device.name=pixel_9\nhw.ramSize=2048\nimage.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/\n'
    'disk.dataPartition.size=16G\nvm.heapSize=228M\n';
const _simulators = '''
-- iOS 26.2 --
    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Shutdown)
''';

ProcessResultX _result(String out, {int exitCode = 0, String err = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: out, stderr: err);

void main() {
  late LocalDeviceService service;
  late MplatrolShell shell;
  late FileSystem files;
  late PlatformWrapper platform;

  void stubShell(String exe, List<String> args, ProcessResultX result, {Duration? timeout}) {
    if (timeout == null) {
      when(() => shell.runArgs(exe, args, throwOnError: false, silent: true)).thenAnswer((_) async => result);
    } else {
      when(() => shell.runArgs(exe, args, throwOnError: false, silent: true, timeout: timeout))
          .thenAnswer((_) async => result);
    }
  }

  void stubFile(String? content) {
    when(() => files.fileExistsSync(_configPath)).thenReturn(content != null);
    if (content != null) {
      when(() => files.readAsStringSync(_configPath)).thenReturn(content);
    }
  }

  const createArgs = [
    'create',
    'avd',
    '-n',
    'mplatrol_e2e_pixel9',
    '-k',
    'system-images;android-36;google_apis_playstore;arm64-v8a',
    '-d',
    'pixel_9',
  ];
  const listDevices = ['simctl', 'list', 'devices', 'available'];
  const listRuntimes = ['simctl', 'list', 'runtimes', 'available'];

  setUp(() async {
    await scaffoldMockDependencies();
    service = LocalDeviceService();
    shell = getDep<MplatrolShell>();
    files = getDep<FileSystem>();
    platform = getDep<PlatformWrapper>();
    when(() => platform.environment).thenReturn({'HOME': '/home/dev'});
    when(() => platform.isMac).thenReturn(true);
    when(() => files.writeAsStringSync(filePath: any(named: 'filePath'), newContent: any(named: 'newContent')))
        .thenReturn(null);
    stubShell('xcrun', listDevices, _result(_simulators));
  });

  group('androidConfigPath', () {
    test('defaults to ~/.android/avd', () {
      expect(service.androidConfigPath, _configPath);
    });

    test('follows ANDROID_USER_HOME', () {
      when(() => platform.environment).thenReturn({'ANDROID_USER_HOME': '/u'});

      expect(service.androidConfigPath, '/u/avd/mplatrol_e2e_pixel9.avd/config.ini');
    });

    test('ANDROID_AVD_HOME wins', () {
      when(() => platform.environment).thenReturn({'ANDROID_AVD_HOME': '/avd', 'ANDROID_USER_HOME': '/u'});

      expect(service.androidConfigPath, '/avd/mplatrol_e2e_pixel9.avd/config.ini');
    });
  });

  group('setup', () {
    test('repairs a drifted AVD after backing up config.ini, and leaves a conforming simulator alone', () async {
      stubFile(_drifted);
      stubShell('xcrun', listDevices,
          _result('-- iOS 26.2 --\n    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Booted)\n'));

      final changes = await service.setup();

      expect(changes, [
        'repaired AVD mplatrol_e2e_pixel9: hw.ramSize is 2048, spec is 6144 (backup: $_configPath.mplatrol-backup)',
        'simulator iPhone 17 Pro already conforms (22222222-0000-0000-0000-000000000002)',
      ]);
      verify(() => files.writeAsStringSync(filePath: '$_configPath.mplatrol-backup', newContent: _drifted)).called(1);
      verify(() => files.writeAsStringSync(
          filePath: _configPath, newContent: any(named: 'newContent', that: contains('hw.ramSize=6144')))).called(1);
    });

    test('a conforming AVD is left untouched', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      when(() => platform.isMac).thenReturn(false);

      final changes = await service.setup();

      expect(changes, ['AVD mplatrol_e2e_pixel9 already conforms']);
      verifyNever(
          () => files.writeAsStringSync(filePath: any(named: 'filePath'), newContent: any(named: 'newContent')));
    });

    test('creates a missing AVD with avdmanager, then raises its RAM', () async {
      var created = false;
      when(() => files.fileExistsSync(_configPath)).thenAnswer((_) => created);
      when(() => files.readAsStringSync(_configPath)).thenReturn(_drifted);
      when(() => shell.runArgs('avdmanager', createArgs, throwOnError: false, silent: true)).thenAnswer((_) async {
        created = true;
        return _result('');
      });
      when(() => platform.isMac).thenReturn(false);

      final changes = await service.setup();

      expect(changes.first, 'created AVD mplatrol_e2e_pixel9');
      expect(changes.last, startsWith('repaired AVD mplatrol_e2e_pixel9'));
    });

    test('a failing avdmanager says how to install the system image', () async {
      stubFile(null);
      stubShell('avdmanager', createArgs, _result('', exitCode: 1, err: 'Package path is not valid'));

      await expectLater(
        service.setup(),
        throwsA(isA<LocalDeviceSetupException>().having((error) => error.toString(), 'message',
            allOf(contains('Package path is not valid'), contains('sdkmanager --install')))),
      );
    });

    test('a missing avdmanager says how to install the system image', () async {
      stubFile(null);
      when(() => shell.runArgs('avdmanager', createArgs, throwOnError: false, silent: true))
          .thenThrow(const ProcessException('avdmanager', [], 'No such file', 2));

      await expectLater(
        service.setup(),
        throwsA(isA<LocalDeviceSetupException>()
            .having((error) => error.message, 'message', contains('Could not run avdmanager'))),
      );
    });

    test('an AVD with another device profile asks for it to be deleted instead of changing it', () async {
      stubFile(_drifted.replaceAll('pixel_9', 'pixel_7'));

      await expectLater(
        service.setup(),
        throwsA(isA<LocalDeviceSetupException>().having((error) => error.message, 'message',
            allOf(contains('hw.device.name is pixel_7'), contains('avdmanager delete avd -n mplatrol_e2e_pixel9')))),
      );
      verifyNever(
          () => files.writeAsStringSync(filePath: any(named: 'filePath'), newContent: any(named: 'newContent')));
    });

    test('creates the simulator on the newest iOS 26 runtime when none conforms', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      stubShell('xcrun', listDevices,
          _result('-- iOS 18.5 --\n    iPhone 17 Pro (11111111-0000-0000-0000-000000000001) (Shutdown)\n'));
      stubShell(
          'xcrun', listRuntimes, _result('iOS 26.1 (26.1 - 23B86) - rt-26-1\niOS 26.2 (26.2 - 23C54) - rt-26-2\n'));
      stubShell(
          'xcrun',
          ['simctl', 'create', 'iPhone 17 Pro', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'rt-26-2'],
          _result('NEW-UDID\n'));

      final changes = await service.setup();

      expect(changes.last, 'created simulator iPhone 17 Pro on rt-26-2 (NEW-UDID)');
    });

    test('no iOS 26 runtime says how to install it', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      stubShell('xcrun', listDevices, _result('', exitCode: 1));
      stubShell('xcrun', listRuntimes, _result('iOS 18.5 (18.5 - 22F77) - rt-18-5\n'));

      await expectLater(
        service.setup(),
        throwsA(isA<LocalDeviceSetupException>()
            .having((error) => error.message, 'message', contains('xcodebuild -downloadPlatform iOS'))),
      );
    });

    test('a failing simctl create reports its error', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      stubShell('xcrun', listDevices, _result(''));
      stubShell('xcrun', listRuntimes, _result('iOS 26.2 (26.2 - 23C54) - rt-26-2\n'));
      stubShell(
          'xcrun',
          ['simctl', 'create', 'iPhone 17 Pro', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'rt-26-2'],
          _result('', exitCode: 1, err: 'Invalid device type'));

      await expectLater(
        service.setup(),
        throwsA(isA<LocalDeviceSetupException>()
            .having((error) => error.message, 'message', contains('Invalid device type'))),
      );
    });
  });

  group('doctorFindings', () {
    const avdName = ['-s', 'emulator-5554', 'emu', 'avd', 'name'];

    test('a conforming AVD and simulator pass', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));

      final findings = await service.doctorFindings(['List of devices attached', '']);

      expect(findings.map((finding) => finding.ok), [true, true]);
    });

    test('a missing AVD fails with the setup command and a missing simulator fails too', () async {
      stubFile(null);
      stubShell('xcrun', listDevices, _result('', exitCode: 1));

      final findings = await service.doctorFindings(const []);

      expect(findings.map((finding) => finding.ok), [false, false]);
      expect(findings.first.fix, allOf(startsWith('AVD not found.'), contains('mplatrol devices --setup')));
    });

    test('a drifted AVD lists what differs', () async {
      stubFile(_drifted);
      when(() => platform.isMac).thenReturn(false);

      final findings = await service.doctorFindings(const []);

      expect(findings.single.ok, isFalse);
      expect(findings.single.fix, startsWith('hw.ramSize is 2048, spec is 6144.'));
    });

    test('a booted emulator that is not the spec AVD fails, an unreadable one is unknown, the spec AVD passes',
        () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      when(() => platform.isMac).thenReturn(false);
      stubShell('adb', avdName, _result('Pixel_7\nOK\n'), timeout: const Duration(seconds: 10));
      stubShell('adb', ['-s', 'emulator-5556', 'emu', 'avd', 'name'], _result('', exitCode: 1),
          timeout: const Duration(seconds: 10));
      stubShell('adb', ['-s', 'emulator-5558', 'emu', 'avd', 'name'], _result('mplatrol_e2e_pixel9\nOK\n'),
          timeout: const Duration(seconds: 10));

      final findings = await service.doctorFindings([
        'emulator-5554\tdevice',
        'emulator-5556\tdevice',
        'emulator-5558\tdevice',
        'emulator-5560\toffline',
        'R3CN30ABCDE\tdevice',
      ]);

      expect(findings.skip(1).map((finding) => finding.fix.split(' ').take(3).join(' ')),
          ['emulator-5554 is Pixel_7.', 'emulator-5556 is an']);
    });

    test('a booted simulator that is not the spec fails', () async {
      stubFile(_drifted.replaceAll('2048', '6144'));
      stubShell(
          'xcrun',
          listDevices,
          _result('-- iOS 26.2 --\n    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Shutdown)\n'
              '    iPhone 16 (33333333-0000-0000-0000-000000000003) (Booted)\n'));

      final findings = await service.doctorFindings(const []);

      expect(findings.map((finding) => finding.ok), [true, true, false]);
      expect(findings.last.fix, startsWith('iPhone 16 (iOS 26) is booted.'));
    });
  });

  group('androidAvdName', () {
    test('is the first line that is not OK', () async {
      stubShell('adb', ['-s', 'emulator-5554', 'emu', 'avd', 'name'], _result('\nOK\n'),
          timeout: const Duration(seconds: 10));

      expect(await service.androidAvdName('emulator-5554'), isNull);
    });
  });

  group('isSpecEmulator', () {
    const avdName = ['-s', 'emulator-5580', 'emu', 'avd', 'name'];

    test('an emulator is the spec one only when it runs the spec AVD', () async {
      stubShell('adb', avdName, _result('mplatrol_upgrade_pixel9\nOK\n'), timeout: const Duration(seconds: 10));
      expect(await service.isSpecEmulator('emulator-5580'), isFalse);

      stubShell('adb', avdName, _result('mplatrol_e2e_pixel9\nOK\n'), timeout: const Duration(seconds: 10));
      expect(await service.isSpecEmulator('emulator-5580'), isTrue);
    });

    test('an emulator that does not answer counts as the spec one', () async {
      stubShell('adb', avdName, _result('', exitCode: 1), timeout: const Duration(seconds: 10));

      expect(await service.isSpecEmulator('emulator-5580'), isTrue);
    });
  });

  group('bootAndroid', () {
    const emulatorArgs = ['-avd', 'mplatrol_e2e_pixel9'];
    const propArgs = ['-s', 'emulator-5554', 'shell', 'getprop', 'sys.boot_completed'];
    late DateTime start;
    late DateTime now;
    late List<String> infos;
    late List<Duration> sleeps;

    String Function() cycle(List<String> answers) => () => answers.length > 1 ? answers.removeAt(0) : answers.first;

    void stubAdbDevices(List<String> answers) {
      final next = cycle(answers);
      when(() => shell.runArgs('adb', ['devices'], throwOnError: false, silent: true))
          .thenAnswer((_) async => _result(next()));
    }

    void stubAvdName(String name) =>
        stubShell('adb', ['-s', 'emulator-5554', 'emu', 'avd', 'name'], _result('$name\nOK\n'),
            timeout: const Duration(seconds: 10));

    void stubBootProp(List<String> answers) {
      final next = cycle(answers);
      when(() => shell.runArgs('adb', propArgs, throwOnError: false, silent: true))
          .thenAnswer((_) async => _result(next()));
    }

    setUp(() {
      start = DateTime(2026, 10, 5);
      now = start;
      service = LocalDeviceService(clock: () => now);
      infos = [];
      when(() => getDep<MplatrolLogger>().info(any())).thenAnswer((invocation) {
        infos.add(invocation.positionalArguments.first as String);
      });
      sleeps = [];
      GetIt.I.unregister<SleepFunction>();
      GetIt.I.registerSingleton<SleepFunction>((delay) async {
        sleeps.add(delay);
        now = now.add(delay);
      });
      when(() => files.fileExistsSync(any())).thenReturn(false);
      stubFile(_drifted);
      when(() => shell.startDetached(any(), any())).thenAnswer((_) async {});
    });

    test('is null without the AVD', () async {
      stubFile(null);

      expect(await service.bootAndroid(), isNull);
      verifyNever(() => shell.startDetached(any(), any()));
    });

    test('returns the serial once adb lists the spec AVD and boot_completed is 1', () async {
      stubAdbDevices([
        'List of devices attached\n',
        'List of devices attached\nemulator-5554\toffline\n',
        'List of devices attached\nemulator-5554\tdevice\n',
      ]);
      stubAvdName('mplatrol_e2e_pixel9');
      stubBootProp(['0\n', '1\n']);

      expect(await service.bootAndroid(), 'emulator-5554');
      verify(() => shell.startDetached('emulator', emulatorArgs)).called(1);
      expect(infos.first, 'Starting emulator: emulator -avd mplatrol_e2e_pixel9');
      expect(sleeps, everyElement(const Duration(seconds: 3)));
      expect(sleeps, hasLength(3));
    });

    test('launches the emulator under ANDROID_HOME when it exists', () async {
      when(() => platform.environment)
          .thenReturn({'HOME': '/home/dev', 'ANDROID_HOME': '/sdk', 'ANDROID_SDK_ROOT': '/root'});
      when(() => files.fileExistsSync('/sdk/emulator/emulator')).thenReturn(true);
      stubAdbDevices(['emulator-5554\tdevice\n']);
      stubAvdName('mplatrol_e2e_pixel9');
      stubBootProp(['1\n']);

      await service.bootAndroid();

      verify(() => shell.startDetached('/sdk/emulator/emulator', emulatorArgs)).called(1);
    });

    test('skips an empty ANDROID_HOME and a missing SDK emulator, then uses PATH', () async {
      when(() => platform.environment)
          .thenReturn({'HOME': '/home/dev', 'ANDROID_HOME': '', 'ANDROID_SDK_ROOT': '/root'});
      when(() => files.fileExistsSync('/root/emulator/emulator')).thenReturn(false);
      when(() => files.fileExistsSync('/home/dev/Library/Android/sdk/emulator/emulator')).thenReturn(false);
      stubAdbDevices(['emulator-5554\tdevice\n']);
      stubAvdName('mplatrol_e2e_pixel9');
      stubBootProp(['1\n']);

      await service.bootAndroid();

      verify(() => shell.startDetached('emulator', emulatorArgs)).called(1);
    });

    test("without ANDROID_HOME (a launchd round) uses Android Studio's default SDK under HOME", () async {
      when(() => platform.environment).thenReturn({'HOME': '/home/dev'});
      when(() => files.fileExistsSync('/home/dev/Library/Android/sdk/emulator/emulator')).thenReturn(true);
      stubAdbDevices(['emulator-5554\tdevice\n']);
      stubAvdName('mplatrol_e2e_pixel9');
      stubBootProp(['1\n']);

      await service.bootAndroid();

      verify(() => shell.startDetached('/home/dev/Library/Android/sdk/emulator/emulator', emulatorArgs)).called(1);
    });

    test('ignores a booted emulator that is another AVD', () async {
      stubAdbDevices(['emulator-5554\tdevice\n']);
      stubAvdName('other_avd');

      await expectLater(service.bootAndroid(), throwsA(isA<LocalDeviceSetupException>()));
      verifyNever(() => shell.runArgs('adb', propArgs, throwOnError: false, silent: true));
    });

    test('throws naming the launch command when the emulator cannot be launched', () async {
      when(() => shell.startDetached(any(), any())).thenThrow(const ProcessException('emulator', [], 'denied', 1));

      await expectLater(
        service.bootAndroid(),
        throwsA(isA<LocalDeviceSetupException>()
            .having((e) => e.message, 'message', contains('emulator -avd mplatrol_e2e_pixel9'))),
      );
    });

    test('times out after 240 s when the emulator never appears in adb', () async {
      stubAdbDevices(['List of devices attached\n']);

      await expectLater(
        service.bootAndroid(),
        throwsA(isA<LocalDeviceSetupException>().having(
            (e) => e.message, 'message', allOf(contains('mplatrol_e2e_pixel9 never appeared'), contains('240s')))),
      );
      expect(now.difference(start), const Duration(seconds: 240));
    });

    test('times out when boot_completed stays 0, reporting progress every 15 s', () async {
      stubAdbDevices(['emulator-5554\tdevice\n']);
      stubAvdName('mplatrol_e2e_pixel9');
      stubBootProp(['0\n']);

      await expectLater(
        service.bootAndroid(),
        throwsA(isA<LocalDeviceSetupException>().having(
            (e) => e.message, 'message', allOf(contains('sys.boot_completed is still not 1'), contains('240s')))),
      );
      final waiting = infos.where((line) => line.startsWith('Waiting for mplatrol_e2e_pixel9')).toList();
      expect(waiting, hasLength(15));
      expect(waiting.first, contains('15s of 240s'));
    });
  });

  test('doctor findings are DoctorFinding values with the setup fix', () async {
    stubFile(null);
    when(() => platform.isMac).thenReturn(false);

    final findings = await service.doctorFindings(const []);

    expect(findings.single, isA<DoctorFinding>());
  });
}
