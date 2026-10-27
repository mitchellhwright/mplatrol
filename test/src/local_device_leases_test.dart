import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

void main() {
  late Directory root;
  late MatrixLocalDevices devices;
  late Map<String, String> environment;

  setUp(() async {
    await scaffoldMockDependencies();
    root = Directory.systemTemp.createTempSync('local_leases');
    devices = MatrixLocalDevices(
        directory: p.join(root.path, 'local-devices'),
        logger: getDep<MplatrolLogger>(),
        pollInterval: const Duration(milliseconds: 10));
    environment = {'HOME': root.path};
    when(() => getDep<PlatformWrapper>().environment).thenAnswer((_) => environment);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('holds the emulator for the run, so another run sees who holds it until it is released', () async {
    final run = LocalDeviceLeases(devices: devices);
    await run.hold('android', label: 'run android');
    await run.hold('android', label: 'run android');

    expect(devices.budgetForPlatform('android').liveLeases(), hasLength(1));
    expect(run.heldElsewhere('android'), isNull);
    expect(LocalDeviceLeases(devices: devices).heldElsewhere('android'), 'run android (pid $pid)');
    expect(LocalDeviceLeases(devices: devices).heldElsewhere('ios'), isNull);

    await run.releaseAll();
    expect(LocalDeviceLeases(devices: devices).heldElsewhere('android'), isNull);
  });

  test('hands the devices it holds to a child mplatrol, which then uses them without waiting', () async {
    final parent = LocalDeviceLeases(devices: devices);
    expect(parent.childEnvironment(), isEmpty);
    await parent.hold('android', label: 'upgrade-from');
    await parent.hold('ios', label: 'upgrade-from');

    environment = {...environment, ...parent.childEnvironment()};

    final child = LocalDeviceLeases(devices: devices);
    expect(child.inherited('android'), isTrue);
    expect(child.inherited('ios'), isTrue);
    expect(child.heldElsewhere('android'), isNull);
    await parent.releaseAll();
  });

  test("an agent's own emulator is not leased; a simulator always is", () async {
    when(() => getDep<LocalDeviceService>().isSpecEmulator('emulator-5580')).thenAnswer((_) async => false);
    final run = LocalDeviceLeases(devices: devices);

    await run.hold('android', label: 'own emulator', device: 'emulator-5580');

    expect(devices.budgetForPlatform('android').liveLeases(), isEmpty);
    expect(run.childEnvironment(), isEmpty);
    verify(() => getDep<MplatrolLogger>()
        .detail('[local-device] emulator-5580 is not the spec emulator, so it is not leased')).called(1);

    await run.hold('ios', label: 'own simulator', device: '46F0F812-E836-4300-80EE-00BECDF01B2F');
    expect(devices.budgetForPlatform('ios').liveLeases(), hasLength(1));
    verifyNever(() => getDep<LocalDeviceService>().isSpecEmulator('46F0F812-E836-4300-80EE-00BECDF01B2F'));
    await run.releaseAll();
  });

  test('a second run waits for the device until the first releases it', () async {
    final first = LocalDeviceLeases(devices: devices);
    await first.hold('ios', label: 'run ios');
    var second = false;
    final waiting = LocalDeviceLeases(devices: devices).hold('ios', label: 'second').then((_) => second = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second, isFalse);

    await first.releaseAll();
    await waiting;
    expect(second, isTrue);
  });

  test('uses the lease a parent matrix leg handed down and never leases a physical phone', () async {
    final matrix = await devices.budgetForPlatform('android').acquire(wanted: 1, label: 'acme:android');
    environment = {'HOME': root.path, localDeviceLeaseEnv: LocalDeviceLeases.envValue('android', matrix)};
    final leg = LocalDeviceLeases(devices: devices);

    await leg.hold('android', label: 'run android').timeout(const Duration(seconds: 2));
    await leg.hold('ios', label: 'run ios', device: 'REAL-IPHONE');

    expect(leg.inherited('android'), isTrue);
    expect(leg.inherited('ios'), isFalse);
    expect(leg.heldElsewhere('android'), isNull);
    expect(devices.budgetForPlatform('ios').liveLeases(), isEmpty);
    await matrix.release();
    expect(leg.inherited('android'), isFalse);
  });

  test('without HOME nothing is leased', () async {
    environment = {};
    final run = LocalDeviceLeases();
    await run.hold('android', label: 'run android');
    expect(run.heldElsewhere('android'), isNull);
    await run.releaseAll();
    verify(() => getDep<MplatrolLogger>().detail('[local-device] no HOME, so the local android device is not leased'))
        .called(1);
  });

  test('names a lease without a pid by its label and skips an unreadable one', () {
    final dir = Directory(p.join(root.path, 'local-devices', 'android'))..createSync(recursive: true);
    File(p.join(dir.path, '1-0-1.lease')).writeAsStringSync(jsonEncode({'slots': 1, 'label': 'old mplatrol'}));
    File(p.join(dir.path, '1-0-2.lease')).writeAsStringSync('not json');
    File(p.join(dir.path, '1-0-3.lease')).writeAsStringSync('[]');
    File(p.join(dir.path, '1-0-4.lease'))
      ..writeAsStringSync(jsonEncode({'slots': 1, 'label': 'dead run', 'pid': 7}))
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));

    expect(LocalDeviceLeases(devices: devices).heldElsewhere('android')!.split(', '),
        unorderedEquals(['old mplatrol', '1-0-3.lease']));
  });

  test('only the emulator, a simulator or the default device is leased', () {
    expect(LocalDeviceLeases.isLeasedDevice('android', null), isTrue);
    expect(LocalDeviceLeases.isLeasedDevice('android', 'emulator-5554'), isTrue);
    expect(LocalDeviceLeases.isLeasedDevice('android', '54120DLAQ002QN'), isFalse);
    expect(LocalDeviceLeases.isLeasedDevice('ios', '11111111-2222-3333-4444-555555555555'), isTrue);
    expect(LocalDeviceLeases.isLeasedDevice('ios', '00008140-001A2B3C4D5E801C'), isFalse);
  });
}
