import 'package:mplatrol/src/local_device_spec.dart';
import 'package:test/test.dart';

const _conforming = '''
avd.ini.encoding=UTF-8
hw.device.name=pixel_9
hw.ramSize=6144
disk.dataPartition.size = 16G
vm.heapSize=228M
image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/
''';

void main() {
  group('AvdConfig', () {
    test('a config that meets the spec has no drift', () {
      expect(AvdConfig.parse(_conforming).drift(), isEmpty);
    });

    test('larger RAM, data partition and heap than the spec conform', () {
      final config = AvdConfig.parse(
        _conforming.replaceAll('6144', '8192').replaceAll('16G', '32768M').replaceAll('228M', '512'),
      );

      expect(config.drift(), isEmpty);
    });

    test('too little RAM, data partition or heap is repairable drift', () {
      final config = AvdConfig.parse(
        _conforming.replaceAll('6144', '2048').replaceAll('16G', '6G').replaceAll('228M', '64M'),
      );

      final drift = config.drift();

      expect(drift.map((item) => item.key), ['hw.ramSize', 'disk.dataPartition.size', 'vm.heapSize']);
      expect(drift.every((item) => item.repairable), isTrue);
      expect(drift.first.toString(), 'hw.ramSize is 2048, spec is 6144');
    });

    test('a missing or unreadable size is drift', () {
      final config = AvdConfig.parse(
        'hw.device.name=pixel_9\nhw.ramSize=lots\nimage.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a\n',
      );

      final drift = config.drift();

      expect(drift.map((item) => item.key), ['hw.ramSize', 'disk.dataPartition.size', 'vm.heapSize']);
      expect(drift.last.toString(), 'vm.heapSize is unset, spec is 228M');
    });

    test('another device profile or system image is drift that setup cannot repair', () {
      final config = AvdConfig.parse(
        _conforming.replaceAll('pixel_9', 'pixel_7').replaceAll('android-36', 'android-34'),
      );

      final drift = config.drift();

      expect(drift.map((item) => item.key), ['hw.device.name', 'image.sysdir.1']);
      expect(drift.any((item) => item.repairable), isFalse);
    });

    test('a missing device profile and system image are unrepairable drift', () {
      final config = AvdConfig.parse('hw.ramSize=6144\ndisk.dataPartition.size=16G\nvm.heapSize=228M\n');

      expect(config.drift().map((item) => item.key), ['hw.device.name', 'image.sysdir.1']);
    });

    test('repaired replaces drifted lines, appends missing keys and keeps everything else', () {
      final config = AvdConfig.parse('hw.device.name=pixel_9\nhw.ramSize=2048\n# note\n\n\nvm.heapSize=64M\n');

      final repaired = config.repaired();

      expect(
        repaired,
        'hw.device.name=pixel_9\nhw.ramSize=6144\n# note\n\n\nvm.heapSize=228M\n'
        'disk.dataPartition.size=16G\n',
      );
      expect(AvdConfig.parse(repaired).drift().where((item) => item.repairable), isEmpty);
    });

    test('repaired output of a conforming config only normalises the trailing newline', () {
      expect(AvdConfig.parse(_conforming.trimRight()).repaired(), _conforming);
    });
  });

  group('SimulatorEntry', () {
    const list = '''
== Devices ==
-- iOS 18.5 --
    iPhone 17 Pro (11111111-0000-0000-0000-000000000001) (Shutdown)
-- iOS 26.2 --
    iPhone 17 Pro (22222222-0000-0000-0000-000000000002) (Booted)
    iPhone 16 (33333333-0000-0000-0000-000000000003) (Shutdown)
    garbage without a udid
-- watchOS 11.0 --
    Apple Watch (44444444-0000-0000-0000-000000000004) (Shutdown)
''';

    test('parses iOS simulators with their runtime and state and skips other runtimes', () {
      final entries = SimulatorEntry.parse(list.split('\n'));

      expect(entries.map((entry) => entry.udid.substring(0, 2)), ['11', '22', '33']);
      expect(entries[1].booted, isTrue);
      expect(entries[2].booted, isFalse);
      expect(entries.map((entry) => entry.iosMajor), [18, 26, 26]);
    });

    test('only the spec name on the spec iOS major conforms', () {
      final entries = SimulatorEntry.parse(list.split('\n'));

      expect(entries.map((entry) => entry.conforms), [false, true, false]);
    });

    test('the newest installed iOS 26 runtime is chosen', () {
      final runtime = SimulatorEntry.newestRuntime(
        '''
== Runtimes ==
iOS 18.5 (18.5 - 22F77) - com.apple.CoreSimulator.SimRuntime.iOS-18-5
iOS 26.1 (26.1 - 23B86) - com.apple.CoreSimulator.SimRuntime.iOS-26-1
iOS 26.2 (26.2 - 23C54) - com.apple.CoreSimulator.SimRuntime.iOS-26-2
iOS 26.0 (26.0 - 23A1) - com.apple.CoreSimulator.SimRuntime.iOS-26-0
'''
            .split('\n'),
      );

      expect(runtime, 'com.apple.CoreSimulator.SimRuntime.iOS-26-2');
    });

    test('no iOS 26 runtime gives null', () {
      expect(SimulatorEntry.newestRuntime(['iOS 18.5 (18.5 - 22F77) - com.apple.CoreSimulator.SimRuntime.iOS-18-5']),
          isNull);
    });
  });

  test('a simulator list label is the spec simulator only by exact name', () {
    expect(LocalDeviceSpec.isSpecSimulatorLabel('iPhone 17 Pro'), isTrue);
    expect(LocalDeviceSpec.isSpecSimulatorLabel('iPhone 17 Pro (Booted)'), isTrue);
    expect(LocalDeviceSpec.isSpecSimulatorLabel('iPhone 17 Pro Max'), isFalse);
  });
}
