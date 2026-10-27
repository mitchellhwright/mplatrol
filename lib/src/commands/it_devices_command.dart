import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_device_spec.dart';

/// DEV NOTE* When you create a new command, make sure you add it to the [MplatrolCommandRunner]
///
/// `mplatrol devices` lists the local devices/simulators and the configured
/// LambdaTest real devices that the E2E variants can target.
class ItDevicesCommand extends BaseCommand {
  MplatrolConfig get config => getDep<MplatrolConfig>();
  DevicePicker get _devicePicker => getDep<DevicePicker>();

  ItDevicesCommand() {
    argParser.addFlag(
      'setup',
      negatable: false,
      help: 'Create the spec emulator and simulator if missing and repair drift (${LocalDeviceSpec.summary}). '
          'Prints what it changed; safe to rerun.',
    );
  }

  @override
  String get name => 'devices';

  @override
  String get description => 'List local devices/simulators and the configured LambdaTest devices to target.';

  @override
  void validateInput() {}

  @override
  Future<int> runCommand() async {
    final leased = _leasedDevices();
    if (argResults['setup'] as bool) {
      if (leased.isNotEmpty) {
        logger.err('[local-device] not changing the local devices while a run uses them: ${leased.join('; ')}. '
            'Rerun `${LocalDeviceSpec.setupCommand}` when it finishes.');
        return ExitCode.tempFail.code;
      }
      return _setup();
    }
    leased.map((line) => '[local-device] $line').forEach(logger.info);
    logger.info('Local Android physical devices (flutter/adb):');
    _printList(
      (await _devicePicker.localAndroidRealDevices()).map((device) => device.label).toList(),
      '(none connected)',
    );

    logger.info('');
    logger.info('Local Android (adb devices):');
    final adb = await shell.run('adb devices -l', throwOnError: false, silent: true);
    _printList(
      adb.outLines.skip(1).where((line) => line.trim().isNotEmpty).toList(),
      '(none — boot an emulator or attach a device)',
    );

    if (platformWrapper.isMac) {
      logger.info('');
      logger.info('Local iOS physical devices (flutter devices):');
      _printList(
        (await _devicePicker.localIosRealDevices()).map((device) => device.label).toList(),
        '(none connected)',
      );

      logger.info('');
      logger.info('Local iOS simulators (xcrun simctl, available):');
      _printList(
        (await _devicePicker.localIosSimulators()).map((device) => device.label).take(15).toList(),
        '(none available)',
      );
    }

    logger.info('');
    logger.info('LambdaTest real devices (configured variant defaults):');
    if ((platformWrapper.environment['LT_USERNAME'] ?? '').isEmpty) {
      logger.info('  (set LT_USERNAME + LT_ACCESS_KEY to use the lt-* variants)');
    }
    logger.info('  ${ItVariant.ltAndroid.id}: ${config.it.ltAndroidDevices.join(', ')}');
    logger.info('  ${ItVariant.ltIos.id}: ${config.it.ltIosDevices.join(', ')}');
    return ExitCode.success.code;
  }

  Future<int> _setup() async {
    try {
      for (final change in await getDep<LocalDeviceService>().setup()) {
        logger.info('  $change');
      }
    } on LocalDeviceSetupException catch (error) {
      logger.err(error.message);
      return ExitCode.unavailable.code;
    }
    logger.info('Boot the spec AVD with `${LocalDeviceSpec.androidBootCommand}`; `mplatrol run` boots the simulator.');
    return ExitCode.success.code;
  }

  /// `<platform> is leased by <holder>` for each local device another `mplatrol` run holds.
  List<String> _leasedDevices() {
    final leases = getDep<LocalDeviceLeases>();
    return [
      for (final platform in const ['android', 'ios'])
        if (leases.heldElsewhere(platform) case final holder?) 'the local $platform device is leased by $holder',
    ];
  }

  void _printList(List<String> lines, String emptyMessage) {
    if (lines.isEmpty) {
      logger.info('  $emptyMessage');
      return;
    }
    for (final line in lines) {
      logger.info('  $line');
    }
  }
}
