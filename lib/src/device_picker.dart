import 'dart:convert';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_device_spec.dart';

/// Discovers locally-connected devices to target for an integration test run.
///
/// Every device-discovery shell-out (`adb`, `xcrun`) goes through
/// [MplatrolShell] so it can be mocked in tests. All methods are tolerant of a
/// failing/empty/malformed tool: they return `null` rather than throwing so a
/// caller can fall back to another target.
class DevicePicker {
  /// Regex matching a single `xcrun simctl list devices` entry, e.g.
  /// `    iPhone 17 Pro (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX) (Booted)`.
  ///
  /// Group 1 is the device name, group 2 the UDID, group 3 the state.
  static final RegExp _simDeviceLine = RegExp(r'^\s*(.+?)\s+\(([0-9A-Fa-f]{8}-[0-9A-Fa-f-]+)\)\s+\((\w+)\)\s*$');

  /// Regex matching an iOS-26 runtime header, e.g. `-- iOS 26.0 --`.
  static final RegExp _ios26Header = RegExp(r'^\s*--\s*iOS 26(?:\.(\d+))?[.\d]*\s*--\s*$');

  /// Regex matching any runtime header, e.g. `-- watchOS 11.0 --`.
  static final RegExp _anyHeader = RegExp(r'^\s*--\s*.+\s*--\s*$');

  /// Pulls the first integer model number out of an iPhone name so that, e.g.,
  /// `iPhone 17 Pro Max` sorts newer than `iPhone 16`.
  static final RegExp _iphoneModel = RegExp(r'iPhone\s+(\d+)');

  /// Every locally-attached physical Android device that Flutter or adb can
  /// target, excluding emulators. Flutter's machine output is preferred because
  /// it is the same device id namespace Patrol receives via `-d`; adb is a
  /// fallback so a ready USB/wireless device still appears if Flutter discovery
  /// fails or omits it.
  Future<List<LocalDevice>> localAndroidRealDevices() async {
    final flutterDevices = await _flutterAndroidRealDevices();
    final adbDevices = await _adbAndroidDevices();
    final adbRealDevices = adbDevices.where((device) => !device.isEmulator).map((device) => device.localDevice);
    return _mergeDevices(flutterDevices, adbRealDevices);
  }

  /// Every booted Android emulator that is the spec AVD ([LocalDeviceSpec.androidAvdName]), in
  /// `adb devices -l` order. Other emulators and physical phones are never auto-selected: a physical phone is
  /// used only through `--device`. Empty when none are ready (or `adb` is unavailable).
  Future<List<LocalDevice>> localAndroidDevices() async => (await scanAndroidEmulators()).conforming;

  /// The booted Android emulators split into the spec AVD and the ones [DeviceScan.rejected] for being
  /// another AVD, so a caller can warn instead of silently skipping them.
  Future<DeviceScan> scanAndroidEmulators() async {
    final conforming = <LocalDevice>[];
    final rejected = <String>[];
    for (final device in await _adbAndroidDevices()) {
      if (!device.isEmulator) {
        continue;
      }
      final avd = await getDep<LocalDeviceService>().androidAvdName(device.id);
      if (avd == LocalDeviceSpec.androidAvdName) {
        conforming.add(device.localDevice);
      } else {
        rejected.add('${device.label} runs ${avd == null ? 'an unknown AVD' : 'AVD $avd'}');
      }
    }
    return DeviceScan(conforming: conforming, rejected: rejected);
  }

  Future<List<_AdbAndroidDevice>> _adbAndroidDevices() async {
    final result = await getDep<MplatrolShell>().run('adb devices -l', throwOnError: false, silent: true);
    if (result.exitCode != 0) {
      return const [];
    }

    final devices = <_AdbAndroidDevice>[];
    for (final rawLine in result.outLines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('List of devices')) {
        continue;
      }
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 2 || fields[1] != 'device') {
        continue;
      }
      final serial = fields[0];
      devices.add(
        _AdbAndroidDevice(
          id: serial,
          label: _androidLabel(serial, fields),
          isEmulator: _isAdbAndroidEmulator(serial),
        ),
      );
    }
    return devices;
  }

  Future<List<LocalDevice>> _flutterAndroidRealDevices() async {
    final result = await getDep<MplatrolShell>().run(
      'dart pub global run fvm:main flutter devices --machine',
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != 0 || result.outText.trim().isEmpty) {
      return const [];
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(result.outText);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) {
      return const [];
    }

    final devices = <LocalDevice>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final targetPlatform = entry['targetPlatform'];
      if (targetPlatform is! String || !targetPlatform.startsWith('android')) {
        continue;
      }
      if (entry['emulator'] == true || entry['isSupported'] == false) {
        continue;
      }
      final id = entry['id'];
      if (id is! String || id.trim().isEmpty) {
        continue;
      }
      devices.add(
        LocalDevice(id: id.trim(), label: _flutterDeviceLabel(entry, id.trim())),
      );
    }
    return devices;
  }

  /// A friendly Android label like `Pixel 7 (emulator-5554)` from the `model:`
  /// (else `device:`) field of an `adb devices -l` row, falling back to the bare
  /// serial when neither is present.
  String _androidLabel(String serial, List<String> fields) {
    String? value(String key) {
      for (final field in fields) {
        if (field.startsWith(key)) {
          return field.substring(key.length).replaceAll('_', ' ');
        }
      }
      return null;
    }

    final name = value('model:') ?? value('device:');
    return name == null ? serial : '$name ($serial)';
  }

  bool _isAdbAndroidEmulator(String serial) => serial.startsWith('emulator-');

  List<LocalDevice> _mergeDevices(
    Iterable<LocalDevice> preferred,
    Iterable<LocalDevice> fallback,
  ) {
    final devices = <LocalDevice>[];
    final seen = <String>{};

    void addDevices(Iterable<LocalDevice> source) {
      for (final device in source) {
        if (seen.add(device.id)) {
          devices.add(device);
        }
      }
    }

    addDevices(preferred);
    addDevices(fallback);
    return devices;
  }

  /// Every locally-attached physical iOS device that Flutter can target.
  ///
  /// Patrol takes the same device id as `flutter devices`, not the devicectl
  /// pairing identifier, so this intentionally reads Flutter's machine output.
  Future<List<LocalDevice>> localIosRealDevices() async {
    final result = await getDep<MplatrolShell>().run(
      'dart pub global run fvm:main flutter devices --machine',
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != 0 || result.outText.trim().isEmpty) {
      return const [];
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(result.outText);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) {
      return const [];
    }

    final devices = <LocalDevice>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      if (entry['targetPlatform'] != 'ios' || entry['emulator'] == true) {
        continue;
      }
      final id = entry['id'];
      if (id is! String || id.trim().isEmpty) {
        continue;
      }
      devices.add(LocalDevice(id: id, label: _flutterDeviceLabel(entry, id)));
    }
    return devices;
  }

  String _flutterDeviceLabel(Map<String, dynamic> entry, String id) {
    final name = entry['name'];
    final sdk = entry['sdk'];
    final labelParts = [
      if (name is String && name.trim().isNotEmpty) name.trim() else id,
      if (sdk is String && sdk.trim().isNotEmpty) sdk.trim(),
    ];
    return '${labelParts.join(' - ')} ($id)';
  }

  /// Every available iOS-26 iPhone simulator, best-first (Booted before not,
  /// then newest runtime, then newest model, then lowest UDID), each labelled with its name and state
  /// (e.g. `iPhone 17 Pro (Booted)`). Empty when none exist (or `xcrun` is
  /// unavailable). Used by `mplatrol run` to offer an interactive choice when
  /// more than one simulator is available.
  Future<List<LocalDevice>> localIosSimulators() async {
    final result = await getDep<MplatrolShell>().run(
      'xcrun simctl list devices available',
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != 0) {
      return const [];
    }

    final candidates = _parseIos26Iphones(result.outLines)..sort(_compareCandidates);
    return candidates
        .map(
          (candidate) => LocalDevice(
            id: candidate.udid,
            label: '${candidate.name}'
                '${candidate.isBooted ? ' (Booted)' : ''}',
          ),
        )
        .toList();
  }

  /// The iOS simulators split into the spec simulator ([LocalDeviceSpec.iosDeviceName], best-first) and the
  /// booted ones [DeviceScan.rejected] for being another model, so a caller can warn about them.
  Future<DeviceScan> scanIosSimulators() async {
    final all = await localIosSimulators();
    return DeviceScan(
      conforming: all.where((device) => LocalDeviceSpec.isSpecSimulatorLabel(device.label)).toList(),
      rejected: [
        for (final device in all)
          if (!LocalDeviceSpec.isSpecSimulatorLabel(device.label) && device.label.endsWith('(Booted)'))
            '${device.label} is booted',
      ],
    );
  }

  List<_SimCandidate> _parseIos26Iphones(Iterable<String> lines) {
    final candidates = <_SimCandidate>[];
    var inIos26 = false;
    var runtimeMinor = 0;

    for (final line in lines) {
      if (_anyHeader.hasMatch(line)) {
        final runtime = _ios26Header.firstMatch(line);
        inIos26 = runtime != null;
        runtimeMinor = int.tryParse(runtime?.group(1) ?? '') ?? 0;
        continue;
      }
      if (!inIos26) {
        continue;
      }
      final match = _simDeviceLine.firstMatch(line);
      if (match == null) {
        continue;
      }
      final name = match.group(1)!;
      final modelMatch = _iphoneModel.firstMatch(name);
      if (modelMatch == null) {
        continue;
      }
      candidates.add(
        _SimCandidate(
          udid: match.group(2)!,
          name: name,
          model: int.parse(modelMatch.group(1)!),
          isBooted: match.group(3) == 'Booted',
          runtimeMinor: runtimeMinor,
        ),
      );
    }
    return candidates;
  }

  /// Orders candidates best-first: Booted before not, then newest runtime, then newest model, then lowest
  /// UDID, so the pick is deterministic when several simulators share a name.
  int _compareCandidates(_SimCandidate a, _SimCandidate b) {
    if (a.isBooted != b.isBooted) {
      return a.isBooted ? -1 : 1;
    }
    if (a.runtimeMinor != b.runtimeMinor) {
      return b.runtimeMinor.compareTo(a.runtimeMinor);
    }
    if (a.model != b.model) {
      return b.model.compareTo(a.model);
    }
    return a.udid.compareTo(b.udid);
  }
}

class _SimCandidate {
  _SimCandidate({
    required this.udid,
    required this.name,
    required this.model,
    required this.isBooted,
    required this.runtimeMinor,
  });

  final String udid;
  final String name;
  final int model;
  final bool isBooted;
  final int runtimeMinor;
}

class _AdbAndroidDevice {
  _AdbAndroidDevice({
    required this.id,
    required this.label,
    required this.isEmulator,
  });

  final String id;
  final String label;
  final bool isEmulator;

  LocalDevice get localDevice => LocalDevice(id: id, label: label);
}

/// The devices of one platform that meet [LocalDeviceSpec], and a description of each booted one that does not.
class DeviceScan {
  /// Creates a scan.
  DeviceScan({required this.conforming, required this.rejected});

  /// The devices `mplatrol run` may pick.
  final List<LocalDevice> conforming;

  /// Booted devices that were skipped, each with the reason.
  final List<String> rejected;
}

/// A locally-targetable device/simulator: its tool [id] (adb serial or simulator
/// UDID) and a human-readable [label] for the interactive picker.
class LocalDevice {
  LocalDevice({required this.id, required this.label});

  /// The id passed to the build/test tool (`-d <id>`): an adb serial or a
  /// simulator UDID.
  final String id;

  /// What the interactive picker shows for this device.
  final String label;
}
