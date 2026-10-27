import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';

/// A platform `mplatrol run auto` picks a target for.
enum AutoPlatform {
  /// Local Android device/emulator or LambdaTest Android.
  android(local: ItVariant.androidLocal, lambdaTest: ItVariant.ltAndroid),

  /// Local iPhone/simulator or LambdaTest iOS.
  ios(local: ItVariant.iosLocal, lambdaTest: ItVariant.ltIos);

  const AutoPlatform({required this.local, required this.lambdaTest});

  /// The variant used when a local target is ready.
  final ItVariant local;

  /// The variant used on LambdaTest real devices.
  final ItVariant lambdaTest;
}

/// The variant `auto` chose for one platform and why.
class AutoTargetChoice {
  /// Creates a choice of [variant] for [platform], explained by [reason].
  const AutoTargetChoice({required this.platform, required this.variant, required this.reason});

  /// The platform this choice is for.
  final AutoPlatform platform;

  /// The chosen variant, or null when no target is available.
  final ItVariant? variant;

  /// Why [variant] was chosen (or why none could be).
  final String reason;
}

/// Picks the fastest available target per platform for `mplatrol run auto`.
///
/// Both local and LambdaTest runs build on this Mac; they differ in what
/// follows. A local run skips the LambdaTest upload and device queue (a few
/// minutes) but runs its tests one after another. LambdaTest Android runs up to
/// [defaultLtMaxParallel] devices at once, so it wins once a selection has more than
/// [localAndroidMaxTestFiles] test files. LambdaTest iOS adds an upload, a device
/// queue and wave scheduling, so a local iOS target is preferred whenever one exists. Local targets
/// are only the spec devices of [LocalDeviceSpec]: the spec simulator (it shares
/// this Mac's network and needs no signing) and the spec AVD.
class ItTargetSelector {
  /// Largest selection (in Patrol test files) run on a local Android target
  /// when LambdaTest is also available. Past this, [defaultLtMaxParallel] parallel
  /// LambdaTest devices finish sooner than one local device despite the upload and queue.
  static const localAndroidMaxTestFiles = 4;

  DevicePicker get _picker => getDep<DevicePicker>();

  /// How many Patrol test files in [repo] the [target]/[targetRegex]/[sdk]
  /// filters select, or null when [repo] has no Patrol test directory.
  int? selectedTestFiles(String repo, {String? target, String? targetRegex, String? sdk}) {
    if (!Directory(patrolTestDirectoryPath(repo)).existsSync()) {
      return null;
    }
    return discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex, sdk: sdk).length;
  }

  /// Chooses a target for each of [platforms] for a selection of
  /// [selectedTestFiles] Patrol test files. [lambdaTestAvailable] says whether
  /// LambdaTest credentials were resolved.
  Future<List<AutoTargetChoice>> choose({
    required List<AutoPlatform> platforms,
    required int selectedTestFiles,
    required bool lambdaTestAvailable,
  }) async {
    return [
      for (final platform in platforms)
        switch (platform) {
          AutoPlatform.android => await _chooseAndroid(selectedTestFiles, lambdaTestAvailable),
          AutoPlatform.ios => await _chooseIos(lambdaTestAvailable),
        },
    ];
  }

  Future<AutoTargetChoice> _chooseAndroid(int selectedTestFiles, bool lambdaTestAvailable) async {
    const platform = AutoPlatform.android;
    final local = await _picker.localAndroidDevices();
    final files = '$selectedTestFiles test file${selectedTestFiles == 1 ? '' : 's'}';
    if (local.isNotEmpty && (!lambdaTestAvailable || selectedTestFiles <= localAndroidMaxTestFiles)) {
      return AutoTargetChoice(
        platform: platform,
        variant: platform.local,
        reason: lambdaTestAvailable
            ? '$files on ${local.first.label}: running locally skips the LambdaTest upload and device queue'
            : '${local.first.label} is ready and LambdaTest credentials are not available',
      );
    }
    if (lambdaTestAvailable) {
      return AutoTargetChoice(
        platform: platform,
        variant: platform.lambdaTest,
        reason: local.isEmpty
            ? 'no local Android device or emulator is ready'
            : '$files: LambdaTest runs up to $defaultLtMaxParallel at once, faster than one local device',
      );
    }
    return const AutoTargetChoice(
      platform: platform,
      variant: null,
      reason: 'no local Android device or emulator is ready and LambdaTest credentials are not available',
    );
  }

  Future<AutoTargetChoice> _chooseIos(bool lambdaTestAvailable) async {
    const platform = AutoPlatform.ios;
    final simulators = (await _picker.scanIosSimulators()).conforming;
    if (simulators.isNotEmpty) {
      return AutoTargetChoice(
        platform: platform,
        variant: platform.local,
        reason: "${simulators.first.label} simulator: it shares this Mac's network and needs no signing; "
            'LambdaTest iOS runs its shards one at a time, so it is not faster',
      );
    }
    if (lambdaTestAvailable) {
      return const AutoTargetChoice(
        platform: platform,
        variant: ItVariant.ltIos,
        reason: 'no ${LocalDeviceSpec.iosDeviceName} simulator is available',
      );
    }
    return const AutoTargetChoice(
      platform: platform,
      variant: null,
      reason: 'no ${LocalDeviceSpec.iosDeviceName} simulator is available and LambdaTest credentials are not available',
    );
  }
}
