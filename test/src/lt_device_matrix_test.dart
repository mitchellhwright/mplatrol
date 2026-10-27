import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_device_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late _MockLogger logger;
  late List<LtDeviceJobSpec> calls;
  late Directory repo;

  setUp(() {
    logger = _MockLogger();
    calls = [];
    repo = Directory.systemTemp.createTempSync();
    addTearDown(() => repo.deleteSync(recursive: true));
  });

  LtDeviceJob jobReturning(Map<String, int> codes) => (spec) async {
        calls.add(spec);
        return codes[spec.device]!;
      };

  group('runOnEachLtDevice', () {
    test('a single device keeps the build name and the repo work directory', () async {
      final code = await runOnEachLtDevice(
        platform: 'Android',
        repo: repo.path,
        devices: const ['Galaxy S23-13'],
        buildName: 'build',
        logger: logger,
        runJob: jobReturning({'Galaxy S23-13': ExitCode.software.code}),
      );

      expect(code, ExitCode.software.code);
      expect(calls.single, (device: 'Galaxy S23-13', buildName: 'build', workDir: repo.path));
      verifyNever(() => logger.info(any()));
    });

    test('runs every device with its own build name and work directory', () async {
      final code = await runOnEachLtDevice(
        platform: 'iOS',
        repo: repo.path,
        devices: const [
          'iPhone 8-16',
          'iPhone SE (2020)-17',
          'iPhone 17 Pro-26',
        ],
        buildName: 'ios',
        logger: logger,
        runJob: jobReturning({
          'iPhone 8-16': ExitCode.success.code,
          'iPhone SE (2020)-17': ExitCode.unavailable.code,
          'iPhone 17 Pro-26': ExitCode.software.code,
        }),
      );

      expect(code, ExitCode.unavailable.code);
      expect(calls.map((spec) => spec.buildName), [
        'ios-iPhone_8_16',
        'ios-iPhone_SE_2020_17',
        'ios-iPhone_17_Pro_26',
      ]);
      for (final spec in calls) {
        expect(p.dirname(spec.workDir), p.join(repo.path, '.mplatrol', 'he-jobs'));
        expect(Directory(spec.workDir).existsSync(), isTrue);
      }
      expect(calls.map((spec) => spec.workDir).toSet(), hasLength(3));
      verify(() => logger.info('[device-matrix] iOS verdicts per device:')).called(1);
      verify(() => logger.info('  PASS  iPhone 8-16  (exit 0, LT build '
          '"ios-iPhone_8_16")')).called(1);
      verify(() => logger.info('  NOT VERIFIED  iPhone SE (2020)-17  (exit 69, '
          'LT build "ios-iPhone_SE_2020_17")')).called(1);
      verify(() => logger.info('  FAIL  iPhone 17 Pro-26  (exit 70, LT build '
          '"ios-iPhone_17_Pro_26")')).called(1);
    });

    test('runs all device jobs concurrently by default', () async {
      final release = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      final finishOrder = <String>[];
      final run = runOnEachLtDevice(
        platform: 'Android',
        repo: repo.path,
        devices: const ['Galaxy S23-13', 'Pixel 4a-12', 'Moto G54 5G-15'],
        buildName: 'android',
        logger: logger,
        runJob: (spec) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await release.future;
          inFlight--;
          finishOrder.add(spec.device);
          return spec.device == 'Galaxy S23-13' ? ExitCode.success.code : ExitCode.software.code;
        },
      );
      await pumpEventQueue();

      expect(maxInFlight, 3);
      release.complete();
      expect(await run, ExitCode.software.code);
      expect(finishOrder, hasLength(3));
      verify(() => logger.info('[device-matrix] Android: 3 devices, '
          '3 HyperExecute job(s) at a time, starts 0s apart')).called(1);
    });

    test('startSpacing staggers the start of concurrent device jobs', () async {
      final clock = Stopwatch()..start();
      final starts = <Duration>[];
      final code = await runOnEachLtDevice(
        platform: 'Android',
        repo: repo.path,
        devices: const ['Galaxy S23-13', 'Pixel 4a-12', 'Moto G54 5G-15'],
        buildName: 'android',
        logger: logger,
        startSpacing: const Duration(milliseconds: 60),
        runJob: (spec) async {
          starts.add(clock.elapsed);
          return ExitCode.success.code;
        },
      );

      expect(code, ExitCode.success.code);
      expect(starts[1], greaterThanOrEqualTo(const Duration(milliseconds: 60)));
      expect(starts[2], greaterThanOrEqualTo(const Duration(milliseconds: 120)));
    });

    test('maxConcurrent 1 runs the device jobs one after another', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final code = await runOnEachLtDevice(
        platform: 'iOS',
        repo: repo.path,
        devices: const ['iPhone 8-16', 'iPhone 17 Pro-26'],
        buildName: 'ios',
        logger: logger,
        maxConcurrent: 1,
        runJob: (spec) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await pumpEventQueue();
          inFlight--;
          return ExitCode.success.code;
        },
      );

      expect(code, ExitCode.success.code);
      expect(maxInFlight, 1);
    });
  });

  test('ltDevicePool splits a pool on | and trims, keeping a plain spec as one device', () {
    expect(ltDevicePool('Galaxy S23-13'), ['Galaxy S23-13']);
    expect(ltDevicePool(' Pixel 9-16 | Galaxy S24-14 ||'), ['Pixel 9-16', 'Galaxy S24-14']);
  });

  test('ltDeviceBuildName names a pool by its first device and size', () {
    expect(ltDeviceBuildName('b', 'Pixel 9-16|Galaxy S24-14|Pixel 8-14'), 'b-Pixel_9_16_pool3');
  });

  test('ltDeviceBuildName keeps letters, digits and dots only', () {
    expect(ltDeviceBuildName('b', 'Galaxy Z Fold7-16'), 'b-Galaxy_Z_Fold7_16');
    expect(ltDeviceBuildName('b', ' iPad 10.9 (2022)-26 '), 'b-iPad_10.9_2022_26');
  });

  test('ltDeviceVerdict names pass, unverified and failed exit codes', () {
    expect(ltDeviceVerdict(ExitCode.success.code), 'PASS');
    expect(ltDeviceVerdict(ExitCode.unavailable.code), 'NOT VERIFIED');
    expect(ltDeviceVerdict(ExitCode.usage.code), 'FAIL');
  });
}
