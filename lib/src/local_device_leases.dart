import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';

/// Env var: the local device lease a parent `mplatrol` already holds for this process, as
/// `<platform>=<lease file>` lines (e.g. `android=/…/local-devices/android/1-0-2.lease`). `mplatrol matrix`
/// sets it for each local leg, so the leg's `mplatrol run` uses the device it was leased instead of waiting
/// for it.
const localDeviceLeaseEnv = 'MPLATROL_LOCAL_DEVICE_LEASE';

/// Exclusive use of the machine's local emulator and simulator for every `mplatrol` path that touches them.
///
/// A local `mplatrol run` on the emulator or a simulator [hold]s its platform for the whole run (all its tenants
/// and the video recording), waiting first come, first served for another run or matrix leg to finish.
/// `mplatrol doctor` and `mplatrol devices` ask [heldElsewhere] and leave a leased device alone. Physical phones,
/// and an emulator other than the spec one (an agent's own AVD), are never leased.
class LocalDeviceLeases {
  /// Creates the service; [devices] overrides the leases under `$HOME` (for tests).
  LocalDeviceLeases({MatrixLocalDevices? devices}) : _override = devices;

  final MatrixLocalDevices? _override;
  final _held = <String, LtSlotLease>{};

  PlatformWrapper get _platform => getDep<PlatformWrapper>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  MatrixLocalDevices? get _devices => _override ?? MatrixLocalDevices.fromHome(_platform.environment['HOME'], _logger);

  /// Leases [platform]'s local device (`android` or `ios`) for this process until [releaseAll], unless
  /// [device] names a physical phone, a parent already holds it ([localDeviceLeaseEnv]) or this process
  /// holds it. [label] names the holder in the lease file and the waiting line.
  Future<void> hold(String platform, {required String label, String? device}) async {
    if (_held.containsKey(platform) || inherited(platform) || !isLeasedDevice(platform, device)) {
      return;
    }
    // An agent's own emulator runs beside the spec one: Patrol talks to the app on the device. Every iOS
    // simulator shares the Mac's network and Patrol's fixed ports 8081/8082, so simulators are always leased.
    if (platform == 'android' && device != null && !await getDep<LocalDeviceService>().isSpecEmulator(device)) {
      _logger.detail('[local-device] $device is not the spec emulator, so it is not leased');
      return;
    }
    final devices = _devices;
    if (devices == null) {
      _logger.detail('[local-device] no HOME, so the local $platform device is not leased');
      return;
    }
    _held[platform] = await devices.budgetForPlatform(platform).acquire(wanted: 1, label: label);
    _logger.detail('[local-device] leased the local $platform device for $label');
  }

  /// Releases every device [hold] leased.
  Future<void> releaseAll() async {
    final leases = [..._held.values];
    _held.clear();
    for (final lease in leases) {
      await lease.release();
    }
  }

  /// Whether a parent `mplatrol` holds [platform]'s device for this process: [localDeviceLeaseEnv] names a
  /// lease file of [platform] that still exists.
  bool inherited(String platform) {
    for (final line in (_platform.environment[localDeviceLeaseEnv] ?? '').split('\n')) {
      final separator = line.indexOf('=');
      if (separator > 0 &&
          line.substring(0, separator).trim() == platform &&
          File(line.substring(separator + 1).trim()).existsSync()) {
        return true;
      }
    }
    return false;
  }

  /// Who else holds [platform]'s local device, e.g. `acme:android (pid 4242)`; null when it is free,
  /// held by this process, or held by a parent of it.
  String? heldElsewhere(String platform) {
    if (_held.containsKey(platform) || inherited(platform)) {
      return null;
    }
    final leases = _devices?.budgetForPlatform(platform).liveLeases() ?? const [];
    if (leases.isEmpty) {
      return null;
    }
    return [
      for (final lease in leases) lease.pid == null ? lease.label : '${lease.label} (pid ${lease.pid})',
    ].join(', ');
  }

  /// The environment that hands every device this process leased to a child `mplatrol`, so its `mplatrol run` uses
  /// them instead of waiting for them; empty when this process holds none.
  Map<String, String> childEnvironment() => _held.isEmpty
      ? const {}
      : {
          localDeviceLeaseEnv: [for (final entry in _held.entries) envValue(entry.key, entry.value)].join('\n')
        };

  /// The [localDeviceLeaseEnv] value that hands [lease] of [platform] to a child process.
  static String envValue(String platform, LtSlotLease lease) => '$platform=${lease.file ?? ''}';

  /// Whether [device] on [platform] is the leased local device: the emulator (`emulator-*`), a simulator
  /// (a CoreSimulator UDID), or the default device when [device] is null. A physical phone is not.
  static bool isLeasedDevice(String platform, String? device) {
    if (device == null) {
      return true;
    }
    return platform == 'ios' ? _coreSimulatorId.hasMatch(device) : device.startsWith('emulator-');
  }

  static final _coreSimulatorId =
      RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$');
}
