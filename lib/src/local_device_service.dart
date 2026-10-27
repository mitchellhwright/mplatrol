import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/doctor/doctor_checks.dart';
import 'package:mplatrol/src/local_device_spec.dart';

/// `mplatrol devices --setup` could not create or repair a spec device.
class LocalDeviceSetupException implements Exception {
  /// Creates an exception with a [message] that says what to do next.
  const LocalDeviceSetupException(this.message);

  /// What failed and how to fix it.
  final String message;

  @override
  String toString() => message;
}

/// Creates, repairs, checks and boots the emulator and simulator of [LocalDeviceSpec].
class LocalDeviceService {
  static const _bootPollDelay = Duration(seconds: 3);
  static const _progressInterval = Duration(seconds: 15);

  /// How long [bootAndroid] waits for a cold boot.
  static const bootTimeout = Duration(seconds: 240);

  /// Creates the service; [clock] is injectable so tests do not sleep.
  LocalDeviceService({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  MplatrolShell get _shell => getDep<MplatrolShell>();
  FileSystem get _files => getDep<FileSystem>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// Where the spec AVD's `config.ini` lives: `$ANDROID_AVD_HOME`, else `$ANDROID_USER_HOME/avd`, else
  /// `~/.android/avd`.
  String get androidConfigPath {
    final env = _platform.environment;
    final avdHome = env['ANDROID_AVD_HOME'] ??
        (env['ANDROID_USER_HOME'] == null ? '${env['HOME']}/.android/avd' : '${env['ANDROID_USER_HOME']}/avd');
    return '$avdHome/${LocalDeviceSpec.androidAvdName}.avd/config.ini';
  }

  /// Creates or repairs the spec AVD and, on a Mac, the spec simulator. Returns one line per action taken
  /// (or per device already conforming), so a rerun prints what it left alone.
  Future<List<String>> setup() async {
    final changes = [...await _setupAvd()];
    if (_platform.isMac) {
      changes.add(await _setupSimulator());
    }
    return changes;
  }

  Future<List<String>> _setupAvd() async {
    final changes = <String>[];
    final path = androidConfigPath;
    if (!_files.fileExistsSync(path)) {
      await _createAvd();
      changes.add('created AVD ${LocalDeviceSpec.androidAvdName}');
    }
    final config = AvdConfig.parse(_files.readAsStringSync(path));
    final drift = config.drift();
    final unrepairable = drift.where((item) => !item.repairable);
    if (unrepairable.isNotEmpty) {
      throw LocalDeviceSetupException(
        'AVD ${LocalDeviceSpec.androidAvdName} differs from the spec in ${unrepairable.join('; ')}. '
        'Delete it with `avdmanager delete avd -n ${LocalDeviceSpec.androidAvdName}` and rerun '
        '`${LocalDeviceSpec.setupCommand}`.',
      );
    }
    if (drift.isEmpty) {
      changes.add('AVD ${LocalDeviceSpec.androidAvdName} already conforms');
      return changes;
    }
    _files.writeAsStringSync(filePath: '$path.mplatrol-backup', newContent: _files.readAsStringSync(path));
    _files.writeAsStringSync(filePath: path, newContent: config.repaired());
    changes.add('repaired AVD ${LocalDeviceSpec.androidAvdName}: ${drift.join('; ')} (backup: $path.mplatrol-backup)');
    return changes;
  }

  Future<void> _createAvd() async {
    final arguments = [
      'create',
      'avd',
      '-n',
      LocalDeviceSpec.androidAvdName,
      '-k',
      LocalDeviceSpec.androidSystemImage,
      '-d',
      LocalDeviceSpec.androidDeviceProfile,
    ];
    const hint = 'Install the system image with `sdkmanager --install "${LocalDeviceSpec.androidSystemImage}"` '
        '(Android command-line tools) and rerun `${LocalDeviceSpec.setupCommand}`.';
    try {
      final result = await _shell.runArgs('avdmanager', arguments, throwOnError: false, silent: true);
      if (result.exitCode != 0) {
        throw LocalDeviceSetupException('`avdmanager ${arguments.join(' ')}` failed: ${result.errText.trim()} $hint');
      }
    } on ProcessException catch (error) {
      throw LocalDeviceSetupException('Could not run avdmanager (${error.message}). $hint');
    }
  }

  Future<String> _setupSimulator() async {
    final entries = await _simulators();
    final existing = entries.where((entry) => entry.conforms);
    if (existing.isNotEmpty) {
      return 'simulator ${LocalDeviceSpec.iosDeviceName} already conforms (${existing.first.udid})';
    }
    final runtimes = await _shell.runArgs(
      'xcrun',
      ['simctl', 'list', 'runtimes', 'available'],
      throwOnError: false,
      silent: true,
    );
    final runtime = SimulatorEntry.newestRuntime(runtimes.outLines);
    if (runtime == null) {
      throw const LocalDeviceSetupException(
        'No iOS ${LocalDeviceSpec.iosRuntimeMajor} simulator runtime is installed. Install it with '
        '`xcodebuild -downloadPlatform iOS` or Xcode > Settings > Components, then rerun '
        '`${LocalDeviceSpec.setupCommand}`.',
      );
    }
    final created = await _shell.runArgs(
      'xcrun',
      ['simctl', 'create', LocalDeviceSpec.iosDeviceName, LocalDeviceSpec.iosDeviceType, runtime],
      throwOnError: false,
      silent: true,
    );
    if (created.exitCode != 0) {
      throw LocalDeviceSetupException('`xcrun simctl create` failed: ${created.errText.trim()}');
    }
    return 'created simulator ${LocalDeviceSpec.iosDeviceName} on $runtime (${created.outText.trim()})';
  }

  Future<List<SimulatorEntry>> _simulators() async {
    final result = await _shell.runArgs(
      'xcrun',
      ['simctl', 'list', 'devices', 'available'],
      throwOnError: false,
      silent: true,
    );
    return result.exitCode == 0 ? SimulatorEntry.parse(result.outLines) : const [];
  }

  /// Doctor findings for the spec devices: the AVD and the simulator exist and conform. [adbDevices] is
  /// `adb devices` output; the AVD name of each booted emulator is checked.
  Future<List<DoctorFinding>> doctorFindings(Iterable<String> adbDevices) async {
    final findings = <DoctorFinding>[];
    final path = androidConfigPath;
    if (_files.fileExistsSync(path)) {
      final drift = AvdConfig.parse(_files.readAsStringSync(path)).drift();
      findings.add(
        DoctorFixes.androidSpecAvd.finding(ok: drift.isEmpty, detail: drift.isEmpty ? null : '${drift.join('; ')}.'),
      );
    } else {
      findings.add(DoctorFixes.androidSpecAvd.finding(ok: false, detail: 'AVD not found.'));
    }
    for (final line in adbDevices) {
      final serial = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim())?.group(1);
      if (serial == null) {
        continue;
      }
      final name = await androidAvdName(serial);
      if (name != LocalDeviceSpec.androidAvdName) {
        findings
            .add(DoctorFixes.bootedEmulatorSpec.finding(ok: false, detail: '$serial is ${name ?? 'an unknown AVD'}.'));
      }
    }
    if (_platform.isMac) {
      final entries = await _simulators();
      findings.add(
        DoctorFixes.iosSpecSimulator.finding(ok: entries.any((entry) => entry.conforms)),
      );
      for (final entry in entries.where((entry) => entry.booted && !entry.conforms)) {
        findings.add(
          DoctorFixes.bootedSimulatorSpec
              .finding(ok: false, detail: '${entry.name} (iOS ${entry.iosMajor}) is booted.'),
        );
      }
    }
    return findings;
  }

  /// Whether the emulator [serial] runs the spec AVD ([LocalDeviceSpec.androidAvdName]) the machine-wide
  /// Android lease guards. An emulator that does not answer counts as the spec one, so a run never skips a
  /// lease it needs.
  Future<bool> isSpecEmulator(String serial) async {
    final name = await androidAvdName(serial);
    return name == null || name == LocalDeviceSpec.androidAvdName;
  }

  /// The AVD name of the emulator [serial], or null when it does not answer.
  Future<String?> androidAvdName(String serial) async {
    final result = await _shell.runArgs(
      'adb',
      ['-s', serial, 'emu', 'avd', 'name'],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 10),
    );
    if (result.exitCode != 0) {
      return null;
    }
    for (final line in result.outLines) {
      final name = line.trim();
      if (name.isNotEmpty && name != 'OK') {
        return name;
      }
    }
    return null;
  }

  /// Starts the spec AVD detached and waits until it is listed by `adb devices` in state `device` and reports
  /// `sys.boot_completed=1`; a cold boot takes 1-3 minutes. Returns the emulator serial, or null when the AVD
  /// does not exist. Throws [LocalDeviceSetupException] when the emulator cannot be launched or is not booted
  /// within [bootTimeout].
  Future<String?> bootAndroid() async {
    if (!_files.fileExistsSync(androidConfigPath)) {
      return null;
    }
    final binary = _emulatorBinary();
    final arguments = ['-avd', LocalDeviceSpec.androidAvdName];
    _logger.info('Starting emulator: $binary ${arguments.join(' ')}');
    try {
      await _shell.startDetached(binary, arguments);
    } on ProcessException catch (error) {
      throw LocalDeviceSetupException(
        'Could not launch `$binary ${arguments.join(' ')}` (${error.message}). Install the Android emulator '
        'package or put it on PATH, then rerun.',
      );
    }
    return _waitForBoot();
  }

  /// `$ANDROID_HOME/emulator/emulator` (or `$ANDROID_SDK_ROOT`, or Android Studio's default `~/Library/Android/sdk`)
  /// when it exists, else `emulator` from PATH. The default matters for rounds launched by launchd, whose shell has
  /// no ANDROID_HOME.
  String _emulatorBinary() {
    final env = _platform.environment;
    final home = env['HOME'];
    for (final sdk in [env['ANDROID_HOME'], env['ANDROID_SDK_ROOT'], if (home != null) '$home/Library/Android/sdk']) {
      if (sdk == null || sdk.isEmpty) {
        continue;
      }
      final candidate = '$sdk/emulator/emulator';
      if (_files.fileExistsSync(candidate)) {
        return candidate;
      }
    }
    return 'emulator';
  }

  Future<String> _waitForBoot() async {
    final started = _clock();
    var lastReport = started;
    var sawEmulator = false;
    while (true) {
      final serial = await _specEmulatorSerial();
      sawEmulator = sawEmulator || serial != null;
      if (serial != null && await _bootCompleted(serial)) {
        return serial;
      }
      final now = _clock();
      final elapsed = now.difference(started);
      if (elapsed >= bootTimeout) {
        throw LocalDeviceSetupException(
          sawEmulator
              ? '${LocalDeviceSpec.androidAvdName} is listed by adb but sys.boot_completed is still not 1 after '
                  '${elapsed.inSeconds}s. Check the emulator window or `adb logcat`, then rerun.'
              : '${LocalDeviceSpec.androidAvdName} never appeared in `adb devices` after ${elapsed.inSeconds}s. '
                  'Run `${LocalDeviceSpec.androidBootCommand}` in a terminal to see the emulator log, then rerun.',
        );
      }
      if (now.difference(lastReport) >= _progressInterval) {
        lastReport = now;
        _logger.info(
          'Waiting for ${LocalDeviceSpec.androidAvdName} to boot (${elapsed.inSeconds}s of '
          '${bootTimeout.inSeconds}s)...',
        );
      }
      await getDep<SleepFunction>()(_bootPollDelay);
    }
  }

  /// The serial of a booted (`device` state) emulator running the spec AVD, or null.
  Future<String?> _specEmulatorSerial() async {
    final listed = await _shell.runArgs('adb', ['devices'], throwOnError: false, silent: true);
    for (final line in listed.outLines) {
      final serial = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim())?.group(1);
      if (serial != null && await androidAvdName(serial) == LocalDeviceSpec.androidAvdName) {
        return serial;
      }
    }
    return null;
  }

  Future<bool> _bootCompleted(String serial) async {
    final boot = await _shell.runArgs(
      'adb',
      ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
      throwOnError: false,
      silent: true,
    );
    return boot.outText.trim() == '1';
  }
}
