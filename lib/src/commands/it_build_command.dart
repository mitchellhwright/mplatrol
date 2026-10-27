import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:mplatrol/src/prepare_hook.dart';

/// `mplatrol build` runs the prepare hook once per tenant, then builds BOTH local platforms so a developer can
/// compile Android and iOS in a single command for fast local iteration (no LambdaTest upload/trigger).
///
/// The two platform compiles run concurrently ([Future.wait]) because they use
/// separate toolchains and write to separate output trees (Android → `build/app`,
/// iOS → `ios/build/xcui-lt`). The only shared artifact is Patrol's generated
/// `patrol_test/test_bundle.dart`, which the Android `patrol build android`
/// regenerates and the iOS `xcodebuild` reads. To keep the concurrency race-free
/// the iOS arm is split: its `flutter build ios --config-only` (which does NOT
/// read the bundle) runs alongside the Android build, and its `xcodebuild
/// build-for-testing` (which DOES read the bundle) runs only after the Android
/// arm has finished generating it.
class ItBuildCommand extends BaseCommand {
  ItBuildCommand() {
    argParser
      ..addFlag('all', negatable: false, help: 'Build every local platform (Android + iOS). This is the default.')
      ..addOption(
        'tenant',
        valueHelp: 'tenant[,tenant2]',
        help: 'The tenant to prepare before building (default: tenant in mplatrol.yaml, else "default").',
      );
  }

  MplatrolConfig get config => getDep<MplatrolConfig>();

  @override
  String get name => 'build';

  @override
  String get description =>
      'Prepare once, then build both local platforms (Android + iOS) concurrently — for fast local iteration '
      '(no LambdaTest).';

  @override
  void validateInput() {}

  @override
  Future<int> runCommand() async {
    final target = config.it.target;
    final tenants = (argResults['tenant'] as String? ?? '')
        .split(',')
        .map((tenant) => tenant.trim())
        .where((tenant) => tenant.isNotEmpty)
        .toList();
    var firstFailure = ExitCode.success.code;
    for (final tenant in tenants.isEmpty ? [config.it.tenant] : tenants) {
      logger.info('Building both local platforms (tenant: $tenant)');
      final code = await _buildForTenant(tenant: tenant, target: target);
      if (code != ExitCode.success.code && firstFailure == ExitCode.success.code) {
        firstFailure = code;
      }
    }
    return firstFailure;
  }

  Future<int> _buildForTenant({required String tenant, required String target}) async {
    final repo = fileSystem.getAppDirectory().path;
    final prepCode = await getDep<PrepareHook>().run(
      repo: repo,
      tenant: tenant,
      environment: config.it.environment,
      platforms: const {'android', 'ios'},
    );
    if (prepCode != ExitCode.success.code) {
      logger.err('Prepare failed for "$tenant" (exit $prepCode); not building.');
      return prepCode;
    }
    return _buildBothPlatforms(repo: repo, target: target);
  }

  Future<int> _buildBothPlatforms({
    required String repo,
    required String target,
  }) async {
    final iosRunner = getDep<LtIosRunner>();

    // Phase 1 (concurrent): the Android compile (which also generates the shared
    // test_bundle.dart) and the bundle-independent iOS config-only step. These
    // touch disjoint outputs and the iOS step never reads the bundle, so they
    // are safe to overlap.
    final phaseOne = await Future.wait([
      getDep<LtAndroidRunner>().buildAndroid(repo: repo, target: target),
      iosRunner.buildIosConfigOnly(target: target),
    ]);
    final androidCode = phaseOne[0] as int;
    final bundleId = phaseOne[1] as String?;

    // Phase 2: the iOS xcodebuild reads the now-stable bundle, so it runs only
    // after the Android arm finished generating it. Skipped (a failure) when the
    // iOS config step already failed (null bundle id — nothing to build).
    final iosCode = bundleId == null ? ExitCode.software.code : await iosRunner.buildIosForTesting(bundleId: bundleId);

    _report('Android', androidCode);
    _report('iOS', iosCode);

    if (androidCode == ExitCode.success.code && iosCode == ExitCode.success.code) {
      logger.success('Built both platforms.');
      return ExitCode.success.code;
    }
    logger.err('At least one platform build failed (see above).');
    return ExitCode.software.code;
  }

  void _report(String platform, int code) {
    if (code == ExitCode.success.code) {
      logger.success('$platform build succeeded.');
    } else {
      logger.err('$platform build failed (exit $code).');
    }
  }
}
