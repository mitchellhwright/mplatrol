import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/it_target_selector.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

final _emulator = LocalDevice(id: 'emulator-5554', label: 'Pixel (emulator-5554)');
final _simulator = LocalDevice(id: 'SIM-UDID-26', label: 'iPhone 17 Pro');

void main() {
  late DevicePicker picker;

  setUp(() async {
    await scaffoldMockDependencies();
    picker = getDep<DevicePicker>();
  });

  void devices({List<LocalDevice> emulators = const [], List<LocalDevice> iosSimulators = const []}) {
    when(picker.localAndroidDevices).thenAnswer((_) async => emulators);
    when(picker.localIosSimulators).thenAnswer((_) async => iosSimulators);
  }

  Future<AutoTargetChoice> choose(AutoPlatform platform, {int files = 1, bool lambdaTest = true}) async =>
      (await ItTargetSelector().choose(
        platforms: [platform],
        selectedTestFiles: files,
        lambdaTestAvailable: lambdaTest,
      ))
          .single;

  group('android', () {
    test('runs a small selection on the spec emulator', () async {
      devices(emulators: [_emulator]);

      final choice = await choose(AutoPlatform.android, files: ItTargetSelector.localAndroidMaxTestFiles);

      expect(choice.variant, ItVariant.androidLocal);
      expect(choice.reason, contains('4 test files on Pixel (emulator-5554)'));
      verifyNever(picker.localAndroidRealDevices);
    });

    test('sends a selection above the local limit to LambdaTest', () async {
      devices(emulators: [_emulator]);

      final choice = await choose(AutoPlatform.android, files: ItTargetSelector.localAndroidMaxTestFiles + 1);

      expect(choice.variant, ItVariant.ltAndroid);
      expect(choice.reason, contains('LambdaTest runs up to 10 at once'));
    });

    test('keeps a large selection local when LambdaTest is not available', () async {
      devices(emulators: [_emulator]);

      final choice = await choose(AutoPlatform.android, files: 20, lambdaTest: false);

      expect(choice.variant, ItVariant.androidLocal);
      expect(choice.reason, contains('LambdaTest credentials are not available'));
    });

    test('uses LambdaTest when nothing local is ready', () async {
      devices();

      final choice = await choose(AutoPlatform.android);

      expect(choice.variant, ItVariant.ltAndroid);
      expect(choice.reason, 'no local Android device or emulator is ready');
    });

    test('has no target without a local device or LambdaTest', () async {
      devices();

      final choice = await choose(AutoPlatform.android, lambdaTest: false);

      expect(choice.variant, isNull);
      expect(choice.reason, contains('LambdaTest credentials are not available'));
    });
  });

  group('ios', () {
    test('runs on the spec simulator, even for a large selection', () async {
      devices(iosSimulators: [_simulator]);

      final choice = await choose(AutoPlatform.ios, files: 20);

      expect(choice.variant, ItVariant.iosLocal);
      expect(choice.reason, startsWith("iPhone 17 Pro simulator: it shares this Mac's network and needs no signing"));
      verifyNever(picker.localIosRealDevices);
    });

    test('uses LambdaTest when no local iOS target exists', () async {
      devices();

      final choice = await choose(AutoPlatform.ios);

      expect(choice.variant, ItVariant.ltIos);
      expect(choice.reason, 'no iPhone 17 Pro simulator is available');
    });

    test('has no target without a local iOS target or LambdaTest', () async {
      devices();

      final choice = await choose(AutoPlatform.ios, lambdaTest: false);

      expect(choice.variant, isNull);
    });
  });

  test('chooses each requested platform independently, in order', () async {
    devices(emulators: [_emulator], iosSimulators: [_simulator]);

    final choices = await ItTargetSelector().choose(
      platforms: AutoPlatform.values,
      selectedTestFiles: 12,
      lambdaTestAvailable: true,
    );

    expect([for (final choice in choices) choice.variant], [ItVariant.ltAndroid, ItVariant.iosLocal]);
  });

  group('selectedTestFiles', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('it_target_selector');
      addTearDown(() => repo.deleteSync(recursive: true));
    });

    test('is null when the checkout has no Patrol test directory', () {
      expect(ItTargetSelector().selectedTestFiles(repo.path), isNull);
    });

    test('counts only the files the filters select', () {
      final tests = Directory(patrolTestDirectoryPath(repo.path))..createSync(recursive: true);
      for (final name in ['patrol_login_test', 'rdc_journey_test', 'chatsdk_chat_journey_test']) {
        File(p.join(tests.path, '$name.dart')).writeAsStringSync("patrolTest('$name', (\$) async {});\n");
      }

      expect(ItTargetSelector().selectedTestFiles(repo.path), 3);
      expect(ItTargetSelector().selectedTestFiles(repo.path, targetRegex: 'journey'), 2);
    });
  });
}
