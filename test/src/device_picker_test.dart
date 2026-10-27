import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

ProcessResultX _result(String stdout, {int exitCode = 0}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: '');

void _stubAdb(MplatrolShell shell, ProcessResultX result) {
  when(
    () => shell.run(
      'adb devices -l',
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
    ),
  ).thenAnswer((_) async => result);
}

void _stubFlutterDevices(MplatrolShell shell, ProcessResultX result) {
  when(
    () => shell.run(
      'dart pub global run fvm:main flutter devices --machine',
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
    ),
  ).thenAnswer((_) async => result);
}

void _stubSimctl(MplatrolShell shell, ProcessResultX result) {
  when(
    () => shell.run(
      'xcrun simctl list devices available',
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
    ),
  ).thenAnswer((_) async => result);
}

class MockLocalDeviceServiceForPicker extends Mock implements LocalDeviceService {}

Future<String?> _firstSimulatorId(DevicePicker picker) async =>
    (await picker.localIosSimulators()).map((device) => device.id).firstOrNull;

void main() {
  late DevicePicker picker;
  late MplatrolShell shell;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    picker = DevicePicker();
  });

  group('localAndroidDevices', () {
    late MockLocalDeviceServiceForPicker service;

    void avd(String serial, String? name) => when(() => service.androidAvdName(serial)).thenAnswer((_) async => name);

    setUp(() {
      service = MockLocalDeviceServiceForPicker();
      GetIt.I.unregister<LocalDeviceService>();
      GetIt.I.registerSingleton<LocalDeviceService>(service);
    });

    test('lists only booted emulators that run the spec AVD, with a model/device label', () async {
      _stubAdb(
        shell,
        _result(
          'List of devices attached\n'
          'emulator-5554\toffline\ttransport_id:1\n'
          'R3CN30ABCDE\tdevice product:b0q model:SM_S908U device:b0q transport_id:3\n'
          'emulator-5556\tdevice product:sdk_gphone64 device:emu64a transport_id:4\n'
          'emulator-5558\tdevice\n',
        ),
      );
      avd('emulator-5556', LocalDeviceSpec.androidAvdName);
      avd('emulator-5558', 'Pixel_7');

      final scan = await picker.scanAndroidEmulators();

      expect(scan.conforming.map((d) => d.id), ['emulator-5556']);
      expect(scan.conforming.single.label, 'emu64a (emulator-5556)');
      expect(scan.rejected, ['emulator-5558 runs AVD Pixel_7']);
      expect((await picker.localAndroidDevices()).map((d) => d.id), ['emulator-5556']);
    });

    test('rejects an emulator that does not answer the AVD name query', () async {
      _stubAdb(shell, _result('List of devices attached\nemulator-5554\tdevice\n'));
      avd('emulator-5554', null);

      final scan = await picker.scanAndroidEmulators();

      expect(scan.conforming, isEmpty);
      expect(scan.rejected, ['emulator-5554 runs an unknown AVD']);
    });

    test('returns an empty list when adb exits non-zero', () async {
      _stubAdb(shell, _result('', exitCode: 1));

      expect(await picker.localAndroidDevices(), isEmpty);
    });
  });

  group('localAndroidRealDevices', () {
    test('prefers Flutter physical Android labels and ignores emulators', () async {
      _stubFlutterDevices(
        shell,
        _result(
          '[{"name":"Galaxy S22","id":"R3CN30ABCDE", '
          '"isSupported":true,"targetPlatform":"android-arm64",'
          '"emulator":false,"sdk":"Android 16 (API 36)"}, '
          '{"name":"sdk gphone64","id":"emulator-5554", '
          '"isSupported":true,"targetPlatform":"android-arm64",'
          '"emulator":true,"sdk":"Android 16 (API 36)"}, '
          '{"name":"iPhone","id":"IOS-1",'
          '"isSupported":true,"targetPlatform":"ios","emulator":false}]',
        ),
      );
      _stubAdb(
        shell,
        _result(
          'List of devices attached\n'
          'R3CN30ABCDE\tdevice product:b0q model:SM_S908U device:b0q\n'
          'emulator-5554\tdevice product:sdk_gphone64 device:emu64a\n',
        ),
      );

      final devices = await picker.localAndroidRealDevices();

      expect(devices.map((device) => device.id), ['R3CN30ABCDE']);
      expect(
        devices.single.label,
        'Galaxy S22 - Android 16 (API 36) (R3CN30ABCDE)',
      );
    });

    test('falls back to ready adb physical devices when Flutter fails', () async {
      _stubFlutterDevices(shell, _result('', exitCode: 1));
      _stubAdb(
        shell,
        _result(
          'List of devices attached\n'
          'R3CN30ABCDE\tdevice product:b0q model:SM_S908U device:b0q\n'
          'emulator-5554\tdevice product:sdk_gphone64 device:emu64a\n',
        ),
      );

      final devices = await picker.localAndroidRealDevices();

      expect(devices.map((device) => device.id), ['R3CN30ABCDE']);
      expect(devices.single.label, 'SM S908U (R3CN30ABCDE)');
    });

    test('returns empty when only Android emulators are visible', () async {
      _stubFlutterDevices(
        shell,
        _result(
          '[{"name":"sdk gphone64","id":"emulator-5554", '
          '"isSupported":true,"targetPlatform":"android-arm64",'
          '"emulator":true}]',
        ),
      );
      _stubAdb(
        shell,
        _result(
          'List of devices attached\n'
          'emulator-5554\tdevice product:sdk_gphone64 device:emu64a\n',
        ),
      );

      expect(await picker.localAndroidRealDevices(), isEmpty);
    });
  });

  group('localIosSimulators best-first pick', () {
    test('same-name simulators: booted first, then newest runtime, then lowest UDID', () async {
      _stubSimctl(
        shell,
        _result(
          '== Devices ==\n'
          '-- iOS 26.0 --\n'
          '    iPhone 17 Pro (CCCCCCCC-0000-0000-0000-000000000003) (Shutdown)\n'
          '-- iOS 26.2 --\n'
          '    iPhone 17 Pro (BBBBBBBB-0000-0000-0000-000000000002) (Shutdown)\n'
          '    iPhone 17 Pro (AAAAAAAA-0000-0000-0000-000000000001) (Shutdown)\n'
          '-- iOS 26.0 --\n'
          '    iPhone 17 Pro (DDDDDDDD-0000-0000-0000-000000000004) (Booted)\n',
        ),
      );

      final ids = [for (final d in await picker.localIosSimulators()) d.id.substring(0, 1)];

      expect(ids, ['D', 'A', 'B', 'C']);
    });

    test('prefers a Booted iOS-26 iPhone over a newer shutdown one', () async {
      _stubSimctl(
        shell,
        _result(
          '== Devices ==\n'
          '-- iOS 26.0 --\n'
          '    iPhone 16 (11111111-0000-0000-0000-000000000001) (Booted)\n'
          '    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Shutdown)\n',
        ),
      );

      expect(await _firstSimulatorId(picker), '11111111-0000-0000-0000-000000000001');
    });

    test('picks the newest iOS-26 iPhone when none are booted and ignores other runtimes', () async {
      _stubSimctl(
        shell,
        _result(
          '== Devices ==\n'
          '-- iOS 17.5 --\n'
          '    iPhone 99 (99999999-0000-0000-0000-000000000099) (Shutdown)\n'
          '-- iOS 26.0 --\n'
          '    iPhone 16 (11111111-0000-0000-0000-000000000001) (Shutdown)\n'
          '    iPhone 17 (22222222-0000-0000-0000-000000000002) (Shutdown)\n'
          '-- watchOS 11.0 --\n'
          '    Apple Watch Series 10 (44444444-0000-0000-0000-000000000004) (Shutdown)\n',
        ),
      );

      expect(await _firstSimulatorId(picker), '22222222-0000-0000-0000-000000000002');
    });

    test('breaks ties between same-model same-state iPhones by first appearance', () async {
      _stubSimctl(
        shell,
        _result(
          '-- iOS 26.0 --\n'
          '    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Shutdown)\n'
          '    iPhone 17 Pro Max (33333333-0000-0000-0000-000000000003) (Shutdown)\n',
        ),
      );

      expect(await _firstSimulatorId(picker), '22222222-0000-0000-0000-000000000002');
    });

    test('returns null when no iOS-26 iPhone exists', () async {
      _stubSimctl(
        shell,
        _result(
          '== Devices ==\n'
          '-- iOS 17.5 --\n'
          '    iPhone 15 (11111111-0000-0000-0000-000000000001) (Shutdown)\n',
        ),
      );

      expect(await _firstSimulatorId(picker), isNull);
    });

    test('returns null when iOS-26 section has only non-iPhone or malformed lines', () async {
      _stubSimctl(
        shell,
        _result(
          '-- iOS 26.0 --\n'
          '    Apple TV 4K (55555555-0000-0000-0000-000000000005) (Shutdown)\n'
          '    total garbage line without a udid\n',
        ),
      );

      expect(await _firstSimulatorId(picker), isNull);
    });

    test('returns null when xcrun exits non-zero', () async {
      _stubSimctl(shell, _result('', exitCode: 1));

      expect(await _firstSimulatorId(picker), isNull);
    });
  });

  group('localIosSimulators', () {
    test('lists iOS-26 iPhones best-first with name + state labels', () async {
      _stubSimctl(
        shell,
        _result(
          '== Devices ==\n'
          '-- iOS 26.0 --\n'
          '    iPhone 16 (11111111-0000-0000-0000-000000000001) (Shutdown)\n'
          '    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Booted)\n',
        ),
      );

      final sims = await picker.localIosSimulators();

      // Booted first, then the shutdown one.
      expect(sims.map((s) => s.id), ['22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001']);
      expect(sims[0].label, 'iPhone 17 Pro (Booted)');
      expect(sims[1].label, 'iPhone 16');
    });

    test('returns an empty list when xcrun exits non-zero', () async {
      _stubSimctl(shell, _result('', exitCode: 1));

      expect(await picker.localIosSimulators(), isEmpty);
    });
  });

  group('scanIosSimulators', () {
    test('keeps the spec simulator and rejects other booted simulators', () async {
      _stubSimctl(
        shell,
        _result(
          '-- iOS 26.0 --\n'
          '    iPhone 16 (11111111-0000-0000-0000-000000000001) (Booted)\n'
          '    iPhone 17 (33333333-0000-0000-0000-000000000003) (Shutdown)\n'
          '    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Booted)\n',
        ),
      );

      final scan = await picker.scanIosSimulators();

      expect(scan.conforming.map((d) => d.id), ['22222222-0000-0000-0000-000000000002']);
      expect(scan.rejected, ['iPhone 16 (Booted) is booted']);
    });
  });

  group('localIosRealDevices', () {
    test('returns empty list when flutter devices exits non-zero', () async {
      _stubFlutterDevices(shell, _result('', exitCode: 1));

      expect(await picker.localIosRealDevices(), isEmpty);
    });

    test('returns empty list when flutter devices output is empty', () async {
      _stubFlutterDevices(shell, _result(''));

      expect(await picker.localIosRealDevices(), isEmpty);
    });

    test('returns empty list when output is not valid JSON', () async {
      _stubFlutterDevices(shell, _result('not json'));

      expect(await picker.localIosRealDevices(), isEmpty);
    });

    test('returns empty list when JSON is not a list', () async {
      _stubFlutterDevices(shell, _result('{"error": "nope"}'));

      expect(await picker.localIosRealDevices(), isEmpty);
    });

    test('returns iOS real devices, skipping non-iOS and emulators', () async {
      _stubFlutterDevices(
        shell,
        _result('''[
          {"id": "REAL-001", "targetPlatform": "ios", "emulator": false,
           "name": "My iPhone", "isDevice": true,
           "sdk": "iOS 18.0", "capabilities": {}},
          {"id": "EMU-001", "targetPlatform": "ios", "emulator": true,
           "name": "iPhone Sim", "isDevice": false,
           "sdk": "iOS 18.0", "capabilities": {}},
          {"id": "AND-001", "targetPlatform": "android-arm64", "emulator": false,
           "name": "Pixel", "isDevice": true,
           "sdk": "Android 14", "capabilities": {}},
          "not-a-map",
          {"targetPlatform": "ios", "emulator": false}
        ]'''),
      );

      final devices = await picker.localIosRealDevices();

      expect(devices.map((d) => d.id), ['REAL-001']);
    });
  });
}
