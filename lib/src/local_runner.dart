import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/android_device_egress.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/android_permission_dialog.dart';
import 'package:mplatrol/src/android_screen_recorder.dart';
import 'package:mplatrol/src/android_sdk_build_identity.dart';
import 'package:mplatrol/src/android_test_diagnostics.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/ios_device_egress.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/ios_simulator_ui_tests_link.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_biometrics.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/local_leg_artifacts.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/pub_cache.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:mplatrol/src/transient_build_failure.dart';
import 'package:mplatrol/src/upgrade/upgrade_leg.dart';
import 'package:path/path.dart' as p;

/// Runs the unified login E2E on a local emulator/simulator via `patrol test`.
///
/// Runs the local variants: reads the app id the prepare step left and drives `patrol test` against the
/// given device. Only the local variants are handled; the LambdaTest variants
/// are owned by the LambdaTest runners. `mplatrol run` resolves the device (via
/// DevicePicker) before calling, so `deviceId` is required here.
/// Env var: a shell command that installs a provisioning profile for `$MPLATROL_BUNDLE_ID`, run before a physical
/// iPhone build when none is installed (for example a script that downloads it from your signing store).
const iosSigningCommandEnv = 'MPLATROL_IOS_SIGNING_COMMAND';

/// Env var: text (a team name or id) that picks the signing identity among several installed ones.
const iosSigningTeamEnv = 'MPLATROL_IOS_SIGNING_TEAM';

class LocalRunner {
  static final _xcodeBuildConfigurationPattern = RegExp(
    r'\n\t\t[0-9A-F]{24} /\* [^*]+ \*/ = \{\n'
    r'\t\t\tisa = XCBuildConfiguration;[\s\S]*?\n\t\t\};',
  );
  static final _provisioningProfileSpecifierPattern = RegExp('PROVISIONING_PROFILE_SPECIFIER = ([^;]*);');
  static const _patrolCliVersion = '4.8.0';
  static const _patrolCliPatchMarker = 'mplatrol-patch: prefer complete xctestrun';
  static final _patchedPatrolCliVersionPattern = RegExp(
    '^version:\\s*${RegExp.escape(_patrolCliVersion)}(?:\\s|\$)',
    multiLine: true,
  );
  static const _androidFrameworkAttempts = 30;
  static const _androidColdStartFrameworkAttempts = 120;
  static const _androidFrameworkPollDelay = Duration(seconds: 2);
  static const _androidAdbCommandTimeout = Duration(seconds: 5);
  static const _androidServiceListTimeout = Duration(seconds: 15);
  static const _androidEmulatorCommandTimeout = Duration(seconds: 10);
  static const _androidAdbWaitForDeviceTimeout = Duration(seconds: 90);
  static const _androidColdStartWaitForDeviceTimeout = Duration(minutes: 4);
  static const _androidEmulatorShutdownAttempts = 30;
  static const _androidEmulatorShutdownPollDelay = Duration(seconds: 2);
  static const _androidEmulatorRestartSettleDelay = Duration(seconds: 3);
  static const _androidReconnectAttempts = 12;
  static const _androidReconnectPollDelay = Duration(seconds: 5);
  static const _localPatrolBuildAllowance = Duration(minutes: 10);
  static const _localPatrolPerTestAllowance = Duration(minutes: 3);
  static const _iosSimctlCommandTimeout = Duration(seconds: 30);
  static const _iosOnlyActiveArch = 'ONLY_ACTIVE_ARCH=YES';
  static const _patrolIosPorts = [8081, 8082];
  static const _iosSimctlBootTimeout = Duration(seconds: 90);
  static const _buildRetryAttempts = 2;
  static const _buildRetryDelay = Duration(seconds: 5);
  static const _androidTestLogMarker = 'MPLATROL_TEST_START';
  static const _iosBuildSuccessMarker = 'MPLATROL_IOS_BUILD_SUCCEEDED';

  static const _androidBuildSuccessMarker = 'MPLATROL_ANDROID_BUILD_SUCCEEDED';
  static final _patrolCliPreparations = <String, Future<String?>>{};

  bool? _androidBuildSucceeded;

  /// The device evidence of the current Android run that its output lacks: the screen recorders'
  /// [localDeviceContentionMarker] warnings and the permission watcher's unanswered dialogs.
  final _deviceEvidence = <String>[];

  /// Whether the final fresh Android attempt compiled both APKs successfully.
  /// Null means no fresh build was attempted, including reuse-only runs.
  bool? get androidBuildSucceeded => _androidBuildSucceeded;

  bool? _iosBuildSucceeded;

  /// Whether the final fresh iOS build attempt succeeded in the latest run.
  /// Null means no fresh iOS build was attempted, including reuse-only runs.
  bool? get iosBuildSucceeded => _iosBuildSucceeded;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  FileSystem get _fileSystem => getDep<FileSystem>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// Runs the login E2E for [variant] on [deviceId], returning the `patrol test`
  /// exit code. [target] runs a single test file; null runs the whole
  /// Patrol suite (every test in one build, each its own process).
  /// [onBuildStarted] observes each fresh build attempt after local preparation.
  /// A physical phone's test traffic goes through this Mac for the run (see
  /// [AndroidDeviceEgress] and [IosDeviceEgress]) so it reaches
  /// network-restricted environments; emulators and simulators already do.
  Future<int> run({
    required ItVariant variant,
    required String deviceId,
    required String? target,
    String? targetRegex,
    String? sdk,
    Map<String, String>? env,
    bool reuseLast = false,
    void Function()? onBuildStarted,
    bool coverage = false,
    bool develop = false,
  }) {
    final selected = develop
        ? const <PatrolTestFile>[]
        : _recordLocalSelection(target: target, targetRegex: targetRegex, sdk: sdk, env: env);
    Future<int> runWith(Map<String, String> egressEnv) => _runOnDevice(
          variant: variant,
          deviceId: deviceId,
          target: target,
          targetRegex: targetRegex,
          sdk: sdk,
          env: egressEnv.isEmpty ? env : {...env ?? _platform.environment, ...egressEnv},
          reuseLast: reuseLast,
          onBuildStarted: onBuildStarted,
          coverage: coverage,
          develop: develop,
          selected: selected,
        );
    if (variant == ItVariant.androidLocal && !_isEmulator(deviceId)) {
      return getDep<AndroidDeviceEgress>().around(deviceId, runWith);
    }
    if (variant == ItVariant.iosLocal && !_isCoreSimulatorDeviceId(deviceId)) {
      return getDep<IosDeviceEgress>().around(deviceId, runWith);
    }
    return runWith(const {});
  }

  /// Registers the Patrol tests this local run selected for the CI report.
  /// A selection that cannot be discovered is left to the run, which reports
  /// the same problem itself.
  List<PatrolTestFile> _recordLocalSelection(
      {String? target, String? targetRegex, String? sdk, Map<String, String>? env}) {
    try {
      final files = discoverPatrolTestFiles(_fileSystem.getAppDirectory().path,
          target: target, targetRegex: targetRegex, sdk: sdk, environment: env ?? _platform.environment);
      getDep<ItRunResults>().selectTests(patrolSelectedTests(files));
      return files;
      // Discovery reports a missing test directory as StateError; the run reports it too.
      // ignore: avoid_catching_errors
    } on StateError {
      return const [];
    }
  }

  /// Records the per-test verdicts Patrol printed in [result] for the CI report, and logs each failed
  /// test's failure message and stack, which the quiet build hid while it ran.
  void _recordLocalResults(ProcessResultX result, List<PatrolTestFile> selected) {
    final output = '${result.outText}\n${result.errText}';
    final results = getDep<ItRunResults>();
    final skipReasons = iosSkipReasons(output, selected);
    for (final test in parsePatrolConsoleResults(output, selected)) {
      final single = selected.fold(0, (sum, file) => sum + file.tests.length) == 1;
      final passed = test.outcome == ItTestOutcome.pass && single ? passedRunOutcome(output) : null;
      final skip = test.reason == itRuntimeSkipReason ? skipReasons[test.id] : null;
      final reason = skip == null ? test.reason : '$itRuntimeSkipReason ($skip)';
      results.verdict(passed?.outcome ?? test.outcome,
          testId: test.id, reason: passed?.reason ?? reason, evidence: reason, details: test.details);
      if (test.outcome == ItTestOutcome.fail) {
        _logger.info('[test-failure] ${test.id}');
        for (final line in (test.details ?? test.reason ?? '').split('\n')) {
          _logger.info('  $line');
        }
      }
    }
  }

  Future<int> _runOnDevice({
    required ItVariant variant,
    required String deviceId,
    required String? target,
    String? targetRegex,
    String? sdk,
    Map<String, String>? env,
    bool reuseLast = false,
    void Function()? onBuildStarted,
    // Off by default: with `--coverage`, patrol's binding tearDown awaits an
    // `ext.patrol.markTestCompleted` coverage handshake (PatrolBinding), and a
    // test that pumps a standalone widget with no app boot (the auth-error
    // a11y test) may never complete it on the Android emulator, hanging to the
    // gradle timeout. `mplatrol run --coverage` turns it on knowingly.
    bool coverage = false,
    // Runs `patrol develop` attached to this terminal instead of a one-shot
    // `patrol test`: after the first build, editing the test and pressing R
    // hot-restarts it in seconds, with no rebuild.
    bool develop = false,
    List<PatrolTestFile> selected = const [],
  }) async {
    final isAndroid = variant == ItVariant.androidLocal;
    if (isAndroid) {
      _androidBuildSucceeded = null;
      _deviceEvidence.clear();
    }
    if (!isAndroid) {
      _iosBuildSucceeded = null;
    }
    final repo = _fileSystem.getAppDirectory().path;
    final String? appId;
    try {
      appId = isAndroid ? preparedAndroidApplicationId(repo, fileSystem: _fileSystem) : await _readIosBundleId(repo);
      // Refuse an unresolved namespace rather than falling back to Patrol's pubspec.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _logger.err(error.message.toString());
      return ExitCode.config.code;
    }
    final isIosSimulator = !isAndroid && _isCoreSimulatorDeviceId(deviceId);
    // Local devices do not need the app's Developer Tools proxy toggle:
    // Android reaches the runtime credential server through adb reverse, and
    // physical iOS receives the Mac's LAN host in E2E_CREDENTIALS_URL. The
    // Developer Tools proxy path is for LambdaTest tunnel routing and is owned
    // by the LT runners via LT_PROXY.
    if (reuseLast && !isAndroid) {
      return _runLastIosBuild(
        repo: repo,
        deviceId: deviceId,
        appId: appId,
        localIosSimulator: isIosSimulator,
        env: env ?? _platform.environment,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
      );
    }
    if (reuseLast && isAndroid) {
      return _runLastAndroidBuild(
        repo: repo,
        deviceId: deviceId,
        appId: appId,
        env: env ?? _platform.environment,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
      );
    }
    if (isAndroid && !await _ensureAndroidDeviceReady(deviceId)) {
      return ExitCode.unavailable.code;
    }
    final upgradeLeg = UpgradeLeg.fromEnv(env ?? _platform.environment);
    if (upgradeLeg == UpgradeLeg.setup && appId != null) {
      await _uninstallBeforeUpgradeSetup(isAndroid: isAndroid, deviceId: deviceId, appId: appId);
    }
    // Regenerate the Patrol runner so its test methods match + name + group the
    // current Patrol tests before `patrol test` builds.
    final methodCount = isAndroid
        ? generateAndroidPatrolRunner(repo,
            target: target, targetRegex: targetRegex, sdk: sdk, env: env ?? _platform.environment)
        : generateIosPatrolRunner(repo,
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            bundleId: appId ?? '',
            disableCodeSigning: isIosSimulator,
            env: env ?? _platform.environment);
    final platformName = isAndroid ? 'Android' : 'iOS';
    _logger.info('Generated $methodCount $platformName Patrol test method(s)');
    final bundleTargets = _patrolBundleTargets(
      repo,
      isAndroid: isAndroid,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env ?? _platform.environment,
    );
    final patchedPatrolCliMain = await _preparePatchedPatrolCli(repo);
    if (patchedPatrolCliMain == null) {
      return ExitCode.software.code;
    }
    final fvmExecutable = isAndroid ? null : _fvmExecutable();
    if (!isAndroid && fvmExecutable == null) {
      // fvm presence is already validated inside _preparePatchedPatrolCli
      // above, so this second guard is unreachable.
      return ExitCode.config.code; // coverage:ignore-line
    }

    _logger.info('Running the ${variant.label} login E2E on $deviceId');
    if (isIosSimulator) {
      await _prepareIosSimulator(deviceId);
    }

    // No target → run the whole Patrol suite (patrol bundles every
    // *_test.dart; the orchestrator runs each as its own process).
    final runnerEnv = await _runtimeEnvForLocalDevice(
      variant: variant,
      deviceId: deviceId,
      env: env ?? _platform.environment,
      localIosSimulator: isIosSimulator,
    );
    writeE2eRuntimeAssetConfig(repo, runnerEnv);
    final e2eDefineArgs = e2eDartDefineArgs(repo, runnerEnv);
    final localDefines = [
      'E2E_TEST_BRIDGE=true',
      if (!isAndroid) 'PATROL_HOST=127.0.0.1',
      // iOS reads DART_DEFINES from the xcconfig written below, which overrides patrol's own
      // `COVERAGE_ENABLED`; without it the binding never posts `waitForCoverageCollection`.
      if (coverage) 'COVERAGE_ENABLED=true',
      ..._idDefines(
        isAndroid: isAndroid,
        appId: appId,
        localIosSimulator: isIosSimulator,
      ),
      ..._rawDartDefines(e2eDefineArgs),
    ];
    if (!isAndroid) {
      writeIosDartDefines(repo, localDefines);
      await _prepareLocalIosSdkBuild(repo, simulator: isIosSimulator);
      if (!isIosSimulator &&
          !await _ensurePhysicalIosSigningProfiles(
            repo: repo,
            appId: appId,
            env: runnerEnv,
          )) {
        return ExitCode.config.code;
      }
    }
    // Run Patrol through Dart's globally-activated FVM entrypoint (not bare
    // `patrol`) so the pinned Flutter SDK runs the test. Avoid resolving a
    // stale Homebrew FVM before the Dart-global FVM installed by mplatrol setup.
    final patrolTestArgs = [
      if (develop) 'develop' else 'test',
      if (!isAndroid && !isIosSimulator) '--release',
      if (!isAndroid && !isIosSimulator) '--no-tree-shake-icons',
      if (coverage) ...[
        '--coverage',
        '--coverage-package=${e2eCoveragePackagePattern(repo, configured: getDep<MplatrolConfig>().coveragePackages)}',
        for (final glob in e2eCoverageIgnoreGlobs) '--coverage-ignore=$glob',
      ],
      // An upgrade leg leaves the app installed: the verify leg installs the current build over it.
      if (isAndroid || upgradeLeg != null) '--no-uninstall',
      '--no-label',
      for (final bundleTarget in bundleTargets) ...['--target', bundleTarget],
      '-d',
      deviceId,
      ..._idArgs(
        isAndroid: isAndroid,
        appId: appId,
        localIosSimulator: isIosSimulator,
      ),
      '--dart-define=E2E_TEST_BRIDGE=true',
      if (!isAndroid) '--dart-define=PATROL_HOST=127.0.0.1',
      ...e2eDefineArgs,
    ];
    final orderAssignments = _testOrderAssignments(repo,
        isAndroid: isAndroid, target: target, targetRegex: targetRegex, sdk: sdk, env: env ?? _platform.environment);
    final executable = isAndroid && orderAssignments.isEmpty ? 'dart' : 'env';
    final arguments = isAndroid
        ? [
            if (orderAssignments.isNotEmpty) ...[...orderAssignments, 'dart'],
            'pub',
            'global',
            'run',
            'fvm:main',
            'exec',
            'dart',
            patchedPatrolCliMain,
            ...patrolTestArgs
          ]
        : [
            _iosOnlyActiveArch,
            ...orderAssignments,
            fvmExecutable!.path,
            'dart',
            '-D$patrolTestBundleDefine=$iosPatrolTestBundleFile',
            patchedPatrolCliMain,
            ...patrolTestArgs,
          ];

    if (develop) {
      _logger.info('[develop] edit the test, then press R in this terminal to '
          'hot-restart it (no rebuild); press Q to quit.');
      return _shell.runInteractive(executable, arguments, workingDirectory: repo);
    }
    if (isAndroid) {
      removeIfExists(_androidTestResultsDir(repo));
    }
    final patrolTimeout = _localPatrolTestTimeout(methodCount);
    var androidAttemptStartedAt = DateTime.now();
    void beforeBuild() {
      if (isAndroid) {
        _androidBuildSucceeded = false;
      }
      onBuildStarted?.call();
      androidAttemptStartedAt = DateTime.now();
    }

    final iosRunStartedAt = DateTime.now();
    final previousIosResultBundles = isAndroid ? <String>{} : _iosResultBundlePaths(repo);
    if (isAndroid && !await _ensureAndroidDeviceOnline(deviceId, repo)) {
      return ExitCode.unavailable.code;
    }
    var result = isAndroid
        ? await _runAndroidPatrolTestWithPermissionWatcher(
            deviceId: deviceId,
            record: _recordsAndroidVideo(env ?? _platform.environment),
            repo: repo,
            run: () => _runPatrolTestWithBuildRetry(
              executable: executable,
              arguments: arguments,
              repo: repo,
              timeout: patrolTimeout,
              onBuildStarted: beforeBuild,
            ),
          )
        : await _runIosPatrolTestWithSimulatorObserver(
            deviceId: deviceId,
            localIosSimulator: isIosSimulator,
            repo: repo,
            run: () => _runPatrolTestWithBuildRetry(
              executable: executable,
              arguments: arguments,
              repo: repo,
              timeout: patrolTimeout,
              quietBuild: false,
              onBuildStarted: beforeBuild,
            ),
          );
    if (isAndroid && _patrolTimedOut(result)) {
      await _logAndroidFailureDiagnostics(repo, androidAttemptStartedAt);
      _keepLegEvidence(repo, variant, result, since: androidAttemptStartedAt);
      return result.exitCode;
    }
    if (isAndroid &&
        result.exitCode != ExitCode.success.code &&
        await _diagnoseAndroidVersionDowngrade(deviceId, repo, appId, result, androidAttemptStartedAt)) {
      await _logAndroidFailureDiagnostics(repo, androidAttemptStartedAt);
      _keepLegEvidence(repo, variant, result, since: androidAttemptStartedAt);
      return result.exitCode;
    }
    if (isAndroid && result.exitCode != ExitCode.success.code && await _recoverAndroidInstallFailure(deviceId, repo)) {
      if (!await _ensureAndroidDeviceOnline(deviceId, repo)) {
        return ExitCode.unavailable.code;
      }
      result = await _runPatrolTest(
        executable: executable,
        arguments: arguments,
        repo: repo,
        timeout: patrolTimeout,
        onBuildStarted: beforeBuild,
      );
    }
    if (isAndroid &&
        !_patrolTimedOut(result) &&
        result.exitCode != ExitCode.success.code &&
        await _recoverMissingAndroidTargetApp(deviceId, repo, result)) {
      result = await _runAndroidPatrolTestWithPermissionWatcher(
        deviceId: deviceId,
        record: _recordsAndroidVideo(env ?? _platform.environment),
        repo: repo,
        run: () => _runPatrolTestWithBuildRetry(
          executable: executable,
          arguments: arguments,
          repo: repo,
          timeout: patrolTimeout,
          onBuildStarted: beforeBuild,
        ),
      );
    }
    if (!isAndroid && isIosSimulator && _shouldRetryIosSimulator(result, repo, previousIosResultBundles)) {
      _logger.warn(
        '[ios-sim] Local iOS Patrol exited with code '
        '${result.exitCode}; restarting $deviceId and retrying local iOS '
        'once.',
      );
      await _restartIosSimulator(deviceId);
      result = await _runIosPatrolTestWithSimulatorObserver(
        deviceId: deviceId,
        localIosSimulator: isIosSimulator,
        repo: repo,
        run: () => _runPatrolTest(
          executable: executable,
          arguments: arguments,
          repo: repo,
          timeout: patrolTimeout,
          onBuildStarted: beforeBuild,
        ),
      );
    }
    if (!isAndroid) {
      _iosBuildSucceeded = '${result.outText}\n${result.errText}'.contains(_iosBuildSuccessMarker);
      result = await _appendLatestIosActionLog(
        result: result,
        repo: repo,
        startedAt: iosRunStartedAt,
        previousResultBundles: previousIosResultBundles,
      );
    } else if (result.exitCode != ExitCode.success.code) {
      await _logAndroidFailureDiagnostics(repo, androidAttemptStartedAt);
    }
    final evidence = _keepLegEvidence(repo, variant, result,
        since: isAndroid ? androidAttemptStartedAt : iosRunStartedAt, previousIosBundles: previousIosResultBundles);
    if (result.exitCode != ExitCode.success.code) {
      final output = '${result.outText}\n${result.errText}${evidence.map((line) => '\n$line').join()}';
      reportTestLessons(output, repo: repo, logger: _logger);
    }
    _recordLocalResults(result, selected);
    return _exitCodeWithSkipPolicy(result);
  }

  /// Keeps the full output of [result] and the run's test results in the leg's own directory
  /// ([LocalLegArtifacts]) and returns the evidence lessons read beyond the output: the Android
  /// instrumentation issues (e.g. `INSTRUMENTATION_ABORTED: System has crashed`) and the device
  /// contention warnings of this run.
  List<String> _keepLegEvidence(String repo, ItVariant variant, ProcessResultX result,
      {required DateTime since, Set<String> previousIosBundles = const {}}) {
    final artifacts = getDep<LocalLegArtifacts>()
      ..keepBuildLog(repo, variant: variant.id, output: '${result.outText}\n${result.errText}');
    if (variant != ItVariant.androidLocal) {
      artifacts.keepIosResults(repo, _iosResultBundlePaths(repo).difference(previousIosBundles));
      return const [];
    }
    return [
      ...artifacts.keepAndroidResults(repo, results: _androidTestResultsDir(repo), since: since),
      ..._deviceEvidence,
    ];
  }

  /// `KEY=value` environment assignments that carry the run's shuffled test
  /// order ([ItTestOrder]) to the native runner: none for a declared order.
  ///
  /// iOS gets `TEST_RUNNER_$testOrderEnv`, which xcodebuild hands to the
  /// generated runner's `fullTestSuite()` as [testOrderEnv], so every test
  /// runs in the seeded order. Android's `build.gradle` turns [testOrderEnv]
  /// into the [androidTestOrderArgument] instrumentation argument that orders
  /// the tests within each generated class; the runner keeps classes (test
  /// files) in its own order. [e2eKeepAppDataEnv] runs keep name order.
  List<String> _testOrderAssignments(String repo,
      {required bool isAndroid,
      required String? target,
      required String? targetRegex,
      required String? sdk,
      required Map<String, String> env}) {
    final order = getDep<ItTestOrder>().order;
    if (order.declared) {
      return const [];
    }
    if (isAndroid && resolveAndroidKeepAppData(env)) {
      _logger.info('[order] $e2eKeepAppDataEnv keeps Android tests in name order; the seed is not applied.');
      return const [];
    }
    final tests = isAndroid
        ? [
            for (final file
                in discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex, sdk: sdk, environment: env))
              for (final test in file.tests) '${androidPatrolTestClassName(file.basename)}.${test.method}',
          ]
        : [
            for (final shard in iosTestShards(repo, target: target, targetRegex: targetRegex, sdk: sdk, env: env))
              shard.method,
          ];
    final ordered = order.apply(tests);
    final orderLabel = isAndroid ? 'Android order within each test file' : 'iOS run order';
    _logger
      ..info(summariseTestOrder(orderLabel, ordered))
      ..detail('[order] $orderLabel: ${ordered.join(', ')}');
    return ['${isAndroid ? '' : 'TEST_RUNNER_'}$testOrderEnv=${ordered.join(',')}'];
  }

  /// The `--target`s `patrol test` bundles for this run.
  ///
  /// Android owns Patrol's shared `test_bundle.dart` and, for filtered runs,
  /// mplatrol's `mplatrol_filtered_test.dart` wrapper. `mplatrol run all` builds
  /// local iOS concurrently with Android, so local iOS never writes, deletes,
  /// or compiles those: it bundles exactly its selected files into its own
  /// [iosPatrolTestBundleFile] (named via [patrolTestBundleDefine]).
  List<String> _patrolBundleTargets(
    String repo, {
    required bool isAndroid,
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required Map<String, String> env,
  }) {
    if (!isAndroid) {
      return iosPatrolBundleTargets(
        repo,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        environment: env,
      );
    }
    if (targetRegex == null && sdk == null) {
      removeFilteredPatrolTestTarget(repo);
      return [if (target != null) target];
    }
    final filteredTarget = retargetPatrolTestBundle(
      repo,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
    );
    _logger.info('[bundle] local filtered run target -> $filteredTarget');
    return [filteredTarget];
  }

  bool _shouldRetryIosSimulator(
    ProcessResultX result,
    String repo,
    Set<String> previousResultBundles,
  ) {
    if (result.exitCode == ExitCode.success.code || _patrolTimedOut(result)) {
      return false;
    }
    if (_iosResultBundlePaths(repo).difference(previousResultBundles).isNotEmpty) {
      return false;
    }
    final output = '${result.outText}\n${result.errText}';
    if (patrolReportedTestFailures(output) ||
        output.contains('MPLATROL_TEST_START') ||
        output.contains('Test Case ') ||
        RegExp(r'Total:\s*[1-9]\d*').hasMatch(output)) {
      return false;
    }
    return output.contains('Simulator disconnected');
  }

  /// Time allowed for one local Patrol attempt: the platform build plus every
  /// selected test, so a growing suite never hits a fixed ceiling.
  static Duration _localPatrolTestTimeout(int testCount) =>
      _localPatrolBuildAllowance + _localPatrolPerTestAllowance * (testCount < 1 ? 1 : testCount);

  Future<void> _logAndroidFailureDiagnostics(String repo, DateTime startedAt) async {
    final lines = await AndroidTestDiagnostics().summarizeCurrentFailure(
      repo: repo,
      runStartedAt: startedAt,
    );
    lines.forEach(_logger.err);
  }

  Future<int> _runLastAndroidBuild({
    required String repo,
    required String deviceId,
    required String? appId,
    required Map<String, String> env,
    required String? target,
    required String? targetRegex,
    required String? sdk,
  }) async {
    // Unreachable: the Android appId comes from preparedAndroidApplicationId,
    // which returns a non-null id or throws before this method is called.
    // coverage:ignore-start
    if (appId == null) {
      _logger.err('[reuse-last] Android applicationId is missing from build.gradle.');
      return ExitCode.config.code;
    }
    // coverage:ignore-end
    if (!await _ensureAndroidDeviceReady(deviceId)) {
      return ExitCode.unavailable.code;
    }
    final runnerEnv = await _runtimeEnvForLocalDevice(
      variant: ItVariant.androidLocal,
      deviceId: deviceId,
      env: env,
      localIosSimulator: false,
    );
    writeE2eRuntimeAssetConfig(repo, runnerEnv);
    final files = discoverPatrolTestFiles(
      repo,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      environment: runnerEnv,
    );
    const testPackage = '$androidPatrolTestPackage.';
    final tests = [
      for (final file in files)
        for (final test in file.tests) '$testPackage${androidPatrolTestClassName(file.basename)}#${test.method}',
    ];
    final dartNames = [
      for (final file in files)
        for (final test in file.tests) patrolDartTestName(file, test),
    ];
    final results = getDep<ItRunResults>();
    if (tests.isEmpty) {
      _logger.err('[reuse-last] no selected Android Patrol tests were found.');
      return ExitCode.usage.code;
    }
    if (!await _installCachedAndroidApks(repo, deviceId)) {
      return ExitCode.software.code;
    }
    _logger.info('[reuse-last] running ${tests.length} cached Android test(s) '
        'on $deviceId without Gradle');
    var passed = 0;
    final runOrder = getDep<ItTestOrder>().order.apply([for (var index = 0; index < tests.length; index++) index]);
    for (final index in runOrder) {
      final test = tests[index];
      if (!await _resetAndroidTestLog(repo, deviceId)) {
        return ExitCode.software.code;
      }
      final clear = await _runPatrolTest(
        executable: 'adb',
        arguments: ['-s', deviceId, 'shell', 'pm', 'clear', appId],
        repo: repo,
      );
      if (clear.exitCode != 0 || !clear.outText.contains('Success')) {
        _logger.err('[reuse-last] could not clear $appId before $test: '
            '${clear.errText.isEmpty ? clear.outText : clear.errText}');
        return ExitCode.software.code;
      }
      final attemptStartedAt = DateTime.now();
      final result = await _runAndroidPatrolTestWithPermissionWatcher(
        deviceId: deviceId,
        record: _recordsAndroidVideo(env),
        repo: repo,
        run: () => _runPatrolTest(
          executable: 'adb',
          arguments: [
            '-s',
            deviceId,
            'shell',
            'am',
            'instrument',
            '-w',
            '-r',
            '-e',
            'class',
            test,
            '$appId.test/pl.leancode.patrol.PatrolJUnitRunner',
          ],
          repo: repo,
          timeout: const Duration(minutes: 10),
        ),
      );
      if (!await _androidTestLogHasNoSkips(repo, deviceId, test)) {
        results.verdict(ItTestOutcome.notRun, testId: dartNames[index], reason: itRuntimeSkipReason);
        continue;
      }
      if (_cachedAndroidTestPassed(result)) {
        passed++;
        results.verdict(ItTestOutcome.pass, testId: dartNames[index]);
      } else {
        await _logAndroidFailureDiagnostics(repo, attemptStartedAt);
        final signals = result.outText.split('\n').map((line) => line.trim()).where(
              (line) =>
                  line.startsWith('INSTRUMENTATION_STATUS_CODE:') ||
                  line.startsWith('INSTRUMENTATION_CODE:') ||
                  line.contains('shortMsg='),
            );
        _logger.err('[reuse-last] $test failed (adb exit ${result.exitCode}): '
            '${signals.join('; ')} ${result.errText.trim()}');
        results.verdict(ItTestOutcome.fail,
            testId: dartNames[index], reason: signals.join('; '), evidence: result.outText);
      }
    }
    _logger.info('[reuse-last] Android instrumentation: '
        '$passed/${tests.length} test(s) passed');
    return passed == tests.length ? ExitCode.success.code : ExitCode.software.code;
  }

  Future<bool> _resetAndroidTestLog(String repo, String deviceId) async {
    final clear = await _runPatrolTest(
      executable: 'adb',
      arguments: ['-s', deviceId, 'logcat', '-c'],
      repo: repo,
      timeout: const Duration(seconds: 10),
    );
    if (clear.exitCode != 0) {
      _logger.err('[reuse-last] could not clear Android logcat: ${clear.errText}');
      return false;
    }
    final marker = await _runPatrolTest(
      executable: 'adb',
      arguments: [
        '-s',
        deviceId,
        'shell',
        'log',
        '-p',
        'i',
        '-t',
        'mplatrol',
        _androidTestLogMarker,
      ],
      repo: repo,
      timeout: const Duration(seconds: 10),
    );
    if (marker.exitCode != 0) {
      _logger.err('[reuse-last] could not mark Android logcat: ${marker.errText}');
      return false;
    }
    return true;
  }

  Future<bool> _androidTestLogHasNoSkips(
    String repo,
    String deviceId,
    String test,
  ) async {
    final logs = await _runPatrolTest(
      executable: 'adb',
      arguments: ['-s', deviceId, 'logcat', '-d', '-s', 'flutter:I', 'mplatrol:I'],
      repo: repo,
      timeout: const Duration(seconds: 10),
    );
    if (logs.exitCode != 0 || !logs.outText.contains(_androidTestLogMarker)) {
      _logger.err('[reuse-last] could not verify Android test log for $test');
      return false;
    }
    final skipped = patrolSkipSummary(logs.outText);
    if (skipped.hasSkippedTests) {
      _logger.err('[reuse-last] $test reported ${skipped.countLabel} skipped '
          'test(s); a skip is not a pass.');
      return false;
    }
    return true;
  }

  Future<bool> _installCachedAndroidApks(String repo, String deviceId) async {
    final apks = [
      p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'),
      p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
    ];
    for (final apk in apks) {
      if (!File(apk).existsSync()) {
        _logger.err('[reuse-last] cached APK missing: $apk. Rebuild the Android variant.');
        return false;
      }
      final install = await _runPatrolTest(
        executable: 'adb',
        arguments: ['-s', deviceId, 'install', '-r', '-t', '-d', apk],
        repo: repo,
        timeout: const Duration(minutes: 2),
      );
      if (install.exitCode != 0 || !install.outText.contains('Success')) {
        _logger.err('[reuse-last] failed to install $apk: '
            '${install.errText.isEmpty ? install.outText : install.errText}');
        return false;
      }
    }
    return true;
  }

  bool _cachedAndroidTestPassed(ProcessResultX result) {
    if (result.exitCode != 0 || _exitCodeWithSkipPolicy(result) != 0) {
      return false;
    }
    final statuses = RegExp(r'^INSTRUMENTATION_STATUS_CODE:\s*(-?\d+)\s*$', multiLine: true)
        .allMatches(result.outText)
        .map((match) => int.parse(match.group(1)!))
        .where((code) => code <= 0)
        .toList();
    return statuses.length == 1 && statuses.single == 0 && result.outText.contains('INSTRUMENTATION_CODE: -1');
  }

  int _exitCodeWithSkipPolicy(ProcessResultX result) {
    if (result.exitCode != ExitCode.success.code) {
      return result.exitCode;
    }
    final skipSummary = patrolSkipSummary(
      '${result.outText}\n${result.errText}',
    );
    if (!skipSummary.hasSkippedTests) {
      return ExitCode.success.code;
    }
    _logger.err(
      'Patrol reported ${skipSummary.countLabel} skipped test(s); treating '
      'this run as failed because a skip is not a pass.',
    );
    return ExitCode.software.code;
  }

  Future<int> _runLastIosBuild({
    required String repo,
    required String deviceId,
    required String? appId,
    required bool localIosSimulator,
    required Map<String, String> env,
    required String? target,
    required String? targetRegex,
    required String? sdk,
  }) async {
    if (targetRegex != null || sdk != null) {
      _logger.err(
        '[reuse-last] local iOS filtered reuse is not safe: the cached build '
        'was not built for this filter (targetRegex/sdk). Re-run the iOS '
        'variant without --reuse-last to build the filtered bundle.',
      );
      return ExitCode.usage.code;
    }
    final xctestRun = _latestIosXctestRun(
      repo: repo,
      localIosSimulator: localIosSimulator,
    );
    if (xctestRun == null) {
      _logger.err(
        '[reuse-last] no cached local iOS .xctestrun was found under '
        'build/ios_integ/Build/Products. Run the iOS variant once without '
        '--reuse-last to build it.',
      );
      return ExitCode.usage.code;
    }

    final runnerEnv = await _runtimeEnvForLocalDevice(
      variant: ItVariant.iosLocal,
      deviceId: deviceId,
      env: env,
      localIosSimulator: localIosSimulator,
    );
    writeE2eRuntimeAssetConfig(repo, runnerEnv);
    if (!await _patchBuiltIosRuntimeConfig(
      repo: repo,
      env: runnerEnv,
      localIosSimulator: localIosSimulator,
    )) {
      return ExitCode.software.code;
    }

    if (localIosSimulator) {
      await _prepareIosSimulator(deviceId);
    }
    await _uninstallCachedIosReuseApps(
      deviceId: deviceId,
      localIosSimulator: localIosSimulator,
      appBundleId: appId,
      xctestRun: xctestRun,
    );
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp('[:.]'), '-');
    final resultBundle = p.join(repo, 'build', 'ios_results_reuse_$stamp.xcresult');
    final destination = localIosSimulator ? 'platform=iOS Simulator,id=$deviceId' : 'platform=iOS,id=$deviceId';
    _logger.info('[reuse-last] running cached local iOS build on $deviceId');
    final orderAssignments =
        _testOrderAssignments(repo, isAndroid: false, target: target, targetRegex: targetRegex, sdk: sdk, env: env);
    final result = await _runIosPatrolTestWithSimulatorObserver(
      deviceId: deviceId,
      localIosSimulator: localIosSimulator,
      repo: repo,
      run: () => _shell.runArgs(
        orderAssignments.isEmpty ? 'xcodebuild' : 'env',
        [
          if (orderAssignments.isNotEmpty) ...[...orderAssignments, 'xcodebuild'],
          'test-without-building',
          '-xctestrun',
          xctestRun,
          '-destination',
          destination,
          '-resultBundlePath',
          resultBundle,
        ],
        workingDirectory: repo,
        throwOnError: false,
        surfaceFailureOutput: true,
        timeout: _localPatrolTestTimeout(iosTestShards(repo, target: target).length),
      ),
    );
    _logger.info('[reuse-last] result bundle: $resultBundle');
    final resultWithActionLog = await _appendIosActionLog(
      result: result,
      resultBundle: resultBundle,
    );
    getDep<LocalLegArtifacts>()
      ..keepBuildLog(repo,
          variant: ItVariant.iosLocal.id, output: '${resultWithActionLog.outText}\n${resultWithActionLog.errText}')
      ..keepIosResults(repo, [resultBundle]);
    return _exitCodeWithSkipPolicy(resultWithActionLog);
  }

  Future<ProcessResultX> _appendIosActionLog({
    required ProcessResultX result,
    required String resultBundle,
  }) async {
    final checkedResult = await _verifyIosTestSummary(result, resultBundle);
    final issueSummary = await _iosXcresultIssueSummary(resultBundle);
    if (checkedResult.exitCode != ExitCode.success.code && issueSummary.isNotEmpty) {
      _logger.err(issueSummary);
    }
    final log = await _shell.runArgs(
      'xcrun',
      [
        'xcresulttool',
        'get',
        'log',
        '--path',
        resultBundle,
        '--type',
        'action',
        '--compact',
      ],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 30),
    );
    if ((log.exitCode != ExitCode.success.code || log.outText.trim().isEmpty) && issueSummary.isEmpty) {
      return checkedResult;
    }
    final output = [
      checkedResult.outText,
      if (log.exitCode == ExitCode.success.code && log.outText.trim().isNotEmpty) log.outText,
      if (issueSummary.isNotEmpty) issueSummary,
    ].join('\n');
    return ProcessResultX(
      exitCode: checkedResult.exitCode,
      stdout: output,
      stderr: checkedResult.errText,
      pid: checkedResult.pid,
      processResult: checkedResult.processResult,
    );
  }

  Future<ProcessResultX> _verifyIosTestSummary(
    ProcessResultX result,
    String resultBundle,
  ) async {
    final summary = await _shell.runArgs(
      'xcrun',
      ['xcresulttool', 'get', 'test-results', 'summary', '--path', resultBundle],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 30),
    );
    if (summary.exitCode != ExitCode.success.code) {
      return _iosVerificationFailure(
          result,
          'Could not read the current iOS test summary '
          '(xcresulttool exit ${summary.exitCode}); cannot verify a pass.');
    }
    try {
      final decoded = jsonDecode(summary.outText);
      if (decoded is! Map<String, dynamic>) {
        return _iosVerificationFailure(result, 'The current iOS test summary is not an object; cannot verify a pass.');
      }
      final reason = _iosSummaryFailureReason(decoded);
      if (reason == null) {
        return result;
      }
      final failures = decoded['testFailures'];
      if (failures is List) {
        for (final failure in failures.whereType<Map<String, dynamic>>()) {
          final text = failure['failureText'];
          if (text is String && text.isNotEmpty) {
            _logger.err('[xcresult] ${failure['testName'] ?? 'Test'}: $text');
          }
        }
      }
      return _iosVerificationFailure(result, reason);
    } on FormatException {
      return _iosVerificationFailure(result, 'The current iOS test summary is invalid JSON; cannot verify a pass.');
    }
  }

  String? _iosSummaryFailureReason(Map<String, dynamic> summary) {
    const keys = [
      'totalTestCount',
      'passedTests',
      'failedTests',
      'skippedTests',
      'expectedFailures',
    ];
    for (final key in keys) {
      final count = summary[key];
      if (count is! int || count < 0) {
        return 'The current iOS test summary has invalid $key; '
            'cannot verify a pass.';
      }
    }
    final total = summary['totalTestCount'] as int;
    final passed = summary['passedTests'] as int;
    final failed = summary['failedTests'] as int;
    final skipped = summary['skippedTests'] as int;
    final expected = summary['expectedFailures'] as int;
    final status = summary['result'];
    final counts = 'result=$status, total=$total, passed=$passed, '
        'failed=$failed, skipped=$skipped, expectedFailures=$expected';
    if (skipped > 0) {
      return 'iOS reported $skipped skipped test(s); a skip is not a pass. $counts';
    }
    if (expected > 0 || status == 'Expected Failure') {
      return 'iOS reported an expected failure, not a verified test pass. $counts';
    }
    if (passed == 0 || total == 0) {
      return 'iOS reported zero passed tests; cannot verify a pass. $counts';
    }
    if (failed > 0 || status != 'Passed' || total != passed) {
      return 'iOS did not report a consistent passed test result. $counts';
    }
    return null;
  }

  ProcessResultX _iosVerificationFailure(
    ProcessResultX result,
    String reason,
  ) {
    _logger.err('[xcresult] $reason');
    return ProcessResultX(
      exitCode: result.exitCode == ExitCode.success.code ? ExitCode.software.code : result.exitCode,
      stdout: result.outText,
      stderr: '${result.errText}\n[xcresult] $reason',
      pid: result.pid,
      processResult: result.processResult,
    );
  }

  Future<String> _iosXcresultIssueSummary(String resultBundle) async {
    final issues = await _shell.runArgs(
      'xcrun',
      [
        'xcresulttool',
        'get',
        'object',
        '--legacy',
        '--path',
        resultBundle,
        '--format',
        'json',
      ],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 30),
    );
    if (issues.exitCode != ExitCode.success.code || issues.outText.trim().isEmpty) {
      return '';
    }
    try {
      final messages = <String>{};
      void visit(Object? value) {
        if (value is List) {
          value.forEach(visit);
          return;
        }
        if (value is! Map<String, dynamic>) {
          return;
        }
        final type = _xcresultStringValue(value['_type'], '_name');
        if (type == 'IssueSummary') {
          final message = _xcresultStringValue(value['message'], '_value');
          if (message != null && message.trim().isNotEmpty) {
            final issueType = _xcresultStringValue(value['issueType'], '_value');
            messages.add('[xcresult] ${issueType ?? 'Issue'}: $message');
          }
        }
        value.values.forEach(visit);
      }

      visit(jsonDecode(issues.outText));
      return messages.join('\n');
    } on FormatException {
      return '';
    }
  }

  String? _xcresultStringValue(Object? value, String key) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final raw = value[key];
    return raw is String ? raw : null;
  }

  Future<ProcessResultX> _appendLatestIosActionLog({
    required ProcessResultX result,
    required String repo,
    required DateTime startedAt,
    required Set<String> previousResultBundles,
  }) async {
    final resultBundle = _latestIosResultBundle(
      repo: repo,
      startedAt: startedAt,
      previousResultBundles: previousResultBundles,
    );
    if (resultBundle == null) {
      return result.exitCode == ExitCode.success.code
          ? _iosVerificationFailure(result, 'No current-run iOS result bundle was produced; cannot verify a pass.')
          : result;
    }
    return _appendIosActionLog(result: result, resultBundle: resultBundle);
  }

  String? _latestIosResultBundle({
    required String repo,
    required DateTime startedAt,
    required Set<String> previousResultBundles,
  }) {
    final buildDir = Directory(p.join(repo, 'build'));
    if (!buildDir.existsSync()) {
      return null;
    }
    final bundles = buildDir.listSync(followLinks: false).whereType<Directory>().where((directory) {
      final name = p.basename(directory.path);
      if (previousResultBundles.contains(directory.path)) {
        return false;
      }
      final match = RegExp(r'^ios_results_(\d+)\.xcresult$').firstMatch(name);
      final timestamp = match == null ? null : int.tryParse(match.group(1)!);
      return timestamp != null && timestamp >= startedAt.millisecondsSinceEpoch;
    }).toList();
    if (bundles.isEmpty) {
      return null;
    }
    bundles.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return bundles.first.path;
  }

  Set<String> _iosResultBundlePaths(String repo) {
    final buildDir = Directory(p.join(repo, 'build'));
    if (!buildDir.existsSync()) {
      return {};
    }
    return buildDir
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where((directory) => directory.path.endsWith('.xcresult'))
        .map((directory) => directory.path)
        .toSet();
  }

  String? _latestIosXctestRun({
    required String repo,
    required bool localIosSimulator,
  }) {
    final products = Directory(
      p.join(repo, 'build', 'ios_integ', 'Build', 'Products'),
    );
    if (!products.existsSync()) {
      return null;
    }
    final platform = localIosSimulator ? 'iphonesimulator' : 'iphoneos';
    final files = products
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.xctestrun') && p.basename(file.path).contains(platform))
        .toList();
    if (files.isEmpty) {
      return null;
    }
    files.sort((a, b) => b.statSync().modified.compareTo(
          a.statSync().modified,
        ));
    return files.first.path;
  }

  Future<bool> _patchBuiltIosRuntimeConfig({
    required String repo,
    required Map<String, String> env,
    required bool localIosSimulator,
  }) async {
    final defines = e2eRuntimeDartDefines(repo, env);
    if (defines.isEmpty) {
      _logger.err(
        '[reuse-last] no E2E runtime config values were available for the '
        'cached iOS artifact.',
      );
      return false;
    }
    final files = _builtIosRuntimeConfigFiles(
      repo: repo,
      localIosSimulator: localIosSimulator,
    );
    if (files.isEmpty) {
      _logger.err(
        '[reuse-last] cached iOS artifact does not contain '
        '$runtimeE2eAssetConfigFile. Rebuild without --reuse-last.',
      );
      return false;
    }
    final content = '${const JsonEncoder.withIndent('  ').convert(defines)}\n';
    for (final file in files) {
      file.writeAsStringSync(content);
    }
    _logger.info(
      '[reuse-last] updated E2E runtime config in ${files.length} cached '
      'iOS artifact file(s).',
    );
    if (localIosSimulator) {
      return true;
    }
    return _resignBuiltIosRuntimeConfig(files);
  }

  Future<void> _uninstallCachedIosReuseApps({
    required String deviceId,
    required bool localIosSimulator,
    required String? appBundleId,
    required String xctestRun,
  }) async {
    final bundleIds = <String>{};
    final appId = appBundleId?.trim() ?? '';
    if (appId.isNotEmpty) {
      bundleIds.add(appId);
    }
    final testHost = await _xctestrunStringValue(
      xctestRun,
      'RunnerUITests.TestHostBundleIdentifier',
    );
    if (testHost != null && testHost.trim().isNotEmpty) {
      bundleIds.add(testHost.trim());
    }
    if (bundleIds.isEmpty) {
      return;
    }

    for (final bundleId in bundleIds) {
      final result = localIosSimulator
          ? await _xcrunSimctl(
              ['uninstall', deviceId, bundleId],
              timeout: _iosSimctlCommandTimeout,
            )
          : await _xcrunDevicectlUninstallApp(deviceId, bundleId);
      final label = localIosSimulator ? '[ios-sim]' : '[ios-device]';
      if (result.exitCode == ExitCode.success.code) {
        _logger.info('$label uninstalled cached reuse app $bundleId');
        continue;
      }
      _logger.warn(
        '$label could not uninstall cached reuse app $bundleId '
        '(exit ${result.exitCode}); continuing so xcodebuild can install '
        'the current cached product.',
      );
    }
  }

  Future<String?> _xctestrunStringValue(
    String xctestRun,
    String keyPath,
  ) async {
    final result = await _shell.runArgs(
      'plutil',
      ['-extract', keyPath, 'raw', '-o', '-', xctestRun],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 10),
    );
    if (result.exitCode != ExitCode.success.code) {
      return null;
    }
    final value = result.outText.trim();
    return value.isEmpty ? null : value;
  }

  List<File> _builtIosRuntimeConfigFiles({
    required String repo,
    required bool localIosSimulator,
  }) {
    final products = Directory(
      p.join(repo, 'build', 'ios_integ', 'Build', 'Products'),
    );
    if (!products.existsSync()) {
      return const [];
    }
    final platform = localIosSimulator ? 'iphonesimulator' : 'iphoneos';
    return products
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.contains(platform) && file.path.endsWith(runtimeE2eAssetConfigFile))
        .toList();
  }

  Future<bool> _resignBuiltIosRuntimeConfig(List<File> configFiles) async {
    final appBundles = <String, Directory>{};
    final frameworksByApp = <String, Map<String, Directory>>{};
    for (final file in configFiles) {
      final app = _ancestorWithSuffix(file, '.app');
      if (app != null) {
        appBundles[app.path] = app;
        final framework = _ancestorNamed(file, 'App.framework');
        if (framework != null) {
          frameworksByApp
              .putIfAbsent(app.path, () => <String, Directory>{})
              .putIfAbsent(framework.path, () => framework);
        }
      }
    }
    for (final app in appBundles.values) {
      final identity = await _codesignIdentityForAppBundle(app);
      if (identity == null || identity.trim().isEmpty) {
        _logger.err(
          '[reuse-last] could not find a signing identity compatible with '
          '${app.path}.',
        );
        return false;
      }
      for (final framework in frameworksByApp[app.path]?.values ?? const Iterable<Directory>.empty()) {
        if (!await _codesignPath(framework.path, identity)) {
          return false;
        }
      }
      if (!await _codesignPath(
        app.path,
        identity,
        preserveMetadata: true,
      )) {
        return false;
      }
    }
    _logger.info('[reuse-last] re-signed cached iOS artifact runtime config');
    return true;
  }

  Future<String?> _codesignIdentityForAppBundle(Directory app) async {
    final profile = await _embeddedProvisioningProfilePayload(app);
    if (profile != null && _provisioningProfileRequiresDistribution(profile)) {
      return _installedDistributionIdentity();
    }
    final current = await _currentCodesignIdentity(app);
    if (current != null && current.startsWith('Apple Development:')) {
      return current;
    }
    return getDep<IosCodesign>().developerIdentity();
  }

  Future<bool> _codesignPath(
    String path,
    String identity, {
    bool preserveMetadata = false,
  }) async {
    final result = await _shell.runArgs(
      'codesign',
      [
        '--force',
        '--sign',
        identity,
        if (preserveMetadata) '--preserve-metadata=entitlements,requirements,flags',
        path,
      ],
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode == ExitCode.success.code) {
      return true;
    }
    _logger.err(
      '[reuse-last] failed to re-sign $path (exit ${result.exitCode}).',
    );
    return false;
  }

  Future<String?> _embeddedProvisioningProfilePayload(Directory app) async {
    final profile = File(p.join(app.path, 'embedded.mobileprovision'));
    if (!profile.existsSync()) {
      return null;
    }
    final result = await _shell.runArgs(
      'security',
      ['cms', '-D', '-i', profile.path],
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != ExitCode.success.code) {
      return null;
    }
    return result.outText;
  }

  bool _provisioningProfileRequiresDistribution(String payload) {
    return payload.contains('<key>ProvisionsAllDevices</key>') || !payload.contains('<key>ProvisionedDevices</key>');
  }

  Future<String?> _installedDistributionIdentity() async {
    final result = await _shell.runArgs(
      'security',
      ['find-identity', '-v', '-p', 'codesigning'],
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != ExitCode.success.code) {
      return null;
    }
    String? fallback;
    for (final line in result.outLines) {
      if (!line.contains('Apple Distribution:') && !line.contains('iPhone Distribution:')) {
        continue;
      }
      final match = RegExp('([0-9A-F]{40})').firstMatch(line);
      if (match == null) {
        continue;
      }
      fallback ??= match.group(1);
      final team = (_platform.environment[iosSigningTeamEnv] ?? '').trim();
      if (team.isNotEmpty && line.contains(team)) {
        return match.group(1);
      }
    }
    return fallback;
  }

  Future<String?> _currentCodesignIdentity(Directory bundle) async {
    final result = await _shell.runArgs(
      'codesign',
      ['-dv', '--verbose=4', bundle.path],
      throwOnError: false,
      silent: true,
    );
    return _codesignAuthorityIdentity('${result.errText}\n${result.outText}');
  }

  String? _codesignAuthorityIdentity(String output) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('Authority=')) {
        continue;
      }
      final authority = trimmed.substring('Authority='.length).trim();
      if (authority.contains('Apple Worldwide Developer Relations') || authority.contains('Apple Root')) {
        continue;
      }
      if (authority.isNotEmpty) {
        return authority;
      }
    }
    return null;
  }

  Directory? _ancestorNamed(File file, String name) {
    Directory current = file.parent;
    while (current.path != current.parent.path) {
      if (p.basename(current.path) == name) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  Directory? _ancestorWithSuffix(File file, String suffix) {
    Directory current = file.parent;
    while (current.path != current.parent.path) {
      if (current.path.endsWith(suffix)) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  /// Whether a local Android run records video: unless its [env] sets `MPLATROL_E2E_RECORD_ANDROID=false`.
  bool _recordsAndroidVideo(Map<String, String> env) => env['MPLATROL_E2E_RECORD_ANDROID'] != 'false';

  /// Runs [run] while the permission watcher answers system dialogs and the screen recorder records
  /// the device ([record] false only watches it for other recorders).
  Future<ProcessResultX> _runAndroidPatrolTestWithPermissionWatcher({
    required String deviceId,
    required String repo,
    required bool record,
    required Future<ProcessResultX> Function() run,
  }) async {
    var stopped = false;
    Future<ProcessResultX> adb(List<String> arguments, {required Duration timeout, Future<void>? cancelOn}) =>
        _adb(deviceId, arguments, timeout: timeout, cancelOn: cancelOn);
    final permissions = AndroidPermissionWatcher(deviceId: deviceId, adb: adb, logger: _logger);
    final recorder = AndroidScreenRecorder(
      deviceId: deviceId,
      outputDir: getDep<LocalLegArtifacts>().videoDirectory(repo),
      adb: adb,
      logger: _logger,
      record: record,
    );
    final watcher = _watchAndroidPermissionDialogs(deviceId, permissions, () => stopped);
    BiometricResponder? biometrics;
    // Everything started here is stopped in `finally`, also when a later start throws.
    try {
      biometrics = _isEmulator(deviceId) ? await _androidEmulatorBiometrics(deviceId) : null;
      await recorder.start();
      return await run();
    } finally {
      stopped = true;
      await biometrics?.stop();
      await watcher;
      _deviceEvidence
        ..addAll((await recorder.stop()).contention)
        ..addAll(permissions.notes);
    }
  }

  /// Enrolls a fingerprint on the emulator [deviceId] when it has none and answers the biometric
  /// journeys' match requests for the run.
  Future<BiometricResponder> _androidEmulatorBiometrics(String deviceId) async {
    final biometrics = getDep<LocalBiometrics>();
    await biometrics.enrollAndroidEmulator(deviceId);
    return biometrics.respondOnAndroidEmulator(deviceId);
  }

  Future<Map<String, String>> _runtimeEnvForLocalDevice({
    required ItVariant variant,
    required String deviceId,
    required Map<String, String> env,
    required bool localIosSimulator,
  }) async {
    final url = _runtimeCredentialUrl(env);
    if (url == null) {
      return env;
    }

    if (variant == ItVariant.androidLocal && !_isEmulator(deviceId)) {
      final reversed = await _reverseAndroidCredentialPort(deviceId, url.port);
      if (!reversed) {
        _logger.warn(
          '[e2e-creds] adb reverse failed for $deviceId; '
          'physical Android may not reach runtime credentials',
        );
      }
      return _withRuntimeCredentialUrl(
        env,
        url.replace(host: '127.0.0.1'),
      );
    }

    if (variant == ItVariant.iosLocal && !localIosSimulator) {
      final host = await _platform.localNetworkHost();
      if (host == null) {
        _logger.warn(
          '[e2e-creds] no non-loopback IPv4 address found; '
          'physical iOS may not reach runtime credentials',
        );
        return env;
      }
      return _withRuntimeCredentialUrl(env, url.replace(host: host));
    }

    return env;
  }

  Uri? _runtimeCredentialUrl(Map<String, String> env) {
    final value = (env[e2eCredentialsUrlEnv] ?? env[e2eCredentialsUrlFallbackEnv] ?? '').trim();
    if (value.isEmpty) {
      return null;
    }
    return Uri.tryParse(value);
  }

  Map<String, String> _withRuntimeCredentialUrl(
    Map<String, String> env,
    Uri url,
  ) {
    return {
      ...env,
      e2eCredentialsUrlEnv: url.toString(),
    };
  }

  Future<bool> _reverseAndroidCredentialPort(String deviceId, int port) async {
    if (port <= 0) {
      return false;
    }
    final result = await _adb(
      deviceId,
      ['reverse', 'tcp:$port', 'tcp:$port'],
    );
    if (_adbCommandSucceeded(result)) {
      _logger.info('[e2e-creds] adb reverse tcp:$port -> tcp:$port');
      return true;
    }
    return false;
  }

  Future<ProcessResultX> _runIosPatrolTestWithSimulatorObserver({
    required String deviceId,
    required bool localIosSimulator,
    required String repo,
    required Future<ProcessResultX> Function() run,
  }) async {
    if (!localIosSimulator) {
      return run();
    }
    await _openIosSimulator(deviceId);
    await _removeStaleIosTestRunnerApps(deviceId);
    final biometrics = getDep<LocalBiometrics>();
    BiometricResponder? matcher;
    ({Process process, String path, Future<void> stdoutDone})? logCapture;
    ({Process process, String path})? video;
    // Everything started here is stopped in `finally`, also when a later start throws.
    try {
      await biometrics.enrollIosSimulator(deviceId);
      matcher = await biometrics.respondOnIosSimulator(deviceId);
      logCapture = await _startIosSimulatorLog(deviceId, repo);
      video = await _startIosSimulatorVideo(deviceId, repo);
      return await run();
    } finally {
      await matcher?.stop();
      await _stopIosSimulatorVideo(video);
      await _stopIosSimulatorLog(logCapture);
      await _removeStaleIosTestRunnerApps(deviceId);
    }
  }

  Future<void> _openIosSimulator(String deviceId) async {
    final result = await _shell.runArgs(
      'open',
      ['-a', 'Simulator', '--args', '-CurrentDeviceUDID', deviceId],
      throwOnError: false,
      silent: true,
      timeout: const Duration(seconds: 10),
    );
    if (result.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] failed to open Simulator.app for $deviceId '
        '(exit ${result.exitCode}); continuing.',
      );
    }
  }

  Future<({Process process, String path})?> _startIosSimulatorVideo(
    String deviceId,
    String repo,
  ) async {
    if (_platform.environment['MPLATROL_E2E_RECORD_IOS'] == 'false') {
      return null;
    }
    final path = _e2eArtifactPath(
      repo: repo,
      directoryName: 'e2e-videos',
      prefix: 'ios',
      deviceId: deviceId,
      extension: 'mp4',
    );
    try {
      final process = await Process.start(
        'xcrun',
        [
          'simctl',
          'io',
          deviceId,
          'recordVideo',
          '--force',
          path,
        ],
      );
      // Real xcrun simctl recording I/O is not reproducible through the mock
      // seam and only spawns on a host with xcrun.
      // coverage:ignore-start
      _logger.info('[ios-video] recording $path');
      return (process: process, path: path);
    } catch (error) {
      _logger.warn('[ios-video] failed to start recording: $error');
      return null;
    }
    // coverage:ignore-end
  }

  Future<void> _stopIosSimulatorVideo(
    ({Process process, String path})? video,
  ) async {
    if (video == null) {
      return;
    }
    // A non-null video only exists after real xcrun recording launched, so the
    // teardown I/O is not reproducible through the mock seam.
    // coverage:ignore-start
    video.process.kill(ProcessSignal.sigint);
    try {
      await video.process.exitCode.timeout(const Duration(seconds: 10));
    } catch (_) {
      video.process.kill();
    }
    final file = File(video.path);
    if (file.existsSync() && file.lengthSync() > 0) {
      _logger.info('[ios-video] saved ${video.path}');
      return;
    }
    _logger.warn('[ios-video] failed to save ${video.path}');
    // coverage:ignore-end
  }

  Future<({Process process, String path, Future<void> stdoutDone})?> _startIosSimulatorLog(
      String deviceId, String repo) async {
    if (_platform.environment['MPLATROL_E2E_LOG_IOS'] == 'false') {
      return null;
    }
    final path = _e2eArtifactPath(
      repo: repo,
      directoryName: 'e2e-logs',
      prefix: 'ios',
      deviceId: deviceId,
      extension: 'log',
    );
    const predicate = '''
eventMessage CONTAINS[c] "PATROL" OR
eventMessage CONTAINS[c] "MPLATROL"
''';
    try {
      final process = await Process.start(
        'xcrun',
        [
          'simctl',
          'spawn',
          deviceId,
          'log',
          'stream',
          '--style',
          'compact',
          '--level',
          'debug',
          '--predicate',
          predicate.replaceAll('\n', ' '),
        ],
      );
      // Real xcrun simctl log-stream I/O is not reproducible through the mock
      // seam and only spawns on a host with xcrun.
      // coverage:ignore-start
      final stdoutDone = process.stdout.pipe(File(path).openWrite());
      unawaited(process.stderr.drain<void>());
      _logger.info('[ios-log] recording $path');
      return (process: process, path: path, stdoutDone: stdoutDone);
    } catch (error) {
      _logger.warn('[ios-log] failed to start simulator log capture: $error');
      return null;
    }
    // coverage:ignore-end
  }

  Future<void> _stopIosSimulatorLog(
    ({Process process, String path, Future<void> stdoutDone})? logCapture,
  ) async {
    if (logCapture == null) {
      return;
    }
    // A non-null logCapture only exists after real xcrun streaming launched, so
    // the teardown I/O is not reproducible through the mock seam.
    // coverage:ignore-start
    logCapture.process.kill(ProcessSignal.sigint);
    try {
      await logCapture.process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      logCapture.process.kill();
    }
    try {
      await logCapture.stdoutDone.timeout(const Duration(seconds: 5));
    } catch (_) {
      _logger.warn('[ios-log] simulator log stream did not close cleanly');
    }
    final file = File(logCapture.path);
    if (file.existsSync() && file.lengthSync() > 0) {
      _logger.info('[ios-log] saved ${logCapture.path}');
      return;
    }
    _logger.warn('[ios-log] failed to save ${logCapture.path}');
    // coverage:ignore-end
  }

  String _e2eArtifactPath({
    required String repo,
    required String directoryName,
    required String prefix,
    required String deviceId,
    required String extension,
  }) {
    final directory = Directory(p.join(repo, 'build', directoryName));
    directory.createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp('[:.]'), '-');
    final safeDevice = deviceId.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');
    return p.join(directory.path, '$prefix-$safeDevice-$stamp.$extension');
  }

  Future<void> _removeStaleIosTestRunnerApps(String deviceId) async {
    final result = await _xcrunSimctl(
      ['listapps', deviceId, '--json'],
      timeout: _iosSimctlCommandTimeout,
    );
    if (result.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl listapps $deviceId exited with code '
        '${result.exitCode}; skipping stale XCUITest runner cleanup.',
      );
      return;
    }

    final staleBundleIds = <String>[];
    try {
      final decoded = jsonDecode(
        await _iosListAppsJson(result.stdout),
      );
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          continue;
        }
        final name = [
          value['CFBundleName'],
          value['CFBundleDisplayName'],
          value['CFBundleExecutable'],
        ].whereType<String>().join(' ');
        if (entry.key.contains('RunnerUITests') || name.contains('RunnerUITests')) {
          staleBundleIds.add(entry.key);
        }
      }
      // jsonDecode only throws for plist output normalized through the
      // un-mockable plutil fallback in _iosListAppsJson; every mockable path
      // yields valid JSON.
      // coverage:ignore-start
    } on FormatException catch (error) {
      _logger.warn(
        '[ios-sim] could not parse simctl listapps JSON for runner cleanup: '
        '$error',
      );
      return;
    }
    // coverage:ignore-end

    if (staleBundleIds.isEmpty) {
      return;
    }

    for (final bundleId in staleBundleIds) {
      final uninstall = await _xcrunSimctl(
        ['uninstall', deviceId, bundleId],
        timeout: _iosSimctlCommandTimeout,
      );
      if (uninstall.exitCode == ExitCode.success.code) {
        _logger.info('[ios-sim] removed stale XCUITest runner app $bundleId');
        continue;
      }
      _logger.warn(
        '[ios-sim] failed to uninstall stale XCUITest runner app $bundleId '
        '(exit ${uninstall.exitCode}).',
      );
    }
  }

  Future<String> _iosListAppsJson(String output) async {
    final trimmed = output.trimLeft();
    // Only a "{"-prefixed payload is a candidate for JSON or plist; anything
    // else (empty, plain text) has no apps to clean, so skip the macOS-only
    // plutil normalization entirely.
    if (!trimmed.startsWith('{')) {
      return '{}';
    }
    try {
      jsonDecode(output);
      return output;
      // The plist-normalization fallback runs a real plutil Process.start
      // against a temp file and cannot be mocked.
      // coverage:ignore-start
    } on FormatException {
      // simctl advertises --json but may return plist syntax that also
      // starts with "{". Fall through and normalize it through plutil.
    }
    final tempDir = await Directory.systemTemp.createTemp('mplatrol-listapps-');
    final plistFile = File(p.join(tempDir.path, 'listapps.plist'));
    await plistFile.writeAsString(output);
    final process = await Process.start(
      'plutil',
      ['-convert', 'json', '-o', '-', plistFile.path],
    );
    try {
      final converted = await process.stdout.transform(utf8.decoder).join();
      final errors = await process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        _iosSimctlCommandTimeout,
      );
      if (exitCode != ExitCode.success.code) {
        throw const FormatException('simctl listapps output was not JSON');
      }
      if (errors.trim().isNotEmpty) {
        _logger.warn('[ios-sim] plutil listapps conversion warnings: $errors');
      }
      return converted;
    } finally {
      await tempDir.delete(recursive: true);
    }
    // coverage:ignore-end
  }

  /// How often the Android watcher reads the focused window: once a second, with the light
  /// [androidFocusCommand]. The full `dumpsys window` it read four times a second (plus a second one every
  /// 2 s) takes the window manager lock each time; on an overloaded host the emulator's watchdog then kills its
  /// system server once the window manager monitor is blocked for minutes.
  static const _androidWatchInterval = Duration(seconds: 1);

  Future<void> _watchAndroidPermissionDialogs(
    String deviceId,
    AndroidPermissionWatcher permissions,
    bool Function() stopped,
  ) async {
    while (!stopped()) {
      await Future<void>.delayed(_androidWatchInterval);
      if (stopped()) {
        return;
      }
      final focus = await _adb(deviceId, const ['shell', androidFocusCommand]);
      if (!_adbCommandSucceeded(focus)) {
        continue;
      }
      await permissions.answer(focus.stdout);
    }
  }

  Future<void> _prepareLocalIosSdkBuild(
    String repo, {
    required bool simulator,
  }) async {
    if (simulator && linkFlutterIntoSimulatorUiTests(repo)) {
      _logger.info('[ios-sim-link] RunnerUITests links Flutter.framework for this simulator build');
    }
  }

  Future<bool> _ensurePhysicalIosSigningProfiles({
    required String repo,
    required String? appId,
    required Map<String, String> env,
  }) async {
    final appBundleId = appId?.trim() ?? '';
    if (appBundleId.isEmpty) {
      _logger.err(
        '[ios-signing] could not determine the iOS app bundle id before '
        'physical-device build.',
      );
      return false;
    }
    final bundleIds = _physicalIosEnterpriseBundleIds(repo, appBundleId);
    final profiles = <String, IosProvisioningProfile>{};
    for (final bundleId in bundleIds) {
      var profile = await getDep<IosCodesign>().installedProfileForBundleId(
        bundleId,
      );
      if (profile == null) {
        if (!await _installSigningProfileForBundleId(
          repo: repo,
          bundleId: bundleId,
          env: env,
        )) {
          return false;
        }
        // Only reached after a successful signing command, which shells out via
        // Process.run and cannot be mocked.
        // coverage:ignore-start
        profile = await getDep<IosCodesign>().installedProfileForBundleId(
          bundleId,
        );
      }
      if (profile == null) {
        _logger.err(
          '[ios-signing] $iosSigningCommandEnv completed, but no installed '
          'provisioning profile was found for $bundleId.',
        );
        return false;
      }
      // coverage:ignore-end
      profiles[bundleId] = profile;
    }
    _patchIosProvisioningProfileSpecifiers(repo, profiles);
    final runnerProfile = await getDep<IosCodesign>().installedXctrunnerDevelopmentProfile();
    if (runnerProfile == null) {
      _logger.err(
        '[ios-signing] no installed iOS App Development .xctrunner profile '
        'was found. Install any development XCUITest runner profile or add an '
        'Xcode account that can create one for $appBundleId.uitests.xctrunner.',
      );
      return false;
    }
    _patchIosRunnerUiTestsSigningProfile(repo, runnerProfile);
    return true;
  }

  List<String> _physicalIosEnterpriseBundleIds(String repo, String appBundleId) {
    final projectFile = File(p.join(repo, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    final ids = <String>{appBundleId};
    if (!projectFile.existsSync()) {
      return ids.toList();
    }
    final source = projectFile.readAsStringSync();
    for (final suffix in const ['notificationservice', 'notificationcontent']) {
      final bundleId = '$appBundleId.$suffix';
      if (!source.contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId;')) {
        continue;
      }
      if (!_hasNonEmptyProvisioningSpecifierForBundle(source, bundleId)) {
        continue;
      }
      ids.add(bundleId);
    }
    return ids.toList();
  }

  bool _hasNonEmptyProvisioningSpecifierForBundle(
    String source,
    String bundleId,
  ) {
    return _xcodeBuildConfigurationPattern.allMatches(source).any((match) {
      final block = match.group(0)!;
      if (!block.contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId;')) {
        return false;
      }
      final specifier = _provisioningProfileSpecifierPattern.firstMatch(block)?.group(1)?.replaceAll('"', '').trim();
      return specifier != null && specifier.isNotEmpty;
    });
  }

  /// Runs [iosSigningCommandEnv] (through `/bin/sh -c`, with `MPLATROL_BUNDLE_ID` set to [bundleId]) to install a
  /// provisioning profile for [bundleId].
  /// False (after logging the fix) when the variable is unset or the command fails.
  Future<bool> _installSigningProfileForBundleId({
    required String repo,
    required String bundleId,
    required Map<String, String> env,
  }) async {
    final command = (env[iosSigningCommandEnv] ?? _platform.environment[iosSigningCommandEnv] ?? '').trim();
    if (command.isEmpty) {
      _logger.err(
        '[ios-signing] no provisioning profile is installed for $bundleId. Install one in Xcode, or set '
        '$iosSigningCommandEnv to a command that installs it (it runs with MPLATROL_BUNDLE_ID=$bundleId), then retry.',
      );
      return false;
    }
    // Runs the user's signing command via Process.run, an external tool invocation that cannot be exercised
    // through the mock seam.
    // coverage:ignore-start
    _logger.info('[ios-signing] installing a provisioning profile for $bundleId');
    final result = await getDep<ProcessRunFunction>()(
      '/bin/sh',
      ['-c', command],
      workingDirectory: p.join(repo, 'ios'),
      environment: {..._platform.environment, ...env, 'MPLATROL_BUNDLE_ID': bundleId},
    );
    if (result.exitCode == ExitCode.success.code) {
      return true;
    }
    _logger.err('[ios-signing] $iosSigningCommandEnv failed for $bundleId (exit ${result.exitCode}).');
    _lastNonEmptyLines('${result.stdout}\n${result.stderr}', 20).forEach(_logger.err);
    return false;
    // coverage:ignore-end
  }

  void _patchIosProvisioningProfileSpecifiers(
    String repo,
    Map<String, IosProvisioningProfile> profiles,
  ) {
    final projectFile = File(p.join(repo, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    if (!projectFile.existsSync()) {
      return;
    }
    final source = projectFile.readAsStringSync();
    var updated = source;
    for (final entry in profiles.entries) {
      updated = _patchProvisioningProfileSpecifier(
        updated,
        bundleId: entry.key,
        profileName: entry.value.name,
      );
    }
    if (updated == source) {
      return;
    }
    projectFile.writeAsStringSync(updated);
    _logger.info(
      '[ios-signing] patched Runner.xcodeproj provisioning profile '
      'specifier(s) for ${profiles.keys.join(', ')}',
    );
  }

  void _patchIosRunnerUiTestsSigningProfile(
    String repo,
    IosProvisioningProfile profile,
  ) {
    final runnerBundleId = _runnerBundleIdFromXctrunnerProfile(profile.applicationIdentifier);
    if (runnerBundleId == null) {
      _logger.err(
        '[ios-signing] installed runner profile ${profile.name} does not '
        'have an .xctrunner application identifier.',
      );
      return;
    }
    final projectFile = File(p.join(repo, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    if (!projectFile.existsSync()) {
      return;
    }
    final source = projectFile.readAsStringSync();
    final updated = source.replaceAllMapped(_xcodeBuildConfigurationPattern, (match) {
      var block = match.group(0)!;
      if (!block.contains('INFOPLIST_FILE = RunnerUITests/Info.plist;')) {
        return block;
      }
      block = upsertSortedPbxBuildSetting(
        block,
        'PRODUCT_BUNDLE_IDENTIFIER',
        runnerBundleId,
      );
      block = upsertSortedPbxBuildSetting(
        block,
        'CODE_SIGN_STYLE',
        'Manual',
      );
      block = upsertSortedPbxBuildSetting(
        block,
        'DEVELOPMENT_TEAM',
        IosCodesign.teamId,
      );
      block = upsertSortedPbxBuildSetting(
        block,
        'PROVISIONING_PROFILE_SPECIFIER',
        '"${_escapePbxValue(profile.name)}"',
      );
      return block;
    });
    if (updated == source) {
      return;
    }
    projectFile.writeAsStringSync(updated);
    _logger.info(
      '[ios-signing] patched RunnerUITests to use installed runner profile '
      '${profile.name}',
    );
  }

  String? _runnerBundleIdFromXctrunnerProfile(String applicationIdentifier) {
    const suffix = '.xctrunner';
    final prefix = '${IosCodesign.teamId}.';
    if (!applicationIdentifier.startsWith(prefix) || !applicationIdentifier.endsWith(suffix)) {
      return null;
    }
    return applicationIdentifier.substring(prefix.length, applicationIdentifier.length - suffix.length).trim();
  }

  String _patchProvisioningProfileSpecifier(
    String source, {
    required String bundleId,
    required String profileName,
  }) {
    return source.replaceAllMapped(_xcodeBuildConfigurationPattern, (match) {
      final block = match.group(0)!;
      if (!block.contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId;')) {
        return block;
      }
      if (!_provisioningProfileSpecifierPattern.hasMatch(block)) {
        return block;
      }
      return block.replaceFirst(
        _provisioningProfileSpecifierPattern,
        'PROVISIONING_PROFILE_SPECIFIER = "${_escapePbxValue(profileName)}";',
      );
    });
  }

  String _escapePbxValue(String value) => value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  List<String> _lastNonEmptyLines(String output, int count) {
    final lines = output.split('\n').map((line) => line.trimRight()).where((line) => line.trim().isNotEmpty).toList();
    if (lines.length <= count) {
      return lines;
    }
    return lines.sublist(lines.length - count);
  }

  Future<ProcessResultX> _runPatrolTest({
    required String executable,
    required List<String> arguments,
    required String repo,
    Duration? timeout,
    bool quietBuild = true,
    void Function()? onBuildStarted,
  }) async {
    onBuildStarted?.call();
    if (timeout != null) {
      final result = await _shell.runArgs(
        executable,
        arguments,
        workingDirectory: repo,
        throwOnError: false,
        quietBuild: quietBuild,
        surfaceFailureOutput: true,
        timeout: timeout,
      );
      _observeAndroidBuildResult(arguments, result);
      if (_patrolTimedOut(result)) {
        _logger.err('[patrol-timeout] Local Patrol build/test exceeded '
            '${timeout.inSeconds}s; the attempt was terminated. '
            'Review the last test step and device logs before retrying.');
      }
      return result;
    }
    final result = await _shell.runArgs(
      executable,
      arguments,
      workingDirectory: repo,
      throwOnError: false,
      // Keep successful local runs quiet and preserve failure tails through
      // MplatrolShell's quiet-build diagnostics.
      quietBuild: quietBuild,
      surfaceFailureOutput: true,
    );
    _observeAndroidBuildResult(arguments, result);
    return result;
  }

  void _observeAndroidBuildResult(
    List<String> arguments,
    ProcessResultX result,
  ) {
    if (arguments.contains('--no-uninstall') && !arguments.contains(_iosOnlyActiveArch)) {
      _androidBuildSucceeded =
          const LineSplitter().convert(result.outText).any((line) => line.trim() == _androidBuildSuccessMarker);
    }
  }

  bool _patrolTimedOut(ProcessResultX result) =>
      result.exitCode == ExitCode.tempFail.code && result.errText.contains('Timed out after ');

  /// Runs `patrol test`, retrying the build up to [_buildRetryAttempts] times
  /// when it fails on a transient dependency/network error (see
  /// [_transientBuildFailureMarkers]). A real compile/test failure is returned
  /// on the first attempt without retry.
  Future<ProcessResultX> _runPatrolTestWithBuildRetry({
    required String executable,
    required List<String> arguments,
    required String repo,
    Duration? timeout,
    bool quietBuild = true,
    void Function()? onBuildStarted,
  }) async {
    var result = await _runPatrolTest(
      executable: executable,
      arguments: arguments,
      repo: repo,
      timeout: timeout,
      quietBuild: quietBuild,
      onBuildStarted: onBuildStarted,
    );
    for (var attempt = 1;
        attempt <= _buildRetryAttempts &&
            result.exitCode != ExitCode.success.code &&
            !_patrolTimedOut(result) &&
            _isTransientBuildFailure(result);
        attempt++) {
      _logger.warn(
        '[build-retry] Build failed on a transient dependency/network error '
        '(attempt $attempt/$_buildRetryAttempts); retrying in '
        '${_buildRetryDelay.inSeconds}s.',
      );
      await getDep<SleepFunction>()(_buildRetryDelay);
      result = await _runPatrolTest(
        executable: executable,
        arguments: arguments,
        repo: repo,
        timeout: timeout,
        quietBuild: quietBuild,
        onBuildStarted: onBuildStarted,
      );
    }
    return result;
  }

  bool _isTransientBuildFailure(ProcessResultX result) =>
      isTransientBuildFailure('${result.outText}\n${result.errText}');

  Future<void> _restartIosSimulator(String deviceId) async {
    final shutdown = await _xcrunSimctl(['shutdown', deviceId], timeout: _iosSimctlCommandTimeout);
    if (shutdown.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl shutdown $deviceId exited with code '
        '${shutdown.exitCode}; continuing with boot.',
      );
    }
    final boot = await _xcrunSimctl(['boot', deviceId], timeout: _iosSimctlCommandTimeout);
    if (boot.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl boot $deviceId exited with code '
        '${boot.exitCode}; waiting for boot status anyway.',
      );
    }
    final bootStatus = await _xcrunSimctl(['bootstatus', deviceId, '-b'], timeout: _iosSimctlBootTimeout);
    if (bootStatus.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl bootstatus $deviceId exited with code '
        '${bootStatus.exitCode}; retrying Patrol anyway.',
      );
    }
  }

  Future<void> _prepareIosSimulator(String deviceId) async {
    // Every simulator, not only booted ones: whether this run is on the spec simulator is read from its name,
    // which a `booted` listing lacks while it is still shut down.
    final list = await _xcrunSimctl(['list', 'devices'], timeout: _iosSimctlCommandTimeout);
    final booted = list.exitCode == ExitCode.success.code ? _simulatorUdids(list.stdout).toSet() : <String>{};
    if (list.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl list devices exited with code '
        '${list.exitCode}; continuing with $deviceId.',
      );
    }

    // A run on the spec simulator shuts down other booted copies of it (`simctl shutdown` fails on one that is
    // already shut down). Other simulators stay booted (an agent's own one is in use between its runs); the iOS
    // lease keeps their runs out while this one runs, and [_stopOtherSimulatorAppsOnPatrolPorts] stops an app a
    // finished run left listening on Patrol's ports.
    final entries = SimulatorEntry.parse(const LineSplitter().convert(list.stdout));
    final onSpec = entries.any((entry) => entry.udid == deviceId && entry.name == LocalDeviceSpec.iosDeviceName);
    final otherSpecSimulators = entries
        .where((entry) => onSpec && entry.name == LocalDeviceSpec.iosDeviceName && entry.udid != deviceId)
        .map((entry) => entry.udid)
        .where(booted.contains);
    for (final bootedId in otherSpecSimulators) {
      final shutdown = await _xcrunSimctl(['shutdown', bootedId], timeout: _iosSimctlCommandTimeout);
      if (shutdown.exitCode != ExitCode.success.code) {
        _logger.warn(
          '[ios-sim] simctl shutdown $bootedId exited with code '
          '${shutdown.exitCode}; continuing.',
        );
      }
    }

    await _stopOtherSimulatorAppsOnPatrolPorts(deviceId);

    if (!booted.contains(deviceId)) {
      final boot = await _xcrunSimctl(['boot', deviceId], timeout: _iosSimctlCommandTimeout);
      if (boot.exitCode != ExitCode.success.code) {
        _logger.warn(
          '[ios-sim] simctl boot $deviceId exited with code '
          '${boot.exitCode}; waiting for boot status anyway.',
        );
      }
    }

    final bootStatus = await _xcrunSimctl(['bootstatus', deviceId, '-b'], timeout: _iosSimctlBootTimeout);
    if (bootStatus.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[ios-sim] simctl bootstatus $deviceId exited with code '
        '${bootStatus.exitCode}; running Patrol anyway.',
      );
    }
  }

  Iterable<String> _simulatorUdids(String output) sync* {
    final bootedDevicePattern = RegExp(r'\(([^()]+)\)\s+\(Booted\)');
    for (final line in output.split('\n')) {
      final match = bootedDevicePattern.firstMatch(line);
      if (match != null) {
        yield match.group(1)!;
      }
    }
  }

  /// Removes [appId] from [deviceId] so the app-upgrade setup leg installs the previous release fresh.
  /// An app that is not installed is fine; any other failure is logged, and the setup leg's own install
  /// then reports what is wrong.
  Future<void> _uninstallBeforeUpgradeSetup(
      {required bool isAndroid, required String deviceId, required String appId}) async {
    final result = isAndroid
        ? await _shell.runArgs('adb', ['-s', deviceId, 'uninstall', appId],
            throwOnError: false, silent: true, timeout: _iosSimctlCommandTimeout)
        : _isCoreSimulatorDeviceId(deviceId)
            ? await _xcrunSimctl(['uninstall', deviceId, appId], timeout: _iosSimctlCommandTimeout)
            : await _xcrunDevicectlUninstallApp(deviceId, appId);
    _logger.info(result.exitCode == ExitCode.success.code
        ? '[upgrade-from] removed $appId from $deviceId before installing the previous release'
        : '[upgrade-from] $appId was not removed from $deviceId (exit ${result.exitCode}): '
                '${result.errText.isEmpty ? result.outText : result.errText}'
            .trim());
  }

  /// Stops apps on other simulators that listen on Patrol's iOS ports ([_patrolIosPorts]). Simulators share the
  /// Mac's network, so an app a finished run left open there answers this run's `listDartTests` with its own
  /// tests. This run holds the iOS lease, so no other run is using such an app. A listener that is not a
  /// simulator app is only reported.
  Future<void> _stopOtherSimulatorAppsOnPatrolPorts(String deviceId) async {
    final listeners = await _shell.runArgs(
        'lsof', ['-nP', for (final port in _patrolIosPorts) '-iTCP:$port', '-sTCP:LISTEN', '-Fp'],
        throwOnError: false, silent: true, timeout: _iosSimctlCommandTimeout);
    final pids = {
      for (final line in const LineSplitter().convert(listeners.stdout))
        if (line.startsWith('p')) line.substring(1),
    };
    for (final pid in pids) {
      final files = await _shell.runArgs('lsof', ['-nP', '-a', '-p', pid, '-d', 'txt', '-Fn'],
          throwOnError: false, silent: true, timeout: _iosSimctlCommandTimeout);
      final app = RegExp(r'^n(.*/CoreSimulator/Devices/([0-9A-F-]{36})/.*\.app/[^/\n]+)$', multiLine: true)
          .firstMatch(files.stdout);
      if (app == null) {
        _logger.warn('[ios-sim] process $pid listens on Patrol port ${_patrolIosPorts.join('/')} and is not a '
            'simulator app; Patrol may reach it instead of the app under test. Stop it if the run fails.');
        continue;
      }
      if (app.group(2) == deviceId) {
        continue;
      }
      final stop =
          await _shell.runArgs('kill', [pid], throwOnError: false, silent: true, timeout: _iosSimctlCommandTimeout);
      _logger.info('[ios-sim] stopped ${p.basename(app.group(1)!)} (pid $pid) on simulator ${app.group(2)}: it held '
          'Patrol port ${_patrolIosPorts.join('/')}${stop.exitCode == 0 ? '' : ' (kill exit ${stop.exitCode})'}');
    }
  }

  Future<ProcessResultX> _xcrunSimctl(List<String> arguments, {required Duration timeout}) {
    return _shell.runArgs('xcrun', ['simctl', ...arguments], throwOnError: false, silent: true, timeout: timeout);
  }

  Future<ProcessResultX> _xcrunDevicectlUninstallApp(
    String deviceId,
    String bundleId,
  ) {
    return _shell.runArgs(
      'xcrun',
      [
        'devicectl',
        'device',
        'uninstall',
        'app',
        '--device',
        deviceId,
        bundleId,
      ],
      throwOnError: false,
      silent: true,
      timeout: _iosSimctlCommandTimeout,
    );
  }

  List<String> _rawDartDefines(List<String> args) => [
        for (final arg in args)
          if (arg.startsWith('--dart-define=')) arg.substring('--dart-define='.length),
      ];

  Future<bool> _diagnoseAndroidVersionDowngrade(
    String deviceId,
    String repo,
    String? appId,
    ProcessResultX result,
    DateTime attemptStartedAt,
  ) async {
    if (!await _hasCurrentAndroidVersionDowngrade(repo, result, attemptStartedAt)) {
      return false;
    }
    await _logAndroidDowngradeEligibility(deviceId, appId);
    return true;
  }

  Future<bool> _hasCurrentAndroidVersionDowngrade(
    String repo,
    ProcessResultX result,
    DateTime attemptStartedAt,
  ) async {
    const failure = 'INSTALL_FAILED_VERSION_DOWNGRADE';
    if ('${result.outText}\n${result.errText}'.contains(failure)) {
      return true;
    }
    final reports = Directory(_androidTestResultsDir(repo));
    if (!reports.existsSync()) {
      return false;
    }
    final collectedAt = DateTime.now();
    for (final file in reports.listSync(recursive: true, followLinks: false).whereType<File>()) {
      if (!_isAndroidTextReport(file.path)) {
        continue;
      }
      final text = await AndroidTestDiagnostics().readCurrentReport(
        file,
        runStartedAt: attemptStartedAt,
        collectedAt: collectedAt,
      );
      if (text != null && text.contains(failure)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _logAndroidDowngradeEligibility(String deviceId, String? appId) async {
    const failure = 'INSTALL_FAILED_VERSION_DOWNGRADE';
    // Unreachable: the Android appId comes from preparedAndroidApplicationId,
    // which returns a non-null id or throws before this method is called.
    // coverage:ignore-start
    if (appId == null) {
      _logger.err('[android-device] $failure: applicationId is unavailable. '
          'Cannot verify downgrade eligibility; no install or rebuild retry.');
      return;
    }
    // coverage:ignore-end
    final installed = await _adb(deviceId, ['shell', 'dumpsys', 'package', appId]);
    final flags = RegExp(r'^\s*(?:pkgFlags|flags)=\[([^\]]*)\]', multiLine: true)
        .allMatches(installed.outText)
        .map((match) => match.group(1)!)
        .toList();
    if (installed.exitCode != 0 || flags.isEmpty) {
      _logger.err('[android-device] $failure for $appId: could not verify '
          'installed package debug eligibility. Check adb dumpsys package '
          'and both APK signatures before retrying; no automatic install.');
    } else if (!flags.any((value) => value.split(RegExp(r'\s+')).contains('DEBUGGABLE'))) {
      _logger.err('[android-device] $failure for $appId: installed app is '
          'not debuggable. adb install -r -d cannot bypass this restriction '
          'on a production device. Use a compatible signed build or an '
          'eligible debug test device; existing app data is left untouched.');
    } else {
      _logger.err('[android-device] $failure for $appId: installed app is '
          'debuggable, but matching APK signatures and unchanged build inputs '
          'must be verified before a data-preserving -r -d recovery. '
          'No blind install, data clear or rebuild retry was performed.');
    }
  }

  Future<bool> _recoverAndroidInstallFailure(String deviceId, String repo) async {
    if (!_isEmulator(deviceId) || !_androidInstallCommitFailed(repo)) {
      return false;
    }
    _logger.warn(
      '[android-device] Android package install failed because the '
      'emulator package service broke; rebooting $deviceId once and '
      'retrying.',
    );
    if (await _rebootAndroidDevice(deviceId)) {
      return true;
    }
    _logger.warn(
      '[android-device] Android framework services did not become '
      'available on $deviceId after install-failure reboot; cold-starting '
      'the emulator AVD.',
    );
    return _coldStartAndroidEmulator(deviceId);
  }

  Future<bool> _recoverMissingAndroidTargetApp(
    String deviceId,
    String repo,
    ProcessResultX result,
  ) async {
    final output = '${result.outText}\n${result.errText}';
    if (!output.contains('ActivityNotFoundException') || !output.contains('Unable to find explicit activity class')) {
      return false;
    }
    final apk = File(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'));
    if (!apk.existsSync()) {
      _logger.err(
        '[android-device] Patrol failed because the target app was not '
        'launchable, and ${apk.path} does not exist. Rebuild and retry.',
      );
      return false;
    }
    _logger.warn(
      '[android-device] Patrol could not launch the target app; installing '
      'the just-built debug APK and retrying once.',
    );
    final install = await _adb(
      deviceId,
      ['install', '-r', '-d', apk.path],
      timeout: _androidAdbWaitForDeviceTimeout,
    );
    if (install.exitCode == ExitCode.success.code) {
      return true;
    }
    _logger.err(
      '[android-device] failed to install ${apk.path} on $deviceId '
      '(exit ${install.exitCode}). ${install.errText}',
    );
    return false;
  }

  bool _androidInstallCommitFailed(String repo) {
    final root = Directory(_androidTestResultsDir(repo));
    if (!root.existsSync()) {
      return false;
    }
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !_isAndroidTextReport(entity.path)) {
        continue;
      }
      final content = entity.readAsStringSync();
      if (content.contains('Failed to commit install session') &&
          (content.contains('Failure calling service package: Broken pipe') ||
              content.contains('INSTALL_FAILED_PACKAGE_CHANGED'))) {
        return true;
      }
    }
    return false;
  }

  bool _isAndroidTextReport(String path) =>
      path.endsWith('.xml') || path.endsWith('.html') || path.endsWith('.textproto');

  String _androidTestResultsDir(String repo) =>
      p.join(repo, 'build', 'app', 'outputs', 'androidTest-results', 'connected', 'debug');

  Future<bool> _ensureAndroidDeviceReady(String deviceId) async {
    if (await _androidFrameworkReady(deviceId)) {
      return true;
    }
    if (!_isEmulator(deviceId)) {
      _logger.err(
        'Android device $deviceId is connected, but Android '
        'framework services are unavailable. Reboot or reconnect the device '
        'and retry.',
      );
      return false;
    }

    // An emulator that just booted reports boot_completed before its package
    // and activity services answer; rebooting it then disrupts whoever
    // launched it, so give it the normal framework wait first.
    _logger.info(
      '[android-device] Android framework services are not answering on '
      '$deviceId yet; waiting up to '
      '${_androidFrameworkAttempts * _androidFrameworkPollDelay.inSeconds}s.',
    );
    if (await _waitForAndroidFramework(deviceId)) {
      return true;
    }
    _logger.warn(
      '[android-device] Android framework services are unavailable '
      'on $deviceId; rebooting the emulator once.',
    );
    if (await _rebootAndroidDevice(deviceId)) {
      return true;
    }
    _logger.warn(
      '[android-device] Android framework services did not become '
      'available on $deviceId after reboot; cold-starting the emulator AVD.',
    );
    final ready = await _coldStartAndroidEmulator(deviceId);
    if (!ready) {
      _logger.err(
        '[android-device] Android framework services did not become '
        'available on $deviceId after cold start.',
      );
    }
    return ready;
  }

  /// Re-checks [deviceId] right before Gradle runs: after the one-time reboot an emulator can drop back to
  /// `offline` once adb redoes its auth handshake, and UTP then ends every test with "device not found".
  /// An emulator is reconnected, then cold-started; any other device is never touched.
  Future<bool> _ensureAndroidDeviceOnline(String deviceId, String repo) async {
    final problem = await _androidDeviceProblem(deviceId);
    if (problem == null) {
      return true;
    }
    if (!_isEmulator(deviceId)) {
      _reportAndroidDeviceOffline(
          deviceId, repo, problem, 'Reconnect or unlock the device, accept the USB debugging prompt, and rerun.');
      return false;
    }
    _logger.warn(
      '[android-device] $deviceId is not ready ($problem) right before Gradle; reconnecting it and waiting up to '
      '${_androidReconnectAttempts * _androidReconnectPollDelay.inSeconds}s.',
    );
    await _adb(deviceId, const ['reconnect']);
    if (await _waitForAndroidDeviceOnline(deviceId)) {
      return true;
    }
    _logger.warn('[android-device] $deviceId is still not online after reconnect; cold-starting the emulator AVD.');
    if (await _coldStartAndroidEmulator(deviceId)) {
      final afterColdStart = await _androidDeviceProblem(deviceId);
      if (afterColdStart == null) {
        return true;
      }
      _reportAndroidDeviceOffline(deviceId, repo, afterColdStart, _androidOfflineRemedy);
      return false;
    }
    _reportAndroidDeviceOffline(deviceId, repo, problem, _androidOfflineRemedy);
    return false;
  }

  static const _androidOfflineRemedy = 'Reconnect and cold start did not bring it back: close the emulator, '
      'run `mplatrol devices --setup`, and rerun.';

  Future<bool> _waitForAndroidDeviceOnline(String deviceId) async {
    for (var attempt = 1; attempt <= _androidReconnectAttempts; attempt++) {
      await getDep<SleepFunction>()(_androidReconnectPollDelay);
      if (await _androidDeviceProblem(deviceId) == null) {
        _logger.info('[android-device] $deviceId is back online after reconnect.');
        return true;
      }
    }
    return false;
  }

  /// Null when adb lists [deviceId] as `device` and it reports `sys.boot_completed=1`; otherwise what is
  /// wrong with it, e.g. `offline`, `unauthorized` or `not found`.
  Future<String?> _androidDeviceProblem(String deviceId) async {
    final state = await _adb(deviceId, const ['get-state']);
    final stateText = state.outText.trim();
    if (state.exitCode != ExitCode.success.code || stateText != 'device') {
      final error = state.errText.trim().split('\n').first.replaceFirst('error: ', '').trim();
      final detail = error.isNotEmpty ? error : stateText;
      return detail.isEmpty ? 'not answering adb (exit ${state.exitCode})' : detail;
    }
    final booted = await _adb(deviceId, const ['shell', 'getprop', 'sys.boot_completed']);
    final bootValue = booted.outText.trim();
    if (booted.exitCode != ExitCode.success.code || bootValue != '1') {
      return 'not booted (sys.boot_completed=${bootValue.isEmpty ? 'unset' : bootValue})';
    }
    return null;
  }

  void _reportAndroidDeviceOffline(String deviceId, String repo, String problem, String remedy) {
    final message = '[android-device] $androidDeviceNotReadyMarker: $deviceId is not ready ($problem) before '
        'Gradle, so no test can run. $remedy';
    _logger.err(message);
    reportTestLessons(message, repo: repo, logger: _logger);
  }

  Future<bool> _rebootAndroidDevice(String deviceId) async {
    final reboot = await _adb(deviceId, const ['reboot']);
    if (reboot.exitCode != ExitCode.success.code) {
      _logger.err(
        '[android-device] failed to reboot $deviceId '
        '(exit ${reboot.exitCode}).',
      );
      return false;
    }
    final wait = await _adb(deviceId, const ['wait-for-device'], timeout: _androidAdbWaitForDeviceTimeout);
    if (wait.exitCode != ExitCode.success.code) {
      _logger.err(
        '[android-device] $deviceId did not reconnect after reboot '
        '(exit ${wait.exitCode}).',
      );
      return false;
    }
    return _waitForAndroidFramework(deviceId);
  }

  Future<bool> _coldStartAndroidEmulator(String deviceId) async {
    final avdName = await _androidAvdName(deviceId);
    if (avdName == null) {
      _logger.err(
        '[android-device] could not resolve the AVD name for '
        '$deviceId; restart the emulator manually and retry.',
      );
      return false;
    }
    final kill = await _adb(deviceId, const ['emu', 'kill'], timeout: _androidEmulatorCommandTimeout);
    if (kill.exitCode != ExitCode.success.code) {
      _logger.warn(
        '[android-device] failed to stop $deviceId before cold '
        'start (exit ${kill.exitCode}); launching a fresh AVD anyway.',
      );
    }
    if (!await _waitForAndroidDeviceDisconnect(deviceId)) {
      _logger.warn(
        '[android-device] $deviceId was still listed by adb after '
        'emulator shutdown; starting the AVD anyway.',
      );
    }
    await getDep<SleepFunction>()(_androidEmulatorRestartSettleDelay);
    try {
      await _shell.startDetached('emulator', ['-avd', avdName, '-no-snapshot-load']);
    } catch (error) {
      _logger.err(
        '[android-device] failed to cold-start AVD "$avdName": '
        '$error',
      );
      return false;
    }
    final wait = await _adb(deviceId, const ['wait-for-device'], timeout: _androidColdStartWaitForDeviceTimeout);
    if (wait.exitCode != ExitCode.success.code) {
      _logger.err(
        '[android-device] $deviceId did not connect after cold '
        'start (exit ${wait.exitCode}).',
      );
      return false;
    }
    return _waitForAndroidFramework(deviceId, attempts: _androidColdStartFrameworkAttempts);
  }

  Future<bool> _waitForAndroidDeviceDisconnect(String deviceId) async {
    for (var attempt = 1; attempt <= _androidEmulatorShutdownAttempts; attempt++) {
      if (!await _androidDeviceListed(deviceId)) {
        return true;
      }
      if (attempt < _androidEmulatorShutdownAttempts) {
        await getDep<SleepFunction>()(_androidEmulatorShutdownPollDelay);
      }
    }
    return false;
  }

  Future<bool> _androidDeviceListed(String deviceId) async {
    final result = await _shell.runArgs(
      'adb',
      const ['devices'],
      throwOnError: false,
      silent: true,
      timeout: _androidAdbCommandTimeout,
    );
    if (result.exitCode != ExitCode.success.code) {
      return false;
    }
    return result.outLines.any((line) {
      final parts = line.trim().split(RegExp(r'\s+'));
      return parts.isNotEmpty && parts.first == deviceId;
    });
  }

  Future<String?> _androidAvdName(String deviceId) async {
    final result = await _adb(deviceId, const ['emu', 'avd', 'name'], timeout: _androidEmulatorCommandTimeout);
    if (result.exitCode == ExitCode.success.code) {
      for (final line in result.outLines) {
        final name = line.trim();
        if (name.isNotEmpty && name != 'OK') {
          return name;
        }
      }
    }
    final fallback = await _availableAndroidAvdName();
    if (fallback != null) {
      _logger.warn(
        '[android-device] could not query the AVD name from '
        '$deviceId; using the spec AVD "$fallback".',
      );
    }
    return fallback;
  }

  Future<String?> _availableAndroidAvdName() async {
    final result = await _shell.runArgs(
      'emulator',
      const ['-list-avds'],
      throwOnError: false,
      silent: true,
      timeout: _androidEmulatorCommandTimeout,
    );
    if (result.exitCode != ExitCode.success.code) {
      return null;
    }
    final installed = result.outLines.map((line) => line.trim());
    return installed.contains(LocalDeviceSpec.androidAvdName) ? LocalDeviceSpec.androidAvdName : null;
  }

  Future<bool> _waitForAndroidFramework(String deviceId, {int attempts = _androidFrameworkAttempts}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (await _androidFrameworkReady(deviceId)) {
        return true;
      }
      if (attempt < attempts) {
        await getDep<SleepFunction>()(_androidFrameworkPollDelay);
      }
    }
    return false;
  }

  Future<bool> _androidFrameworkReady(String deviceId) async {
    // Right after `adb reboot` the package/activity/service calls can answer while the system is still booting;
    // Gradle then installs mid-boot and the device drops away ("device not found", 2026-10-05 matrix r6).
    final booted = await _adb(deviceId, const ['shell', 'getprop', 'sys.boot_completed']);
    if (!_adbCommandSucceeded(booted) || booted.stdout.trim() != '1') {
      return false;
    }
    final package = await _adb(deviceId, const ['shell', 'cmd', 'package', 'list', 'packages', 'android']);
    if (!_adbCommandSucceeded(package)) {
      return false;
    }
    final activity = await _adb(deviceId, const ['shell', 'cmd', 'activity', 'get-current-user']);
    if (!_adbCommandSucceeded(activity)) {
      return false;
    }
    // AGP's connected test task enumerates every system service before
    // installing; one wedged service hangs that call (and the whole run)
    // even while `package` and `activity` still answer.
    final services = await _adb(deviceId, const ['shell', 'service', 'list'], timeout: _androidServiceListTimeout);
    return _adbCommandSucceeded(services);
  }

  Future<ProcessResultX> _adb(
    String deviceId,
    List<String> arguments, {
    Duration timeout = _androidAdbCommandTimeout,
    Future<void>? cancelOn,
  }) {
    final command = ['-s', deviceId, ...arguments];
    return cancelOn == null
        ? _shell.runArgs('adb', command, throwOnError: false, silent: true, timeout: timeout)
        : _shell.runArgs('adb', command, throwOnError: false, silent: true, timeout: timeout, cancelOn: cancelOn);
  }

  bool _adbCommandSucceeded(ProcessResultX result) {
    if (result.exitCode != ExitCode.success.code) {
      return false;
    }
    final output = '${result.stdout}\n${result.stderr}';
    return !output.contains("Can't find service:");
  }

  bool _isEmulator(String deviceId) => deviceId.startsWith('emulator-');

  bool _isPatchedPatrolCliComplete(Directory patchedPackage) {
    final packageConfig = File(
      p.join(patchedPackage.path, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfig.existsSync()) {
      return false;
    }
    // A copy patched for an older pinned version would otherwise be reused
    // after a patrol_cli bump, so the copied pubspec must match the pin.
    final pubspec = File(p.join(patchedPackage.path, 'pubspec.yaml'));
    if (!pubspec.existsSync() || !_patchedPatrolCliVersionPattern.hasMatch(pubspec.readAsStringSync())) {
      return false;
    }
    final backend = File(
      p.join(patchedPackage.path, 'lib', 'src', 'ios', 'ios_test_backend.dart'),
    );
    if (!backend.existsSync()) {
      return false;
    }
    final androidBackend = File(p.join(
      patchedPackage.path,
      'lib',
      'src',
      'android',
      'android_test_backend.dart',
    ));
    final content = backend.readAsStringSync();
    final androidContent = androidBackend.existsSync() ? androidBackend.readAsStringSync() : '';
    final bundler = File(p.join(patchedPackage.path, 'lib', 'src', 'test_bundler.dart'));
    final bundlerContent = bundler.existsSync() ? bundler.readAsStringSync() : '';
    return content.contains(_fixedPatrolCliSelection) &&
        bundlerContent.contains(_fixedPatrolCliBundleFile) &&
        content.contains(_fixedPatrolCliPhysicalIosFrameworksCall) &&
        androidContent.contains(_fixedPatrolCliAndroidBuild) &&
        androidContent.contains(_fixedPatrolCliAndroidConfigMode);
  }

  /// Prepares the shared repo-local Patrol CLI and returns its direct launcher.
  ///
  /// Args:
  ///   repo: APP root owning the locked, completeness-checked patched copy.
  ///
  /// Returns null when preparation or the existing FVM launcher is unavailable.
  Future<List<String>?> preparePatrolCliCommand(String repo) async {
    final main = await _preparePatchedPatrolCli(repo);
    if (main == null) {
      return null;
    }
    final fvm = _fvmExecutable();
    return fvm == null ? null : [fvm.path, 'dart', main];
  }

  /// Returns the patched patrol_cli entrypoint, run directly with `dart` so
  /// it resolves from its own package config. Launching it through
  /// `pub global run` would need `PUB_CACHE` pointed at the patched cache,
  /// which Patrol's child `flutter` commands inherit: the app's plugins then
  /// resolve from a different cache than prepare's `pub get`, the
  /// `.symlinks/plugins` targets flip, and `pod install` recreates every pod
  /// (a full native rebuild on the next iOS build).
  Future<String?> _preparePatchedPatrolCli(String repo) async {
    final key = p.normalize(p.absolute(repo));
    final pending = _patrolCliPreparations[key];
    if (pending != null) {
      return pending;
    }
    final preparation = _preparePatchedPatrolCliLocked(repo);
    _patrolCliPreparations[key] = preparation;
    try {
      return await preparation;
    } finally {
      unawaited(_patrolCliPreparations.remove(key));
    }
  }

  Future<String?> _preparePatchedPatrolCliLocked(String repo) async {
    final lockFile = File(p.join(repo, '.mplatrol', 'patched_cli.lock'));
    lockFile.parent.createSync(recursive: true);
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      try {
        return await _preparePatchedPatrolCliCopy(repo);
      } finally {
        await lock.unlock();
      }
    } finally {
      await lock.close();
    }
  }

  Future<String?> _preparePatchedPatrolCliCopy(String repo) async {
    final sourcePackage = _patrolCliPackageDir();
    if (sourcePackage == null || !sourcePackage.existsSync()) {
      _logger.err(
        '[patrol-cli-patch] patrol_cli $_patrolCliVersion source '
        'not found. Run `dart pub global activate patrol_cli '
        '$_patrolCliVersion`, then retry local Android/iOS.',
      );
      return null;
    }

    final patchedPackage = Directory(p.join(repo, '.mplatrol', 'patched_packages', 'patrol_cli'));
    final patchedPubCache = p.join(repo, '.mplatrol', 'patched_pub_cache');
    // Local and LT Android share the locked, already-activated copy. Keeping
    // complete copies stable avoids deleting package inputs during another run.
    final patchedMain = p.join(patchedPackage.path, 'bin', 'main.dart');
    if (_isPatchedPatrolCliComplete(patchedPackage)) {
      _logger.info('[patrol-cli-patch] reusing repo-local patched patrol_cli');
      return patchedMain;
    }
    if (patchedPackage.existsSync()) {
      patchedPackage.deleteSync(recursive: true);
    }
    _copyDirectory(sourcePackage, patchedPackage);

    final patchedAndroidBuild = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['android', 'android_test_backend.dart'],
      patchName: 'Android build success marker',
      fixedContent: _fixedPatrolCliAndroidBuild,
      oldContent: _unpatchedPatrolCliAndroidBuild,
    );
    final patchedAndroidConfigMode = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['android', 'android_test_backend.dart'],
      patchName: 'Android config-only build mode',
      fixedContent: _fixedPatrolCliAndroidConfigMode,
      oldContent: _unpatchedPatrolCliAndroidConfigMode,
    );
    final patchedXcTestRun = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['ios', 'ios_test_backend.dart'],
      patchName: 'xctestrun selector',
      fixedContent: _fixedPatrolCliSelection,
      oldContent: _unpatchedPatrolCliSelection,
    );
    final patchedOnlyTesting = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['crossplatform', 'app_options.dart'],
      patchName: 'only-testing filter',
      fixedContent: _fixedPatrolCliOnlyTesting,
      oldContent: _unpatchedPatrolCliOnlyTesting,
    );
    final patchedIosDestination = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['crossplatform', 'app_options.dart'],
      patchName: 'iOS simulator destination',
      fixedContent: _fixedPatrolCliIosDestination,
      oldContent: _unpatchedPatrolCliIosDestination,
    );
    final patchedIosCodesign = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['crossplatform', 'app_options.dart'],
      patchName: 'iOS physical device code signing',
      fixedContent: _fixedPatrolCliIosCodesign,
      oldContent: _unpatchedPatrolCliIosCodesign,
    );
    final patchedIosProvisioningUpdates = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['crossplatform', 'app_options.dart'],
      patchName: 'iOS physical provisioning updates',
      fixedContent: _fixedPatrolCliIosProvisioningUpdates,
      oldContent: _unpatchedPatrolCliIosProvisioningUpdates,
    );
    final patchedXcodebuildFailureOutput = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['ios', 'ios_test_backend.dart'],
      patchName: 'xcodebuild failure output',
      fixedContent: _fixedPatrolCliXcodebuildFailureOutput,
      oldContent: _unpatchedPatrolCliXcodebuildFailureOutput,
    );
    final patchedIosRunnerFrameworksCall = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['ios', 'ios_test_backend.dart'],
      patchName: 'physical iOS runner framework embed call',
      fixedContent: _fixedPatrolCliPhysicalIosFrameworksCall,
      oldContent: _unpatchedPatrolCliPhysicalIosFrameworksCall,
    );
    final patchedIosRunnerFrameworksMethod = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['ios', 'ios_test_backend.dart'],
      patchName: 'physical iOS runner framework embed method',
      fixedContent: _fixedPatrolCliPhysicalIosFrameworksMethod,
      oldContent: _unpatchedPatrolCliPhysicalIosFrameworksMethod,
    );
    final patchedBundleFile = _patchPatrolCliFile(
      packageRoot: patchedPackage.path,
      segments: const ['test_bundler.dart'],
      patchName: 'bundle file name define',
      fixedContent: _fixedPatrolCliBundleFile,
      oldContent: _unpatchedPatrolCliBundleFile,
    );
    if (!patchedAndroidBuild ||
        !patchedAndroidConfigMode ||
        !patchedBundleFile ||
        !patchedXcTestRun ||
        !patchedOnlyTesting ||
        !patchedIosDestination ||
        !patchedIosCodesign ||
        !patchedIosProvisioningUpdates ||
        !patchedXcodebuildFailureOutput ||
        !patchedIosRunnerFrameworksCall ||
        !patchedIosRunnerFrameworksMethod) {
      return null;
    }

    final fvmExecutable = _fvmExecutable();
    if (fvmExecutable == null) {
      return null;
    }
    final activate = await _shell.runArgs(
      'env',
      [
        'PUB_CACHE=$patchedPubCache',
        fvmExecutable.path,
        'dart',
        'pub',
        'global',
        'activate',
        '--source',
        'path',
        patchedPackage.path,
      ],
      workingDirectory: repo,
      throwOnError: false,
      silent: true,
    );
    if (activate.exitCode != ExitCode.success.code) {
      final details = _lastNonEmptyLines(
        '${activate.outText}\n${activate.errText}',
        80,
      ).join('\n');
      _logger.err(
        '[patrol-cli-patch] failed to activate repo-local '
        'patrol_cli (exit ${activate.exitCode}).'
        '${details.isEmpty ? '' : '\n$details'}',
      );
      return null;
    }
    _logger.info('[patrol-cli-patch] using repo-local patched patrol_cli');
    return patchedMain;
  }

  Directory? _patrolCliPackageDir() {
    final pubCache = pubCacheRoot(_platform.environment);
    if (pubCache == null) {
      return null;
    }
    return Directory(p.join(pubCache, 'hosted', 'pub.dev', 'patrol_cli-$_patrolCliVersion'));
  }

  File? _fvmExecutable() {
    final cacheRoot = pubCacheRoot(_platform.environment);
    final path = cacheRoot == null ? null : p.join(cacheRoot, 'bin', 'fvm');
    if (path == null || !File(path).existsSync()) {
      _logger.err(
        '[patrol-cli-patch] FVM executable not found at '
        '${path ?? '<unknown pub cache>'}. Run `dart pub global activate fvm`, '
        'then retry local Android/iOS.',
      );
      return null;
    }
    return File(path);
  }

  void _copyDirectory(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync()) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        entity.copySync(targetPath);
      }
    }
  }

  bool _patchPatrolCliFile({
    required String packageRoot,
    required List<String> segments,
    required String patchName,
    required String fixedContent,
    required String oldContent,
  }) {
    final source = File(p.joinAll([packageRoot, 'lib', 'src', ...segments]));
    if (!source.existsSync()) {
      _logger.err(
        '[patrol-cli-patch] patrol_cli $_patrolCliVersion '
        '$patchName source not found in repo-local copy.',
      );
      return false;
    }
    final content = source.readAsStringSync();
    if (content.contains(fixedContent)) {
      return true;
    }
    if (content.contains(oldContent)) {
      source.writeAsStringSync(content.replaceFirst(oldContent, fixedContent));
      return true;
    }
    _logger.err(
      '[patrol-cli-patch] patrol_cli $_patrolCliVersion '
      '$patchName shape changed; refusing to run local Android/iOS with an '
      'unpatched runner.',
    );
    return false;
  }

  /// Lets local iOS name its own bundle through [patrolTestBundleDefine];
  /// without the define Patrol keeps its shared `test_bundle.dart`.
  static const _unpatchedPatrolCliBundleFile = '''
      : _projectRoot
            .childDirectory(testDirectory)
            .childFile('test_bundle.dart');
''';

  static const _fixedPatrolCliBundleFile = '''
      : _projectRoot
            .childDirectory(testDirectory)
            .childFile(
              const String.fromEnvironment(
                '$patrolTestBundleDefine',
                defaultValue: 'test_bundle.dart',
              ),
            );
''';

  static const _unpatchedPatrolCliAndroidConfigMode = "              '--config-only',\n";
  static const _fixedPatrolCliAndroidConfigMode = "              '--config-only',\n"
      "              '--\${options.buildMode.androidName.toLowerCase()}',\n";

  static const _unpatchedPatrolCliAndroidBuild = '''
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        task.complete('Completed building \$subject');
      } else if (exitCode == exitCodeInterrupted) {
''';

  // This branch is reached only after app assembly AND test assembly succeed.
  static const _fixedPatrolCliAndroidBuild = '''
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        _logger.info('$_androidBuildSuccessMarker');
        task.complete('Completed building \$subject');
      } else if (exitCode == exitCodeInterrupted) {
''';

  static const _unpatchedPatrolCliSelection = '''
    if (absolutePath) {
      return files.first.absolute.path;
    }
    return files.first.path;
''';

  static const _fixedPatrolCliSelection = '''
    // $_patrolCliPatchMarker
    final completeFiles = files.whereType<File>().where((file) {
      try {
        final content = file.readAsStringSync();
        return content.contains('<key>TestBundlePath</key>') &&
            content.contains('<key>TestHostPath</key>');
      } catch (_) {
        return false;
      }
    }).toList();
    final selected = completeFiles.isEmpty ? files.first : completeFiles.first;

    if (absolutePath) {
      return selected.absolute.path;
    }
    return selected.path;
''';

  /// mplatrol's generated runtime runner puts its tests in `LoginE2ETests`, not
  /// upstream's `RunnerUITests` class (see ios_patrol_runner.dart).
  static const _unpatchedPatrolCliOnlyTesting = '''
      else if (!staticRunner) ...[
        '-only-testing',
        'RunnerUITests/RunnerUITests',
      ],
''';

  static const _fixedPatrolCliOnlyTesting = '''
      else if (!staticRunner) ...[
        '-only-testing',
        'RunnerUITests/LoginE2ETests',
      ],
''';

  /// Upstream already targets the simulator by id but still appends
  /// `OS=$osVersion`, which defaults to `latest` and fails to match a picked
  /// simulator on an older runtime; the id alone is unambiguous.
  static const _unpatchedPatrolCliIosDestination = '''
    final destination = device.real
        ? 'platform=iOS,id=\${device.id}'
        : 'platform=iOS Simulator,id=\${device.id},OS=\$osVersion';
''';

  static const _fixedPatrolCliIosDestination = '''
    final destination = device.real
        ? 'platform=iOS,id=\${device.id}'
        : 'platform=iOS Simulator,id=\${device.id}';
''';

  static const _unpatchedPatrolCliIosCodesign = "        '--no-codesign',\n";

  static const _fixedPatrolCliIosCodesign = "        if (simulator) '--no-codesign',\n";

  static const _unpatchedPatrolCliIosProvisioningUpdates = '''
      ...['-sdk', if (simulator) 'iphonesimulator' else 'iphoneos'],
      ...[
        '-destination',
        'generic/platform=\${simulator ? 'iOS Simulator' : 'iOS'}',
      ],
      '-quiet',
''';

  static const _fixedPatrolCliIosProvisioningUpdates = '''
      ...['-sdk', if (simulator) 'iphonesimulator' else 'iphoneos'],
      if (!simulator) '-allowProvisioningUpdates',
      if (!simulator) 'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES',
      ...[
        '-destination',
        'generic/platform=\${simulator ? 'iOS Simulator' : 'iOS'}',
      ],
      '-quiet',
''';

  static const _unpatchedPatrolCliXcodebuildFailureOutput = '''
      process.listenStdOut((l) => _logger.detail('\\t\$l')).disposedBy(scope);
      process.listenStdErr((l) => _logger.err('\\t\$l')).disposedBy(scope);
      exitCode = await process.exitCode;
      if (exitCode == 0) {
        task.complete('Completed building \$subject');
      } else if (exitCode == _xcodebuildInterrupted) {
        const cause = 'xcodebuild was interrupted';
        task.fail('Failed to execute tests of \$subject (\$cause)');
        throwToolInterrupted(cause);
      } else {
        final cause = 'xcodebuild exited with code \$exitCode';
        task.fail('Failed to build \$subject (\$cause)');
        throwToolExit(cause);
      }
''';

  static const _fixedPatrolCliXcodebuildFailureOutput = '''
      final xcodebuildOutput = <String>[];
      process
          .listenStdOut((l) {
            xcodebuildOutput.add(l);
            _logger.detail('\\t\$l');
          })
          .disposedBy(scope);
      process
          .listenStdErr((l) {
            xcodebuildOutput.add(l);
            _logger.err('\\t\$l');
          })
          .disposedBy(scope);
      exitCode = await process.exitCode;

      if (exitCode == 0) {
        task.complete('Completed building \$subject');
      } else if (exitCode == _xcodebuildInterrupted) {
        const cause = 'xcodebuild was interrupted';
        task.fail('Failed to execute tests of \$subject (\$cause)');
        throwToolInterrupted(cause);
      } else {
        final cause = 'xcodebuild exited with code \$exitCode';
        final failureLines = xcodebuildOutput.where((line) {
          final normalizedLine = line.toLowerCase();
          return normalizedLine.contains('error:') ||
              normalizedLine.contains('no profiles') ||
              normalizedLine.contains('no profile') ||
              normalizedLine.contains('provisioning') ||
              normalizedLine.contains('automatic signing') ||
              normalizedLine.contains('conflicting provisioning') ||
              normalizedLine.contains('no accounts') ||
              normalizedLine.contains('requires a provisioning profile') ||
              normalizedLine.contains('development team') ||
              normalizedLine.contains('codesign') ||
              normalizedLine.contains('code sign') ||
              normalizedLine.contains('test build failed') ||
              normalizedLine.contains('build commands failed');
        }).toList();
        final nonEmptyLines = xcodebuildOutput
            .where((line) => line.trim().isNotEmpty)
            .toList(growable: false);
        final visibleFailureLines = failureLines.isNotEmpty
            ? failureLines
            : nonEmptyLines.skip(
                nonEmptyLines.length > 80 ? nonEmptyLines.length - 80 : 0,
              );
        if (visibleFailureLines.isNotEmpty) {
          _logger.err('xcodebuild failure details:');
          for (final line in visibleFailureLines.take(80)) {
            _logger.err('\\t\$line');
          }
        }
        task.fail('Failed to build \$subject (\$cause)');
        throwToolExit(cause);
      }
''';

  static const _unpatchedPatrolCliPhysicalIosFrameworksCall = '''
      if (exitCode == 0) {
        task.complete('Completed building \$subject');
      } else if (exitCode == _xcodebuildInterrupted) {
''';

  static const _fixedPatrolCliPhysicalIosFrameworksCall = '''
      if (exitCode == 0) {
        if (isRealDevice) {
          await _embedPhysicalIosRunnerFrameworks();
        }
        _logger.info('$_iosBuildSuccessMarker');
        task.complete('Completed building \$subject');
      } else if (exitCode == _xcodebuildInterrupted) {
''';

  static const _unpatchedPatrolCliPhysicalIosFrameworksMethod = '''
  /// Executes the tests of the given [options] on the given [device].
''';

  static const _fixedPatrolCliPhysicalIosFrameworksMethod = '''
  Future<void> _embedPhysicalIosRunnerFrameworks() async {
    final productsDir = _rootDirectory
        .childDirectory('build')
        .childDirectory('ios_integ')
        .childDirectory('Build')
        .childDirectory('Products')
        .childDirectory('Release-iphoneos');
    final appFrameworks = productsDir
        .childDirectory('Runner.app')
        .childDirectory('Frameworks');
    final runnerApp = productsDir.childDirectory('RunnerUITests-Runner.app');
    final runnerFrameworks = runnerApp.childDirectory('Frameworks')
      ..createSync(recursive: true);
    if (!appFrameworks.existsSync() || !runnerApp.existsSync()) {
      _logger.warn(
        'Skipping physical iOS runner framework embed; build products '
        'were not found.',
      );
      return;
    }

    final copiedCode = <String>[];
    for (final entry in appFrameworks.listSync()) {
      final name = entry.path.split('/').last;
      if (!name.endsWith('.framework') && !name.endsWith('.dylib')) {
        continue;
      }
      final destination = join(runnerFrameworks.path, name);
      final copyResult = await _processManager.run(
        ['ditto', entry.path, destination],
        runInShell: true,
      );
      if (copyResult.exitCode != 0) {
        throwToolExit('Failed to embed \$name in the iOS test runner host.');
      }
      copiedCode.add(destination);
    }

    final identity = await _firstCodeSigningAuthority(runnerApp.path);
    if (identity == null) {
      throwToolExit(
        'Could not determine the iOS runner code-signing identity after '
        'framework embedding.',
      );
    }
    for (final path in copiedCode) {
      final signResult = await _processManager.run(
        ['codesign', '--force', '--sign', identity, path],
        runInShell: true,
      );
      if (signResult.exitCode != 0) {
        throwToolExit('Failed to sign embedded runner framework \$path.');
      }
    }
    final signRunner = await _processManager.run(
      [
        'codesign',
        '--force',
        '--sign',
        identity,
        '--preserve-metadata=identifier,entitlements,flags',
        runnerApp.path,
      ],
      runInShell: true,
    );
    if (signRunner.exitCode != 0) {
      throwToolExit('Failed to re-sign the iOS test runner host.');
    }
    _logger.detail(
      'Embedded Runner.app frameworks into the physical iOS test runner host.',
    );
  }

  Future<String?> _firstCodeSigningAuthority(String bundlePath) async {
    final result = await _processManager.run(
      ['codesign', '-d', '--verbose=4', bundlePath],
      runInShell: true,
    );
    final output = '\${result.stdOut}\\n\${result.stdErr}';
    for (final line in output.split('\\n')) {
      if (!line.startsWith('Authority=')) {
        continue;
      }
      final authority = line.substring('Authority='.length).trim();
      if (authority.isEmpty ||
          authority == 'Apple Root CA' ||
          authority.contains('Developer Relations')) {
        continue;
      }
      return authority;
    }
    return null;
  }

  /// Executes the tests of the given [options] on the given [device].
''';

  /// patrol's app-target flag plus the matching `PATROL_APP_*` dart-define the
  /// test reads for native automation. The Makefile passes both explicitly —
  /// patrol does not reliably bake the dart-define for `patrol test`, and
  /// without it the native automator has no package/bundle to drive.
  bool _isCoreSimulatorDeviceId(String deviceId) {
    final pattern = RegExp(
      '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
      r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
    );
    return pattern.hasMatch(deviceId);
  }

  List<String> _idArgs({
    required bool isAndroid,
    required String? appId,
    required bool localIosSimulator,
  }) {
    if (appId == null || appId.isEmpty) {
      return const [];
    }
    return isAndroid
        ? ['--package-name', appId, '--dart-define=PATROL_APP_PACKAGE_NAME=$appId']
        : [
            '--bundle-id',
            appId,
            '--dart-define=PATROL_APP_BUNDLE_ID=$appId',
            if (localIosSimulator) '--dart-define=MPLATROL_E2E_LOCAL_IOS_SIMULATOR=true',
          ];
  }

  List<String> _idDefines({
    required bool isAndroid,
    required String? appId,
    required bool localIosSimulator,
  }) {
    if (appId == null || appId.isEmpty) {
      return const [];
    }
    return [
      if (isAndroid)
        'PATROL_APP_PACKAGE_NAME=$appId'
      else ...[
        'PATROL_APP_BUNDLE_ID=$appId',
        if (localIosSimulator) 'MPLATROL_E2E_LOCAL_IOS_SIMULATOR=true',
      ],
    ];
  }

  /// iOS Runner `PRODUCT_BUNDLE_IDENTIFIER` via `xcodebuild` (best-effort).
  Future<String?> _readIosBundleId(String repo) async {
    final workspace = p.join(repo, 'ios', 'Runner.xcworkspace');
    final result = await _shell.run(
      'xcodebuild -showBuildSettings -workspace $workspace -scheme Runner '
      '-configuration Debug',
      throwOnError: false,
      silent: true,
    );
    if (result.exitCode != ExitCode.success.code) {
      return null;
    }
    for (final line in result.outLines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('PRODUCT_BUNDLE_IDENTIFIER = ')) {
        final value = trimmed.split(' = ').last.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }
}
