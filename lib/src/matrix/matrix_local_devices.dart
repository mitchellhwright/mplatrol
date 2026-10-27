import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:path/path.dart' as p;

/// The machine's one local emulator and one simulator ([LocalDeviceSpec]), each leased by at most one
/// local leg at a time across every `mplatrol` process of the user: a budget of 1 per platform
/// under `<directory>/<platform>`, with the stale-lease handling and first-come, first-served waiting
/// of [LtSlotBudget]. A leg waiting for its device logs `[local-device] … waiting for`, which the
/// matrix stall cap does not count. `mplatrol matrix` leases per leg; a standalone `mplatrol run`, `mplatrol doctor`
/// and `mplatrol devices` go through `LocalDeviceLeases`.
class MatrixLocalDevices {
  /// Creates the leases under [directory].
  MatrixLocalDevices({required this.directory, required MplatrolLogger logger, this.pollInterval = _poll})
      : _logger = logger;

  /// The leases under `$HOME/.mplatrol/local-devices`, or null without a `HOME`.
  static MatrixLocalDevices? fromHome(String? home, MplatrolLogger logger) => home == null || home.isEmpty
      ? null
      : MatrixLocalDevices(directory: p.join(home, '.mplatrol', 'local-devices'), logger: logger);

  static const _poll = Duration(seconds: 15);

  /// Holds one directory of lease files per platform.
  final String directory;

  /// How often a waiting leg checks whether the device is free.
  final Duration pollInterval;

  final MplatrolLogger _logger;
  final _budgets = <String, LtSlotBudget>{};

  /// The lease budget of [leg]'s platform.
  LtSlotBudget budgetFor(MatrixLeg leg) => budgetForPlatform(leg.platform);

  /// The lease budget of [platform] (`android` or `ios`).
  LtSlotBudget budgetForPlatform(String platform) => _budgets.putIfAbsent(
        platform,
        () => LtSlotBudget(
          directory: p.join(directory, platform),
          limit: 1,
          logger: _logger,
          tag: 'local-device',
          unit: platform == 'ios'
              ? 'local ios simulator (${LocalDeviceSpec.iosDeviceName})'
              : 'local android emulator (${LocalDeviceSpec.androidAvdName})',
          limitSource: '',
          pollInterval: pollInterval,
        ),
      );

  /// Waits for [leg]'s device and leases it; [report] gets the waiting lines. Throws
  /// [LtSlotWaitCancelled] when [cancel] completes first.
  Future<LtSlotLease> acquire(MatrixLeg leg,
          {required void Function(String line) report, required Future<void> cancel}) =>
      budgetFor(leg).acquire(wanted: 1, label: '$leg', report: report, cancel: cancel);
}
