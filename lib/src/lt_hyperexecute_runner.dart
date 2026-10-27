import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/android_instrumentation_verdict.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_app_upload.dart';
import 'package:mplatrol/src/lt_dashboard_links.dart';
import 'package:mplatrol/src/lt_device_matrix.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_hyperexecute_scenario_logs.dart';
import 'package:mplatrol/src/lt_hyperexecute_stall_watchdog.dart';
import 'package:mplatrol/src/lt_instrumentation_log.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:mplatrol/src/lt_native_annotation.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/lt_session_artifacts.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/lt_user_session_cap.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:path/path.dart' as p;

/// Env var: HyperExecute task retries for every failed task (default 0, no task retries); set e.g. 2 to opt
/// in. Real journey failures are never retried by default; only LambdaTest infrastructure failures are, once
/// (see [e2eInfraRetryEnv]).
const e2eMaxRetriesEnv = 'MPLATROL_E2E_MAX_RETRIES';

/// Env var overriding `it.lt-ios-max-parallel`: the most LambdaTest iOS devices
/// one device job holds at once (see [LtHyperexecuteRunner.runIos]).
const ltIosMaxParallelEnv = 'MPLATROL_LT_IOS_MAX_PARALLEL';

/// Env var: the local port of the iOS shard coordinator. The iOS build
/// compiles the coordinator URL in, so a fixed port per tenant lets later runs
/// (in any checkout) reuse an upload; unset, the OS assigns a port per run.
const iosShardCoordinatorPortEnv = 'MPLATROL_IOS_SHARD_COORDINATOR_PORT';

/// Env var overriding `it.lt-android-max-parallel`: the most LambdaTest Android
/// devices one device job holds at once (see [LtHyperexecuteRunner.runAndroid]).
const ltAndroidMaxParallelEnv = 'MPLATROL_LT_ANDROID_MAX_PARALLEL';

/// A job or wave waits for at least this many free sessions of the
/// machine-wide budget (or all it wants, when fewer) before it starts.
const _minimumSessionGrant = 5;

/// Runs the LambdaTest real-device E2Es through HyperExecute: one job per
/// platform and device (see [runOnEachLtDevice]), with HyperExecute shard/task
/// names carrying the individual test names. The older LtAndroidRunner/LtIosRunner still own build/upload/package
/// mechanics; this class owns the HyperExecute YAML + CLI invocation. The tests a LambdaTest infrastructure
/// failure kept from a result run once more, and only that retry is reported.
class LtHyperexecuteRunner with LtRunSupport {
  LtHyperexecuteRunner({
    this.pollDelay = const Duration(seconds: 2),
    this.deviceJobSpacing = const Duration(seconds: 20),
    this.tunnelRetryDelay = const Duration(seconds: 15),
    HyperexecuteStallWatchdog? stallWatchdog,
    LtSlotBudget? slotBudget,
  })  : _stallWatchdog = stallWatchdog ?? HyperexecuteStallWatchdog(),
        _injectedSlotBudget = slotBudget;

  @override
  final Duration pollDelay;

  /// Gap between the starts of concurrent per-device Android jobs, to stay
  /// under LambdaTest's per-account API rate limit (see [runOnEachLtDevice]).
  final Duration deviceJobSpacing;

  /// Wait before the one retry of a job whose tunnel failed to start.
  final Duration tunnelRetryDelay;

  final HyperexecuteStallWatchdog _stallWatchdog;

  /// The machine-wide session budget; when null, the one from the environment
  /// (see [LtSlotBudget.fromEnvironment]).
  final LtSlotBudget? _injectedSlotBudget;
  LtSlotBudget? _slotBudget;

  /// Zone key of the [_UserLeg] of the leg running in the zone (see [_asUserLeg]).
  static final _userLegKey = Object();

  /// The leg running in the current zone; null outside [runAndroid] and [runIos].
  _UserLeg? get _userLeg => Zone.current[_userLegKey] as _UserLeg?;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  FileSystem get _fileSystem => getDep<FileSystem>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();
  ItRunResults get _results => getDep<ItRunResults>();
  ItRunStop get _stop => getDep<ItRunStop>();

  /// HyperExecute task retry count from [e2eMaxRetriesEnv] (clamped to >= 0),
  /// falling back to [whenUnset] when the env var is absent/blank/non-numeric.
  int _retriesFromEnv(int whenUnset) {
    final parsed = int.tryParse((_platform.environment[e2eMaxRetriesEnv] ?? '').trim()) ?? whenUnset;
    return parsed < 0 ? 0 : parsed;
  }

  /// Android task retries — default 0; explicit environment opt-in is preserved.
  /// Tests that pass only on retry are reported by [_warnTestsPassedOnRetry].
  int get _maxRetries => _retriesFromEnv(0);

  /// iOS task retries — default 0.
  ///
  /// HyperExecute iOS does not reliably expose the shard name to XCTest in this
  /// generated runner, so the local coordinator assigns one method to each
  /// session. Retrying a failed task would create a new session after all
  /// methods were already assigned; that extra session must not be allowed to
  /// turn a real failed method into a green empty retry.
  int get _iosMaxRetries => _retriesFromEnv(0);

  /// Runs the `lt-android` leg as one leg of its test users' session cap (see [_asUserLeg]).
  Future<int> runAndroid({
    required String? target,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String? tenantLabel,
    String? environmentLabel,
    bool reuseLast = false,
  }) =>
      _asUserLeg(
          tenantLabel == null ? 'lt-android' : '$tenantLabel:lt-android',
          () => _runAndroid(
              target: target,
              devices: devices,
              idleTimeoutSeconds: idleTimeoutSeconds,
              env: env,
              targetRegex: targetRegex,
              sdk: sdk,
              tenantLabel: tenantLabel,
              environmentLabel: environmentLabel,
              reuseLast: reuseLast));

  Future<int> _runAndroid({
    required String? target,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String? tenantLabel,
    String? environmentLabel,
    bool reuseLast = false,
  }) async {
    final missing = _missing(env, _androidRequiredEnv);
    if (missing.isNotEmpty) {
      _logger.err(
        'Missing required environment values for HyperExecute '
        'Android: ${missing.join(', ')}',
      );
      return ExitCode.config.code;
    }
    if (devices.isEmpty) {
      _logger.err('No LambdaTest Android devices supplied.');
      return ExitCode.usage.code;
    }
    final maxParallel = _maxParallel(
        ltAndroidMaxParallelEnv, 'it.lt-android-max-parallel', getDep<MplatrolConfig>().it.ltAndroidMaxParallel);
    if (maxParallel == null || !_resolveSlotBudget(env)) {
      return ExitCode.usage.code;
    }

    final repo = _fileSystem.getAppDirectory().path;
    final buildName =
        env['LT_BUILD_NAME'] ?? await _fallbackBuildName(prefix: 'LoginE2EAndroid', workingDirectory: repo);
    final artifacts = targetRegex == null && sdk == null
        ? await getDep<LtAndroidRunner>().buildUploadAndroid(
            repo: repo,
            target: target,
            buildName: buildName,
            auth: '${env['LT_USERNAME']!}:${env['LT_ACCESS_KEY']!}',
            env: env,
            reuseLast: reuseLast,
            tenant: tenantLabel,
          )
        : await getDep<LtAndroidRunner>().buildUploadAndroid(
            repo: repo,
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            buildName: buildName,
            auth: '${env['LT_USERNAME']!}:${env['LT_ACCESS_KEY']!}',
            env: env,
            reuseLast: reuseLast,
            tenant: tenantLabel,
          );
    if (artifacts == null) {
      return reuseLast ? ExitCode.usage.code : ExitCode.software.code;
    }
    final selected =
        _androidArtifactSelection(artifacts, repo: repo, target: target, targetRegex: targetRegex, sdk: sdk);
    if (selected == null) {
      return ExitCode.unavailable.code;
    }
    final jobRoot = await _releaseCheckout(repo, env, 'android');

    final _AndroidRunPlan plan = (
      jobRoot: jobRoot,
      env: env,
      artifacts: artifacts,
      selected: selected,
      idleTimeoutSeconds: idleTimeoutSeconds,
      maxParallel: maxParallel,
      tenantLabel: tenantLabel,
      environmentLabel: environmentLabel,
      captureNetwork: _capturesNetwork(repo, artifacts.selection!, 'Android'),
    );
    return runOnEachLtDevice(
      platform: 'Android',
      repo: jobRoot,
      devices: devices,
      buildName: buildName,
      logger: _logger,
      startSpacing: deviceJobSpacing,
      runJob: (job) => _results.withDevice(job.device, () => _runAndroidDeviceJob(job, plan)),
    );
  }

  /// Runs one device's Android job over every selected test, then once more over the tests a LambdaTest
  /// infrastructure failure kept from a result (see [_retryInfraFailures]). The retry reuses the uploaded app
  /// and test APKs and selects its tests with a HyperExecute `class#method` filter.
  Future<int> _runAndroidDeviceJob(LtDeviceJobSpec job, _AndroidRunPlan plan) async {
    _recordSelection(
        plan.artifacts.selection!,
        (file, test) => ItSelectedTest(
            id: androidLtNativeIdentity(file.basename, test.method),
            file: file.basename,
            description: test.description));
    final code = await _runAndroidJob(job, plan, tests: plan.selected, buildName: job.buildName);
    return _retryInfraFailures(
        code,
        'Android ${job.device}',
        (tests) => _runAndroidJob(job, plan,
            tests: tests.toSet(), buildName: '${job.buildName}_retry', yamlName: 'retry-hyperexecute-lt-android.yaml'));
  }

  /// One HyperExecute Android job over [tests] (native identities), with the device sessions it leases. A job
  /// over fewer than every selected test lists them in a `class#method` filter.
  Future<int> _runAndroidJob(LtDeviceJobSpec job, _AndroidRunPlan plan,
      {required Set<String> tests, required String buildName, String yamlName = 'hyperexecute-lt-android.yaml'}) async {
    final lease = await _leaseSessions(min(tests.length, plan.maxParallel), buildName);
    _logger.info('[lt-sessions] Android $buildName: ${lease.slots} device session(s) for '
        '${tests.length} selected test(s)');
    try {
      return await _runHyperexecuteJob(
        repo: job.workDir,
        yamlPath: _jobYamlPath(plan.jobRoot, job, yamlName),
        env: _jobEnv(plan.jobRoot, job, plan.env),
        label: 'Android',
        tenantLabel: plan.tenantLabel,
        environmentLabel: plan.environmentLabel,
        yaml: _androidYaml(
          buildName: buildName,
          appId: plan.artifacts.appId,
          testSuiteAppId: plan.artifacts.testSuiteAppId,
          devices: ltDevicePool(job.device),
          idleTimeoutSeconds: plan.idleTimeoutSeconds,
          concurrency: lease.slots,
          tenantLabel: plan.tenantLabel,
          environmentLabel: plan.environmentLabel,
          onlyTests: tests.length == plan.selected.length ? null : tests,
          captureNetwork: plan.captureNetwork,
        ),
        diagnosticsBuildName: buildName,
        expectedNativeTests: tests,
      );
    } finally {
      await lease.release();
    }
  }

  /// Whether [e2eInfraRetryEnv] leaves the infrastructure retry on.
  bool get _infraRetryEnabled => ltInfraRetryEnabled(_platform.environment);

  /// Retries once, through [rerun], the current device job's tests a LambdaTest infrastructure failure
  /// (`lt-tunnel-err`, `lt-failure`) kept from a result, after a job that ended with [code]; their retry
  /// alone decides their result (see [ItRunResults.beginRetry]). Returns [code] when nothing is retried;
  /// else the retry's code, or, when another test of the job did not pass either, the worse of both (a real
  /// failure wins over NOT VERIFIED). Nothing is retried outside a leg of `mplatrol run`.
  Future<int> _retryInfraFailures(int code, String label, Future<int> Function(List<String> tests) rerun) async {
    final retry = code == ExitCode.success.code || !_infraRetryEnabled ? const <String>[] : _results.retryableTests();
    if (retry.isEmpty) {
      return code;
    }
    final othersPassed = _passedExcept(retry);
    _logger.warn('[retry] $label: retrying ${retry.length} test(s) once after a LambdaTest infrastructure '
        'failure; only the retry is reported.');
    for (final MapEntry(key: test, value: note) in _results.beginRetry(retry).entries) {
      _logger.info('[retry] $test: $note');
    }
    await Future<void>.delayed(tunnelRetryDelay);
    final retryCode = await rerun(retry);
    _logRetrySummary(label, retry);
    final codes = [if (!othersPassed) code, retryCode];
    return codes.firstWhere((value) => value != ExitCode.success.code && value != ExitCode.unavailable.code,
        orElse: () => ltFirstNonSuccess(codes));
  }

  /// Whether every test of the current device job except [retried] passed, skipped itself with a reason or
  /// was not selected.
  bool _passedExcept(List<String> retried) => _results.currentDeviceResults().entries.every((entry) =>
      retried.contains(entry.key) || entry.value.outcome.passed || entry.value.explainedSkip || !entry.value.selected);

  /// Logs how the retried tests ended: `[retry] <label>: retried N infra failure(s): M passed, K still failing.`
  void _logRetrySummary(String label, List<String> retried) {
    final results = _results.currentDeviceResults();
    final passed = retried.where((test) => results[test]?.outcome.passed ?? false).length;
    final message = '[retry] $label: retried ${retried.length} infra failure(s): $passed passed, '
        '${retried.length - passed} still failing.';
    if (passed == retried.length) {
      _logger.info(message);
    } else {
      _logger.warn(message);
    }
  }

  /// Tells the leg its artifacts are uploaded (see [ItLegDir.release]) and
  /// returns where its [platform] HyperExecute jobs run (see [ItLegDir.jobRoot]).
  Future<String> _releaseCheckout(String repo, Map<String, String> env, String platform) async {
    final leg = getDep<ItLegDir>();
    await leg.release(repo: repo, env: env);
    final root = leg.jobRoot(repo, platform);
    Directory(root).createSync(recursive: true);
    return root;
  }

  /// Registers the tests [selection] selected for the current device job,
  /// and the tests it excluded as NOT RUN with the exclusion reason.
  void _recordSelection(PatrolSelectionPlan selection, ItSelectedTest? Function(PatrolTestFile, PatrolTest) test) {
    _results.selectTests([
      for (final file in selection.files)
        for (final patrolTest in file.tests) test(file, patrolTest),
    ].whereType<ItSelectedTest>());
    for (final excluded in selection.excluded) {
      _results.excludeTest(file: excluded.file, description: excluded.description, reason: excluded.reason);
    }
  }

  /// Runs the `lt-ios` leg as one leg of its test users' session cap (see [_asUserLeg]).
  Future<int> runIos({
    required String? target,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String? tenantLabel,
    String? environmentLabel,
    bool reuseLast = false,
  }) =>
      _asUserLeg(
          tenantLabel == null ? 'lt-ios' : '$tenantLabel:lt-ios',
          () => _runIos(
              target: target,
              devices: devices,
              idleTimeoutSeconds: idleTimeoutSeconds,
              env: env,
              targetRegex: targetRegex,
              sdk: sdk,
              tenantLabel: tenantLabel,
              environmentLabel: environmentLabel,
              reuseLast: reuseLast));

  Future<int> _runIos({
    required String? target,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String? tenantLabel,
    String? environmentLabel,
    bool reuseLast = false,
  }) async {
    final missing = _missing(env, _iosRequiredEnv);
    if (missing.isNotEmpty) {
      _logger.err(
        'Missing required environment values for HyperExecute iOS: '
        '${missing.join(', ')}',
      );
      return ExitCode.config.code;
    }
    if (devices.isEmpty) {
      _logger.err('No LambdaTest iOS devices supplied.');
      return ExitCode.usage.code;
    }
    if (devices.length > 1 && (env['MPLATROL_IOS_SHARD_COORDINATOR_URL'] ?? '').trim().isNotEmpty) {
      _logger.err(
        'MPLATROL_IOS_SHARD_COORDINATOR_URL points at an external coordinator '
        'that assigns each shard once, so it cannot serve '
        '${devices.length} LambdaTest iOS devices. Unset it or pass one '
        '--device.',
      );
      return ExitCode.usage.code;
    }

    final repo = _fileSystem.getAppDirectory().path;
    final selection = _planIosSelection(repo, target: target, targetRegex: targetRegex, sdk: sdk, tenant: tenantLabel);
    if (selection == null) {
      return ExitCode.config.code;
    }
    final shards = iosTestShards(
      repo,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env,
      selection: selection,
    );
    final dartNames =
        _discoverIosDartNames(repo, selection: selection, target: target, targetRegex: targetRegex, sdk: sdk);
    if (shards.isEmpty) {
      _logger.err('No iOS Patrol test shards discovered.');
      return ExitCode.usage.code;
    }
    final maxParallel = _iosMaxParallel(shards.length, env);
    if (maxParallel == null || !_resolveSlotBudget(env) || !_externalCoordinatorFitsLeases(shards.length, env)) {
      return ExitCode.usage.code;
    }
    final buildName = env['LT_BUILD_NAME'] ?? await _fallbackBuildName(prefix: 'LoginE2EiOS', workingDirectory: repo);
    _IosShardCoordinator? coordinator;
    try {
      coordinator = await _startIosCoordinator(shards, env);
      if (!await _iosCoordinatorReady(coordinator)) {
        return ExitCode.unavailable.code;
      }
      final artifacts = await getDep<LtIosRunner>().buildIosForHyperexecute(
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        env: env,
        reuseLast: reuseLast,
        shards: shards,
        selection: selection,
        selectionCoordinatorUrl: _iosCoordinatorUrl(coordinator, env),
      );
      if (artifacts == null) {
        return ExitCode.software.code;
      }
      final jobRoot = await _releaseCheckout(repo, env, 'ios');

      final _IosRunPlan plan = (
        repo: jobRoot,
        env: env,
        artifacts: artifacts,
        idleTimeoutSeconds: idleTimeoutSeconds,
        shards: shards,
        dartNames: dartNames,
        selection: selection,
        coordinator: coordinator,
        maxParallel: maxParallel,
        tenantLabel: tenantLabel,
        environmentLabel: environmentLabel,
        captureNetwork: _capturesNetwork(repo, selection, 'iOS'),
      );
      return await runOnEachLtDevice(
        platform: 'iOS',
        repo: jobRoot,
        devices: devices,
        buildName: buildName,
        logger: _logger,
        // One job at a time: the single coordinator URL is compiled into the
        // runner and its requests do not identify the device, so concurrent
        // jobs would split one shard set across devices. See
        // [_IosShardCoordinator.reset].
        maxConcurrent: 1,
        runJob: (job) => _results.withDevice(job.device, () => _runIosDeviceJob(job, plan)),
      );
    } finally {
      await coordinator?.close();
    }
  }

  /// Plans the iOS SDK selection once so shards, Dart names, the generated
  /// runner and the compiled bundle all agree on the same journeys. Returns
  /// null (after logging) when the plan is refused; an empty plan falls through
  /// to the "no shards" usage error.
  PatrolSelectionPlan? _planIosSelection(
    String repo, {
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required String? tenant,
  }) {
    try {
      final selection = planPatrolSdkSelection(repo,
          platform: 'ios', target: target, targetRegex: targetRegex, sdk: sdk, tenant: tenant);
      _logger.info('[sdk-selection] iOS selected=${selection.selectedCount} '
          'excluded=${selection.excludedCount} (registrations, not coverage certification)');
      for (final excluded in selection.excluded) {
        _logger.info('[sdk-excluded] iOS ${excluded.file}: ${excluded.reason}');
      }
      return selection;
      // Preparation APIs report absent/stale evidence as StateError.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _logger.err('iOS SDK selection refused: ${error.message}');
      return null;
    }
  }

  /// Dart test names of the selected journeys. The iOS build compiles the same
  /// selection into its own bundle, grouping each file's tests under the file
  /// basename, so every name is `<file basename> <description>`.
  Map<String, Set<String>> _discoverIosDartNames(
    String repo, {
    required PatrolSelectionPlan selection,
    String? target,
    String? targetRegex,
    String? sdk,
  }) {
    final names = <String, Set<String>>{};
    for (final file
        in discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex, sdk: sdk, selection: selection)) {
      for (final test in file.tests) {
        names.putIfAbsent(test.description, () => <String>{}).add('${file.basename} ${test.description}');
      }
    }
    return names;
  }

  /// The most iOS devices one device job may hold at once:
  /// [ltIosMaxParallelEnv] when set, else `it.lt-ios-max-parallel`. Null
  /// (after logging) for a non-positive value, or when [shardCount] needs
  /// several waves but an external coordinator, which cannot be limited to one
  /// wave's shards, is configured.
  int? _iosMaxParallel(int shardCount, Map<String, String> env) {
    final value =
        _maxParallel(ltIosMaxParallelEnv, 'it.lt-ios-max-parallel', getDep<MplatrolConfig>().it.ltIosMaxParallel);
    if (value == null) {
      return null;
    }
    if (shardCount > value && (env['MPLATROL_IOS_SHARD_COORDINATOR_URL'] ?? '').trim().isNotEmpty) {
      _logger.err('$shardCount iOS shards need waves of at most $value devices, '
          'but MPLATROL_IOS_SHARD_COORDINATOR_URL points at an external '
          'coordinator that cannot be limited to one wave. Unset it, or set '
          '$ltIosMaxParallelEnv to at least $shardCount.');
      return null;
    }
    return value;
  }

  /// The most devices one device job may hold: [envName] when set, else the
  /// [configured] `mplatrol.yaml` value of [key]. Null (after logging) for a
  /// value that is not a positive whole number.
  int? _maxParallel(String envName, String key, int configured) {
    final raw = (_platform.environment[envName] ?? '').trim();
    final value = raw.isEmpty ? configured : int.tryParse(raw);
    if (value == null || value < 1) {
      _logger.err('$envName / $key must be a '
          'positive whole number of devices (got "${raw.isEmpty ? value : raw}").');
      return null;
    }
    return value;
  }

  /// Resolves the machine-wide session budget and the per-user cap of the users [runEnv] signs in as. False
  /// (after logging) when [ltMaxConcurrentSessionsEnv] or [ltSessionsPerUserEnv] is not a positive whole number.
  bool _resolveSlotBudget(Map<String, String> runEnv) {
    try {
      final env = _platform.environment;
      _slotBudget = _injectedSlotBudget ?? LtSlotBudget.fromEnvironment(env, _logger);
      _userLeg?.join(LtUserSessionCap.fromEnvironment(env, runEnv, _logger));
      return true;
    } on FormatException catch (error) {
      _logger.err(error.message);
      return false;
    }
  }

  /// Whether an external coordinator's [shardCount] shards, which run on that many sessions at once (see
  /// [_iosMaxParallel]), fit the per-user cap and the machine-wide budget; false after logging when not.
  bool _externalCoordinatorFitsLeases(int shardCount, Map<String, String> env) {
    final limit = min(_userLeg?.cap?.budget.limit ?? shardCount, _slotBudget?.limit ?? shardCount);
    if (shardCount <= limit || (env['MPLATROL_IOS_SHARD_COORDINATOR_URL'] ?? '').trim().isEmpty) {
      return true;
    }
    _logger.err('$shardCount iOS shards run at once with the external coordinator in '
        'MPLATROL_IOS_SHARD_COORDINATOR_URL, more than the $limit LambdaTest sessions this run may hold '
        '($ltSessionsPerUserEnv per test user, $ltMaxConcurrentSessionsEnv machine-wide). Unset it, '
        'or select at most $limit tests.');
    return false;
  }

  /// Leases up to [wanted] device sessions for the job [label] from the
  /// machine-wide budget, waiting for at least [_minimumSessionGrant] (or
  /// [wanted], when fewer or [waitForAll]) to be free; all of [wanted] without
  /// a budget. With a per-user cap, its lease comes first and bounds both
  /// [wanted] and that minimum (see [LtUserSessionCap.lease]).
  ///
  /// Once the run is stopping ([ItRunStop]), no job starts: this throws [LtSlotWaitCancelled], also for a job
  /// still waiting, and [_asUserLeg] ends the leg.
  Future<LtSlotLease> _leaseSessions(int wanted, String label, {bool waitForAll = false}) async {
    if (_stop.isStopping) {
      throw LtSlotWaitCancelled(label);
    }
    Future<LtSlotLease> machine(int count, int minimum) async {
      final budget = _slotBudget;
      if (budget == null) {
        return LtSlotLease.unbudgeted(count);
      }
      return budget.acquire(wanted: count, label: label, minimum: minimum, cancel: _stop.requested);
    }

    final minimum = waitForAll ? wanted : min(wanted, _minimumSessionGrant);
    final cap = _userLeg?.cap;
    final present = _userLeg?.present;
    if (cap == null || present == null) {
      return machine(wanted, minimum);
    }
    return cap.lease(
        wanted: wanted, label: label, minimum: minimum, leg: present, machine: machine, cancel: _stop.requested);
  }

  /// Runs [body] as the LambdaTest leg [label]: once [_resolveSlotBudget] found its test users' session cap,
  /// the leg is present in it (counted for every share, also while it builds) until [body] ends, and
  /// [_leaseSessions] leases as that leg. A zone, because `lt-all` runs both legs at once on this runner.
  Future<int> _asUserLeg(String label, Future<int> Function() body) {
    final leg = _UserLeg(label);
    return runZoned(() async {
      try {
        return await body();
      } on LtSlotWaitCancelled catch (cancelled) {
        // Only a stopping run cancels a lease (see [_leaseSessions]).
        _logger.warn('[it-run] $label stopped before ${cancelled.label} started; its tests are NOT RUN.');
        return _stop.exitCode;
      } finally {
        await leg.present?.leave();
      }
    }, zoneValues: {_userLegKey: leg});
  }

  /// Runs one device's iOS job as consecutive HyperExecute waves of at most
  /// `maxParallel` shards, so the job never holds more devices than that. Each
  /// wave leases its sessions from the machine-wide budget first and is as big
  /// as the lease allows. The coordinator is reset once per device, so across
  /// the waves every shard is assigned once. Every wave runs; as across
  /// devices, the first non-success wave code wins (see [ltFirstNonSuccess]).
  /// A wave whose only problem was device sessions that never reached the
  /// coordinator leaves those shards to one retry wave after the last wave,
  /// whose code replaces that wave's. Last, the shards a LambdaTest
  /// infrastructure failure kept from a result run once more on the same build
  /// and coordinator (see [_runIosInfraRetry]); an external coordinator cannot
  /// reopen its shards, so its job is not retried.
  Future<int> _runIosDeviceJob(LtDeviceJobSpec job, _IosRunPlan plan) async {
    plan.coordinator?.reset();
    _recordIosSelection(plan);
    final code = await _runIosWaves(job, plan);
    if (plan.coordinator == null) {
      return code;
    }
    return _retryInfraFailures(code, 'iOS ${job.device}', (tests) => _runIosInfraRetry(job, plan, tests));
  }

  /// Reopens the shards of [tests] (shard methods) and runs them once more, in waves of at most `maxParallel`
  /// devices, each as big as its lease. The result is the across-waves verdict ([_iosWaveCoverageCode]) unless
  /// a retry wave failed for real.
  Future<int> _runIosInfraRetry(LtDeviceJobSpec job, _IosRunPlan plan, List<String> tests) async {
    final coordinator = plan.coordinator!;
    final shards = [
      for (var index = 0; index < plan.shards.length; index++)
        if (tests.contains(plan.shards[index].method)) index,
    ];
    coordinator.reopen(shards, plan.dartNames);
    final buildName = '${job.buildName}_infra_retry';
    _logger.info('[ios-waves] infrastructure retry: shard(s) ${shards.map((index) => index + 1).join(', ')} '
        '(LT build "$buildName")');
    final codes = <int>[];
    for (var next = 0; next < shards.length;) {
      final lease = await _leaseSessions(min(shards.length - next, plan.maxParallel), buildName);
      final wave = shards.sublist(next, next + lease.slots);
      next += wave.length;
      try {
        codes.add(await _runIosWave(job, plan, wave, buildName: buildName));
      } finally {
        await lease.release();
      }
    }
    codes.add(_iosWaveCoverageCode(coordinator, plan.dartNames));
    return codes.firstWhere((code) => code != ExitCode.success.code && code != ExitCode.unavailable.code,
        orElse: () => codes.last);
  }

  /// The device job's waves (see [_runIosDeviceJob]): one job when the lease covers every shard, else
  /// consecutive waves and the retry wave.
  Future<int> _runIosWaves(LtDeviceJobSpec job, _IosRunPlan plan) async {
    final total = plan.shards.length;
    // The coordinator hands shards out in wave order, so this is the run's
    // test order; the build and its synthetic shard methods stay the same.
    final order = getDep<ItTestOrder>().order.apply([for (var index = 0; index < total; index++) index]);
    LtSlotLease? lease =
        await _leaseSessions(min(total, plan.maxParallel), job.buildName, waitForAll: plan.coordinator == null);
    // An external coordinator cannot be limited to one wave's shards, so its
    // job always runs as one wave (see [_iosMaxParallel]).
    if (lease.slots >= total || plan.coordinator == null) {
      try {
        return await _runIosWave(job, plan, order, buildName: job.buildName);
      } finally {
        await lease.release();
      }
    }
    _logger.info('[ios-waves] ${job.device}: $total shards in waves of at most '
        '${plan.maxParallel} devices, each as big as the free LambdaTest sessions allow');
    final codes = <int>[];
    var next = 0;
    for (var number = 1; next < total; number++) {
      lease ??= await _leaseSessions(min(total - next, plan.maxParallel), '${job.buildName}_wave$number');
      final wave = order.sublist(next, next + lease.slots);
      next += wave.length;
      final buildName = '${job.buildName}_wave$number';
      _logger.info('[ios-waves] wave $number: shards ${wave.map((index) => index + 1).join(', ')} of $total '
          '(LT build "$buildName")');
      final int code;
      try {
        code = await _runIosWave(job, plan, wave, buildName: buildName);
      } finally {
        await lease.release();
        lease = null;
      }
      _logger.info('[ios-waves] wave $number -> ${ltDeviceVerdict(code)} (exit $code)');
      if (!plan.coordinator!.waveDeferredToRetry) {
        codes.add(code);
      }
    }
    final retry = await _runIosRetryWave(job, plan);
    if (retry != null) {
      codes.add(retry);
    }
    codes.add(_iosWaveCoverageCode(plan.coordinator!, plan.dartNames));
    // A real test failure in any wave makes the device job FAIL, even when an
    // earlier wave was only NOT VERIFIED.
    return codes.firstWhere((code) => code != ExitCode.success.code && code != ExitCode.unavailable.code,
        orElse: () => ltFirstNonSuccess(codes));
  }

  /// Registers each iOS shard under its method, with its Dart test names as
  /// aliases, and the tests the selection excluded as NOT RUN.
  void _recordIosSelection(_IosRunPlan plan) {
    final byDescription = <String, IosTestShard>{for (final shard in plan.shards) shard.description: shard};
    _recordSelection(plan.selection, (file, test) {
      final shard = byDescription[test.description];
      return shard == null
          ? null
          : ItSelectedTest(
              id: shard.method,
              file: file.basename,
              description: test.description,
              aliases: [...?plan.dartNames[test.description]]);
    });
  }

  /// Runs once, after the last wave, the shards whose device session never
  /// reached the coordinator (see [_IosShardCoordinator.deferWaveToRetry]);
  /// null when there are none. A retry that again only fails to reach the
  /// coordinator is NOT VERIFIED.
  Future<int?> _runIosRetryWave(LtDeviceJobSpec job, _IosRunPlan plan) async {
    final coordinator = plan.coordinator!;
    final shards = coordinator.retryShards;
    if (shards.isEmpty) {
      return null;
    }
    final buildName = '${job.buildName}_retry';
    _logger.info('[ios-waves] retry: shard(s) ${shards.map((index) => index + 1).join(', ')} '
        'whose device session never reached the coordinator (LT build "$buildName")');
    // A retry bigger than its lease (the per-user cap, or the whole budget) runs in parts, so no shard is dropped.
    final verdicts = <int>[];
    for (var next = 0; next < shards.length;) {
      final part = verdicts.isEmpty ? buildName : '$buildName${verdicts.length + 1}';
      final lease = await _leaseSessions(shards.length - next, part, waitForAll: true);
      final chunk = shards.sublist(next, next + lease.slots);
      next += chunk.length;
      final int code;
      try {
        code = await _runIosWave(job, plan, chunk, buildName: part);
      } finally {
        await lease.release();
      }
      verdicts.add(coordinator.waveDeferredToRetry ? ExitCode.unavailable.code : code);
    }
    final verdict = verdicts.firstWhere((code) => code != ExitCode.success.code && code != ExitCode.unavailable.code,
        orElse: () => ltFirstNonSuccess(verdicts));
    _logger.info('[ios-waves] retry -> ${ltDeviceVerdict(verdict)} (exit $verdict)');
    return verdict;
  }

  Future<int> _runIosWave(LtDeviceJobSpec job, _IosRunPlan plan, _IosWave wave, {required String buildName}) {
    plan.coordinator?.beginWave(wave);
    final total = plan.shards.length;
    return _runHyperexecuteJob(
      repo: job.workDir,
      yamlPath: _jobYamlPath(plan.repo, job, 'hyperexecute-lt-ios.yaml'),
      env: _jobEnv(plan.repo, job, plan.env),
      label: 'iOS',
      tenantLabel: plan.tenantLabel,
      environmentLabel: plan.environmentLabel,
      yaml: _iosYaml(
        buildName: buildName,
        appId: plan.artifacts.appId,
        testSuiteAppId: plan.artifacts.testSuiteAppId,
        devices: ltDevicePool(job.device),
        idleTimeoutSeconds: plan.idleTimeoutSeconds,
        wave: wave,
        shardCount: total,
        tenantLabel: plan.tenantLabel,
        environmentLabel: plan.environmentLabel,
        captureNetwork: plan.captureNetwork,
      ),
      iosBuildName: buildName,
      diagnosticsBuildName: buildName,
      iosCoordinator: plan.coordinator,
      expectedNativeTests: {
        for (final index in wave) iosCoordinatorShardOnlyTesting(index, total),
      },
      iosShards: [for (final index in wave) plan.shards[index]],
      iosDartNames: plan.dartNames,
    );
  }

  /// The device job's result across its waves: FAIL when an assigned test
  /// really failed, PASS when every shard was assigned and every selected Dart
  /// test verified exactly once or skipped itself with a reason, else NOT
  /// VERIFIED. Tests that skipped themselves at runtime are named as NOT RUN
  /// with their reason.
  int _iosWaveCoverageCode(_IosShardCoordinator coordinator, Map<String, Set<String>> dartNames) {
    final explained = coordinator.explainedSkipDescriptions;
    final names = {
      for (final MapEntry(key: description, value: names) in dartNames.entries)
        if (!explained.contains(description)) ...names,
    };
    final verified = coordinator.verifiedDartNames;
    final assigned = coordinator.assignments.length;
    final counts = '$assigned/${coordinator.shardCount} shards assigned and '
        '${verified.length}/${names.length} Dart results verified';
    final skipped = coordinator.skippedMethods;
    final notRun = skipped.isEmpty
        ? ''
        : ' NOT RUN (skipped at runtime): '
            '${[for (final MapEntry(key: method, value: reason) in skipped.entries) '$method ($reason)'].join(', ')}.';
    final failed = coordinator.failedMethods;
    if (failed.isNotEmpty) {
      _logger.err('[ios-waves] FAIL across waves: ${failed.length} test(s) failed: '
          '${failed.join(', ')}; $counts.$notRun');
      return ExitCode.software.code;
    }
    if (assigned == coordinator.shardCount && _completeIosCoverage(verified, names)) {
      _logger.info('[ios-waves] verified across waves: $counts.');
      return ExitCode.success.code;
    }
    _logger.err('[ios-waves] NOT VERIFIED across waves: $counts; every selected test must be '
        'assigned and verified exactly once.$notRun');
    return ExitCode.unavailable.code;
  }

  Future<_IosShardCoordinator?> _startIosCoordinator(List<IosTestShard> shards, Map<String, String> env) async {
    if ((env['MPLATROL_IOS_SHARD_COORDINATOR_URL'] ?? '').trim().isNotEmpty) {
      return null;
    }
    final raw = (_platform.environment[iosShardCoordinatorPortEnv] ?? '').trim();
    final port = int.tryParse(raw);
    if (raw.isEmpty || port == null || port < 1) {
      if (raw.isNotEmpty) {
        _logger.warn('[ios-shard-coordinator] ignoring $iosShardCoordinatorPortEnv="$raw": not a port number.');
      }
      return _IosShardCoordinator.start(shards: shards, logger: _logger, port: 0);
    }
    try {
      return await _IosShardCoordinator.start(shards: shards, logger: _logger, port: port);
    } on SocketException {
      _logger.warn('[ios-shard-coordinator] port $port ($iosShardCoordinatorPortEnv) is in use; using '
          'another port, which changes the iOS build, so this run cannot reuse an earlier upload.');
      return _IosShardCoordinator.start(shards: shards, logger: _logger, port: 0);
    }
  }

  Future<bool> _iosCoordinatorReady(_IosShardCoordinator? coordinator) async =>
      coordinator == null || await coordinator.checkLocalReadiness();

  String _iosCoordinatorUrl(_IosShardCoordinator? coordinator, Map<String, String> env) =>
      coordinator?.url ?? (env['MPLATROL_IOS_SHARD_COORDINATOR_URL'] ?? '').trim();

  /// The job yaml: `<repo>/.mplatrol/<name>` for a single-device run, else inside
  /// the device's own work directory.
  String _jobYamlPath(String repo, LtDeviceJobSpec job, String name) =>
      job.workDir == repo ? p.join(repo, '.mplatrol', name) : p.join(job.workDir, name);

  /// [env] for a job; a device work directory has no `hyperexecute` binary of
  /// its own, so it gets the one resolved from [repo].
  Map<String, String> _jobEnv(String repo, LtDeviceJobSpec job, Map<String, String> env) =>
      job.workDir == repo ? env : {...env, 'HYPEREXECUTE_BIN': _hyperexecuteBinary(repo, env)};

  /// Writes the job yaml and runs the HyperExecute CLI with `tunnel: true` so
  /// the CLI owns the tunnel. The mobile framework args also carry `tunnel:
  /// true`; without that, Android sessions can start under a HyperExecute tunnel
  /// but still refuse localhost credential-server traffic.
  Future<int> _runHyperexecuteJob({
    required String repo,
    required String yamlPath,
    required Map<String, String> env,
    required String label,
    required String yaml,
    String? tenantLabel,
    String? environmentLabel,
    String? iosBuildName,
    String? diagnosticsBuildName,
    _IosShardCoordinator? iosCoordinator,
    Set<String>? expectedNativeTests,
    List<IosTestShard> iosShards = const [],
    Map<String, Set<String>> iosDartNames = const {},
  }) async {
    try {
      _seedCliTunnelBinary(repo, env);
      _writeFile(yamlPath, yaml);
      return await _runHyperexecute(
        repo: repo,
        yamlPath: yamlPath,
        env: env,
        label: label,
        iosBuildName: iosBuildName,
        diagnosticsBuildName: diagnosticsBuildName,
        iosCoordinator: iosCoordinator,
        expectedNativeTests: expectedNativeTests,
        iosShards: iosShards,
        iosDartNames: iosDartNames,
      );
    } catch (error) {
      _logger.err('HyperExecute $label E2E failed: $error');
      return ExitCode.software.code;
    }
  }

  /// Gives every job a fresh `<repo>/LT` inode, seeded from the cached LT
  /// tunnel binary (`LT_BIN`) when there is one. The HyperExecute CLI rewrites
  /// `<repo>/LT` in place before each job; macOS kills (SIGKILL) a signed
  /// binary rewritten in place after it ran, so a later job of the same work
  /// directory failed with "Tunnel ... errored: signal: killed". A fresh file
  /// also replaces a truncated copy a timed-out CLI download left behind.
  ///
  /// Seeding never fails the job: when the binary cannot be read (r12: a round
  /// started from Terminal may not read `~/Downloads`), the CLI downloads its own.
  void _seedCliTunnelBinary(String repo, Map<String, String> env) {
    final target = File(p.join(repo, 'LT'));
    final sourcePath = env['LT_BIN'] ?? '';
    try {
      if (target.existsSync()) {
        target.deleteSync();
      }
      if (sourcePath.isEmpty || !File(sourcePath).existsSync()) {
        return;
      }
      File(sourcePath).copySync(target.path);
      _logger.info('[hyperexecute] seeded tunnel binary -> ${target.path}');
    } on FileSystemException catch (error) {
      _logger.warn('[hyperexecute] could not seed the tunnel binary from $sourcePath into ${target.path} '
          '(${error.osError?.message ?? error.message}); the HyperExecute CLI downloads its own.');
    }
  }

  /// Keeps the tunnel binary the HyperExecute CLI downloaded into `<repo>/LT` as mplatrol's own copy
  /// ([ltTunnelBinaryPath]) when that is `LT_BIN` and still missing, once a job ran ([result] names its job),
  /// so later jobs seed from it. A failed copy only warns.
  void _keepCliTunnelBinary(String repo, Map<String, String> env, ProcessResultX result) {
    final home = _platform.environment['HOME'] ?? '';
    final kept = env['LT_BIN'] ?? '';
    final downloaded = File(p.join(repo, 'LT'));
    if (home.isEmpty ||
        kept != ltTunnelBinaryPath(home) ||
        File(kept).existsSync() ||
        _hyperexecuteJobId(result) == null ||
        !downloaded.existsSync() ||
        downloaded.lengthSync() == 0) {
      return;
    }
    try {
      File(kept).parent.createSync(recursive: true);
      downloaded.copySync(kept);
      _logger.info('[hyperexecute] kept the tunnel binary the CLI downloaded -> $kept');
    } on FileSystemException catch (error) {
      _logger.warn('[hyperexecute] could not keep the tunnel binary at $kept '
          '(${error.osError?.message ?? error.message}); the next job downloads it again.');
    }
  }

  Future<int> _runHyperexecute({
    required String repo,
    required String yamlPath,
    required Map<String, String> env,
    required String label,
    String? iosBuildName,
    String? diagnosticsBuildName,
    _IosShardCoordinator? iosCoordinator,
    Set<String>? expectedNativeTests,
    List<IosTestShard> iosShards = const [],
    Map<String, Set<String>> iosDartNames = const {},
  }) async {
    var result = await _runHyperexecuteCli(repo: repo, yamlPath: yamlPath, env: env, label: label);
    if (result != null) {
      _keepCliTunnelBinary(repo, env, result);
    }
    if (result != null && _tunnelFailedBeforeSessions(result, iosCoordinator)) {
      _logger.warn('[hyperexecute] the $label job tunnel failed to start before any '
          'session ran; retrying the job once in ${tunnelRetryDelay.inSeconds}s.');
      await Future<void>.delayed(tunnelRetryDelay);
      _seedCliTunnelBinary(repo, env);
      result = await _runHyperexecuteCli(repo: repo, yamlPath: yamlPath, env: env, label: label);
    }
    if (result == null) {
      final stopped = itRunStopSignal(_stop.exitCode);
      _recordUnfinishedJob(
          ItTestOutcome.notRun,
          stopped == null
              ? 'infrastructure: the HyperExecute job stalled before this test finished'
              : itRunStoppedReason(stopped),
          iosCoordinator);
      return stopped == null ? ExitCode.unavailable.code : _stop.exitCode;
    }
    if (iosBuildName != null && iosCoordinator != null) {
      await _renameAssignedIosSessions(buildName: iosBuildName, coordinator: iosCoordinator, env: env);
    }
    _logHyperexecuteSummary(result);
    final jobId = _hyperexecuteJobId(result);
    if (jobId != null) {
      try {
        await HyperexecuteScenarioLogs().refetch(workDir: repo, jobId: jobId, headers: _nativeVerdictHeaders(env));
      } on FileSystemException catch (error) {
        _logger.warn('[leg-artifacts] warn: could not keep the scenario logs of job $jobId '
            '(${error.path}: ${error.osError?.message ?? error.message}); the job results are still read.');
      }
    }
    final code = await _hyperexecuteJobVerdict(result,
        env: env,
        label: label,
        diagnosticsBuildName: diagnosticsBuildName ?? iosBuildName,
        iosBuildName: iosBuildName,
        iosCoordinator: iosCoordinator,
        expectedNativeTests: expectedNativeTests,
        iosShards: iosShards,
        iosDartNames: iosDartNames);
    if (code == ExitCode.software.code && iosCoordinator != null) {
      final nonPass = await _recordIosWaveSessionOutcomes(result, env, iosCoordinator,
          dartNames: iosDartNames, nativeSelection: expectedNativeTests ?? const {});
      if (nonPass == _IosWaveNonPass.skipped) {
        return _onlySkippedIosWaveCode(iosCoordinator, iosDartNames);
      }
      if (nonPass == _IosWaveNonPass.infrastructure) {
        return ExitCode.unavailable.code;
      }
    }
    if (label == 'Android') {
      await _recordAndroidSessions(result, env);
    }
    return code;
  }

  /// The code of a wave whose every non-passing test skipped itself at runtime. Skips that all name their reason
  /// are NOT RUN, not a failure: a split wave leaves the verdict to [_iosWaveCoverageCode] after the last wave, and
  /// a single-wave job gets it now. A skip without a reason makes the wave NOT VERIFIED.
  int _onlySkippedIosWaveCode(_IosShardCoordinator coordinator, Map<String, Set<String>> dartNames) {
    if (coordinator.waveSkipsExplained) {
      _logger.info('[ios-waves] every non-passing test of this wave skipped itself at runtime with a '
          'reason: NOT RUN, not FAIL. LambdaTest shows those sessions failed because HyperExecute never '
          'completes a skipped-only task.');
      return coordinator.isSplit ? ExitCode.success.code : _iosWaveCoverageCode(coordinator, dartNames);
    }
    _logger.err('[ios-waves] every non-passing test of this wave skipped itself at '
        'runtime, at least one without a reason: NOT VERIFIED, not FAIL.');
    return ExitCode.unavailable.code;
  }

  /// Gives the tests a job never reported [outcome] with [reason]: the
  /// current wave's iOS shards, or every unresolved test of an Android job.
  /// The job failing on LambdaTest's side makes them `lt-failure`.
  void _recordUnfinishedJob(ItTestOutcome outcome, String reason, _IosShardCoordinator? coordinator) {
    if (coordinator == null) {
      _results.unfinished(outcome, reason, cause: ItResultCategory.ltFailure);
      return;
    }
    for (final shard in coordinator.waveShards) {
      _results.verdict(outcome, testId: shard.method, reason: reason, cause: ItResultCategory.ltFailure);
    }
  }

  /// Records the per-test verdict of each session of the current Android job
  /// that the job verdict did not already decide: its native instrumentation
  /// verdict ([androidInstrumentationVerdict]), else LambdaTest's own status.
  /// Best effort: a failure to read the job is a warning, never a verdict.
  Future<void> _recordAndroidSessions(ProcessResultX result, Map<String, String> env) async {
    final jobId = _results.recording ? _hyperexecuteJobId(result) : null;
    if (jobId == null) {
      return;
    }
    final headers = _nativeVerdictHeaders(env);
    try {
      final sessions = (await _hyperexecuteSessions(jobId, headers))['data'] as List;
      final buildId = await _jobBuildId(sessions.cast<Map>(), env);
      for (final session in sessions.cast<Map>()) {
        await _recordAndroidSession(session, headers, env, buildId);
      }
    } catch (error) {
      _logger.warn('[ci-report] could not read the sessions of HyperExecute job $jobId for per-test '
          'results (${error.runtimeType}); their tests report NOT RUN or NOT VERIFIED.');
    }
  }

  /// The App Automation build every session of the job belongs to, read from its first session; null when
  /// the job has no session or LambdaTest does not return the build.
  Future<String?> _jobBuildId(List<Map> sessions, Map<String, String> env) async {
    if (sessions.isEmpty) {
      return null;
    }
    try {
      final details = await getDep<LtSessionArtifacts>().session(sessions.first['sessionID'] as String, env);
      return details?['build_id']?.toString();
    } catch (error) {
      _logger.warn('[ci-report] could not read the LambdaTest build of the job (${error.runtimeType}); its '
          'test links omit the build.');
      return null;
    }
  }

  Future<void> _recordAndroidSession(
      Map session, Map<String, String> headers, Map<String, String> env, String? buildId) async {
    final id = session['sessionID'] as String;
    final identity = session['scenario_name'] as String?;
    final status = session['status'] as String?;
    _results.session(id, ItSessionDetails(testId: identity, providerStatus: status, buildId: buildId));
    if (identity == null || _results.sessionHasVerdict(id) || (status != 'passed' && status != 'failed')) {
      return;
    }
    final log = await _fetchLtSessionInstrumentationLog(sessionId: id, headers: headers);
    if (log == null) {
      return;
    }
    _recordAndroidVerdict(id, identity, androidInstrumentationVerdict(log, nativeIdentity: identity), log,
        env: env, providerFailed: status == 'failed');
  }

  /// Records one Android session's instrumentation [verdict] for [identity].
  /// A session LambdaTest failed is a FAIL even without terminal evidence.
  void _recordAndroidVerdict(
      String sessionId, String identity, ({AndroidInstrumentationOutcome outcome, String detail}) verdict, String log,
      {required Map<String, String> env, bool providerFailed = false}) {
    final passed = passedRunOutcome(log);
    final failure = _androidFailureLine(log) ?? verdict.detail;
    final (outcome, reason) = switch (verdict.outcome) {
      AndroidInstrumentationOutcome.passed => (passed.outcome, passed.reason),
      AndroidInstrumentationOutcome.skipped => (ItTestOutcome.notRun, '$itRuntimeSkipReason (${verdict.detail})'),
      AndroidInstrumentationOutcome.failed => (ItTestOutcome.fail, failure),
      AndroidInstrumentationOutcome.unavailable when providerFailed => (ItTestOutcome.fail, failure),
      AndroidInstrumentationOutcome.unavailable => (ItTestOutcome.notVerified, verdict.detail),
    };
    final redacted = reason == null ? null : redactE2eSecrets(reason, env);
    if (outcome == ItTestOutcome.fail) {
      _logger.err('failure: $identity: $redacted');
    }
    _results.verdict(outcome, testId: identity, sessionId: sessionId, reason: redacted, evidence: log);
  }

  /// The failure of the test in [log]: Flutter's own exception message when the log has it, else the first
  /// line of the instrumentation failure stack, or null.
  String? _androidFailureLine(String log) {
    final flutter = flutterTestFailureMessage(log);
    if (flutter != null) {
      return flutter;
    }
    final stack = RegExp(r'^INSTRUMENTATION_STATUS: stack=(.+)$', multiLine: true).firstMatch(log)?[1]?.trim();
    if (stack == null || stack.isEmpty) {
      return null;
    }
    return stack.length > 300 ? '${stack.substring(0, 300)}...' : stack;
  }

  /// Runs the HyperExecute CLI once under the stall watchdog. Null (after
  /// logging) when the watchdog stopped a stalled job, or the run is stopping ([ItRunStop]).
  Future<ProcessResultX?> _runHyperexecuteCli({
    required String repo,
    required String yamlPath,
    required Map<String, String> env,
    required String label,
  }) async {
    final progress = _logger.progress('Running HyperExecute $label job');
    final stall = _watchForStall(repo: repo, env: env);
    late final ProcessResultX result;
    try {
      result = await _shell.runArgs(
        _hyperexecuteBinary(repo, env),
        [
          '--user',
          env['LT_USERNAME']!,
          '--key',
          env['LT_ACCESS_KEY']!,
          '--config',
          yamlPath,
          '--download-logs',
          '--download-report'
        ],
        workingDirectory: repo,
        throwOnError: false,
        cancelOn: Future.any([stall.detected, _stop.requested]),
      );
    } catch (_) {
      progress.fail('HyperExecute $label job failed');
      rethrow;
    } finally {
      stall.stop();
    }
    if (_stop.isStopping) {
      progress.fail('HyperExecute $label job stopped');
      return null;
    }
    final stallDiagnostic = await stall.diagnostic;
    if (stallDiagnostic != null) {
      progress.fail('HyperExecute $label job stalled');
      _logStalledJob(stallDiagnostic);
      return null;
    }
    if (result.exitCode == ExitCode.success.code) {
      progress.complete('HyperExecute $label job finished');
    } else {
      progress.fail('HyperExecute $label job failed');
    }
    return result;
  }

  void _logStalledJob(String diagnostic) => _logger.err(
        '[hyperexecute-watchdog] $diagnostic. Stopped the HyperExecute '
        'client; the unfinished task(s) are NOT RUN (infrastructure), neither '
        'passes nor test failures. Re-run, or check the job in the LambdaTest '
        'dashboard.',
      );

  /// Whether the job failed because its tunnel never started, before any
  /// session ran: no iOS shard was assigned, so nothing ran or needs a verdict.
  /// Covers a killed tunnel binary and a local port another job already holds
  /// ("Unable to start tunnels ... bind: address already in use").
  bool _tunnelFailedBeforeSessions(ProcessResultX result, _IosShardCoordinator? coordinator) =>
      result.exitCode != ExitCode.success.code &&
      _tunnelStartFailure.hasMatch('${result.outText}\n${result.errText}') &&
      (coordinator == null || coordinator.waveAssignments.isEmpty);

  static final _tunnelStartFailure = RegExp('failed to start tunnel instances|Unable to start tunnels');

  Future<int> _hyperexecuteJobVerdict(
    ProcessResultX result, {
    required Map<String, String> env,
    required String label,
    required String? diagnosticsBuildName,
    required String? iosBuildName,
    required _IosShardCoordinator? iosCoordinator,
    required Set<String>? expectedNativeTests,
    required List<IosTestShard> iosShards,
    required Map<String, Set<String>> iosDartNames,
  }) async {
    final outputSkipSummary = patrolSkipSummary('${result.outText}\n${result.errText}');
    final skippedSessions = await _reportLtSkippedSessions(
        buildName: diagnosticsBuildName, env: env, label: label, outputSkipSummary: outputSkipSummary);
    if (result.exitCode == ExitCode.success.code) {
      return _completeHyperexecuteVerdict(
        result: result,
        env: env,
        label: label,
        skipped: outputSkipSummary.hasSkippedTests || skippedSessions > 0,
        expectedNativeTests: expectedNativeTests,
        iosCoordinator: iosCoordinator,
        iosBuildName: iosBuildName,
        iosShards: iosShards,
        iosDartNames: iosDartNames,
      );
    }
    final frameworkSetup =
        lessonKeyErrorLine(TestLesson.lambdaTestFrameworkSetup, '${result.outText}\n${result.errText}');
    if (frameworkSetup != null) {
      _reportFrameworkSetupFailure(label, frameworkSetup, iosCoordinator);
      return ExitCode.unavailable.code;
    }
    _logger.err('HyperExecute $label E2E failed (exit ${result.exitCode}).');
    final tunnelError = lessonKeyErrorLine(TestLesson.lambdaTestTunnel, '${result.outText}\n${result.errText}');
    if (tunnelError != null) {
      reportTestLessons(_redact(tunnelError),
          repo: getDep<ItLegDir>().stateRepo(_fileSystem.getAppDirectory().path), logger: _logger);
    }
    _reportUnassignedIosShards(iosCoordinator);
    await _reportHyperexecuteDiagnostics(buildName: diagnosticsBuildName, label: label, env: env);
    return ExitCode.software.code;
  }

  /// LambdaTest could not set up the test framework for the uploaded app, so
  /// the job ended before any device session: NOT VERIFIED, not a test result,
  /// and there is no LambdaTest build to diagnose.
  void _reportFrameworkSetupFailure(String label, String errorLine, _IosShardCoordinator? coordinator) {
    _logger.err('HyperExecute $label job NOT VERIFIED (infrastructure): '
        '${_redact(errorLine)} LambdaTest could not prepare the app for a device, so '
        'no test ran; this is neither a pass nor a test failure.');
    _reportUnassignedIosShards(coordinator);
    _recordUnfinishedJob(ItTestOutcome.notRun,
        'infrastructure: LambdaTest could not prepare the app for a device, so no test ran', coordinator);
    reportTestLessons(errorLine,
        repo: getDep<ItLegDir>().stateRepo(_fileSystem.getAppDirectory().path), logger: _logger);
  }

  /// Records the outcomes of a wave that did not verify as a whole, so one
  /// failed session does not hide the sessions beside it from the
  /// across-waves summary: each passed session of the current job whose native
  /// and Dart results verify on their own, and each other session's assigned
  /// test as failed or skipped at runtime. The wave's own verdict stands.
  ///
  /// Returns [_IosWaveNonPass.skipped] when every assigned test of the wave passed or skipped itself, with at
  /// least one skip; [_IosWaveNonPass.infrastructure] when, besides those, at least one session ended before
  /// any Dart test ran; else [_IosWaveNonPass.failed].
  Future<_IosWaveNonPass> _recordIosWaveSessionOutcomes(
      ProcessResultX result, Map<String, String> env, _IosShardCoordinator coordinator,
      {required Map<String, Set<String>> dartNames, required Set<String> nativeSelection}) async {
    final jobId = _hyperexecuteJobId(result);
    if (jobId == null) {
      return _IosWaveNonPass.failed;
    }
    final headers = _nativeVerdictHeaders(env);
    try {
      final job = (await _hyperexecuteJson(jobId, headers))['data'] as Map;
      final sessions = (await _hyperexecuteSessions(jobId, headers))['data'] as List;
      final assigned = coordinator.waveAssignments.map((assignment) => assignment.method).toSet();
      final selected = {
        for (final shard in coordinator.waveShards)
          if (assigned.contains(shard.method)) shard.method: shard.description,
      };
      final observed = <String>{};
      final completed = <String>{};
      final nonPassing = <String, String?>{};
      final noDartTest = <String>{};
      for (final session in sessions.cast<Map>()) {
        if (session['status'] == 'passed') {
          await _iosSessionInstrumentationFailure(session, headers, selected, observed,
              dartNames: dartNames,
              completed: completed,
              job: job,
              sessions: sessions,
              nativeSelection: nativeSelection);
        } else {
          await _classifyNonPassingIosSession(session, headers, assigned, nonPassing, noDartTest);
        }
      }
      if (noDartTest.isNotEmpty) {
        _logger.err('[ios-waves] ${noDartTest.join(', ')}: the session ended before any Dart test ran '
            '(LambdaTest infrastructure), so NOT VERIFIED, not a test failure.');
      }
      for (final MapEntry(key: method, value: skipReason) in nonPassing.entries) {
        if (skipReason == null) {
          coordinator.recordFailedMethod(method);
        } else {
          coordinator.recordSkippedMethod(method, skipReason);
        }
      }
      if (!coordinator.recordVerifiedDartNames(completed)) {
        _logger.warn('[ios-waves] a passed session of job $jobId repeated a Dart result '
            'an earlier wave verified.');
      } else if (completed.length == assigned.length) {
        await _deferUnreachableIosShards(coordinator, sessions.cast<Map>(), headers);
      }
      final skips = nonPassing.values.whereType<String>().length;
      if (noDartTest.isNotEmpty) {
        return nonPassing.length == skips && observed.length + skips + noDartTest.length == assigned.length
            ? _IosWaveNonPass.infrastructure
            : _IosWaveNonPass.failed;
      }
      return skips > 0 && skips == nonPassing.length && observed.length + skips == assigned.length
          ? _IosWaveNonPass.skipped
          : _IosWaveNonPass.failed;
    } catch (error) {
      _logger.warn('[ios-waves] could not verify the sessions of job $jobId: '
          '${error.runtimeType}.');
      return _IosWaveNonPass.failed;
    }
  }

  /// Adds the assigned test a non-passing session ran to [outcomes]: its skip
  /// reason when it skipped itself at runtime, else null for a failure. A
  /// session without a readable log or an assigned test, or one that never
  /// reached the coordinator, ran no assigned test and adds nothing. An
  /// assigned session that ended before any Dart test ran (see
  /// [ltIosLogShowsNoDartTest]) adds its method to [noDartTest] instead.
  Future<void> _classifyNonPassingIosSession(Map session, Map<String, String> headers, Set<String> assigned,
      Map<String, String?> outcomes, Set<String> noDartTest) async {
    final log = await _fetchLtSessionInstrumentationLog(sessionId: session['sessionID'] as String, headers: headers);
    if (log == null || log.contains('PATROL_SHARD_NOT_RUN')) {
      return;
    }
    final text = _iosNativeLines(log).join('\n');
    final method = _selectedMethodFromInstrumentation(text);
    if (method == null || !assigned.contains(method)) {
      return;
    }
    if (ltIosLogShowsNoDartTest(log)) {
      noDartTest.add(method);
      return;
    }
    final skip = RegExp(r'MPLATROL_TEST_SKIPPED coordinator shard method=\S+ NOT RUN: ([^\n]+)').firstMatch(text);
    outcomes[method] = skip?[1]!.trim();
  }

  /// Leaves this wave's unassigned shards to the retry wave when each of them
  /// is explained by a failed session that never reached the coordinator
  /// (`PATROL_SHARD_NOT_RUN`): acme 2026-10-02 lost a test to one session
  /// whose coordinator requests were all refused while the others got theirs.
  Future<void> _deferUnreachableIosShards(
      _IosShardCoordinator coordinator, List<Map> sessions, Map<String, String> headers) async {
    final unassigned = coordinator.waveShards.length - coordinator.waveAssignments.length;
    final failed = unassigned == 0 ? const <Map>[] : sessions.where((session) => session['status'] != 'passed');
    var unreachable = 0;
    for (final session in failed) {
      final log = await _fetchLtSessionInstrumentationLog(sessionId: session['sessionID'] as String, headers: headers);
      if ((log ?? '').contains('PATROL_SHARD_NOT_RUN')) {
        unreachable++;
      }
    }
    if (unassigned > 0 && unreachable == unassigned) {
      coordinator.deferWaveToRetry();
    }
  }

  /// The one HyperExecute job ID the CLI output links; null when absent or
  /// ambiguous.
  String? _hyperexecuteJobId(ProcessResultX result) {
    final jobIds = RegExp(r'Build Link:\s*https://appautomation\.lambdatest\.com/'
            r'build\?jobid=([a-fA-F0-9-]{36})\b')
        .allMatches('${result.outText}\n${result.errText}')
        .map((match) => match.group(1)!)
        .toSet();
    return jobIds.length == 1 ? jobIds.single : null;
  }

  /// Starts the stall watchdog for the HyperExecute CLI about to run in
  /// [repo]; only CLI-log text written after this call names the job.
  _StallWatch _watchForStall({required String repo, required Map<String, String> env}) {
    final cliLog = File(p.join(repo, 'hyperexecute-cli.log'));
    final processDone = Completer<void>();
    final detected = Completer<void>();
    final offset = cliLog.existsSync() ? cliLog.lengthSync() : 0;
    unawaited(announceHyperexecuteJob(
      cliLogPath: cliLog.path,
      cliLogOffset: offset,
      done: processDone.future,
      onJob: _announceJob,
      every: pollDelay,
    ));
    final diagnostic = _stallWatchdog
        .watch(
      cliLogPath: cliLog.path,
      cliLogOffset: offset,
      headers: _nativeVerdictHeaders(env),
      done: processDone.future,
    )
        .then((value) {
      if (value != null) {
        detected.complete();
      }
      return value;
    });
    return (
      detected: detected.future,
      diagnostic: diagnostic,
      stop: processDone.complete,
    );
  }

  void _announceJob(String jobId) {
    _results.hyperexecuteJob(jobId);
    _logger.info('[lt] Watch it live: ${hyperexecuteJobPageUrl(jobId)} '
        '(HyperExecute job: devices, stages and logs as they run)');
  }

  Future<int> _completeHyperexecuteVerdict({
    required ProcessResultX result,
    required Map<String, String> env,
    required String label,
    required bool skipped,
    Set<String>? expectedNativeTests,
    _IosShardCoordinator? iosCoordinator,
    String? iosBuildName,
    List<IosTestShard> iosShards = const [],
    Map<String, Set<String>> iosDartNames = const {},
  }) async {
    if (skipped) {
      _logger.err(
        'HyperExecute $label E2E reported skipped test(s); failing the '
        'command because a skip is not a pass.',
      );
      return ExitCode.unavailable.code;
    }
    final assignmentFailure = _iosAssignmentCoverageFailure(iosCoordinator);
    if (assignmentFailure != null) {
      _logger.err('HyperExecute $label E2E not verified: $assignmentFailure.');
      return ExitCode.unavailable.code;
    }
    final failure = await _hyperexecuteVerdictFailure(result, env, expectedNativeTests,
        android: label == 'Android',
        iosBuildName: iosBuildName,
        iosShards: iosShards,
        iosDartNames: iosDartNames,
        iosCoordinator: iosCoordinator);
    if (failure != null) {
      _logger.err('HyperExecute $label E2E not verified: $failure. '
          'CLI exit 0 is not a native test pass; inspect the current job.');
      // An unverified CLI-zero result is not a pre-assignment startup failure,
      // and a skip without a reason is NOT VERIFIED on Android as on iOS.
      return ExitCode.unavailable.code;
    }
    _logger.success('HyperExecute $label E2E passed.');
    return ExitCode.success.code;
  }

  /// Names each selected iOS shard no runner session ever received: those
  /// tests did not run, so they are infrastructure NOT RUN, not results.
  void _reportUnassignedIosShards(_IosShardCoordinator? coordinator) {
    if (coordinator == null) {
      return;
    }
    final assigned = coordinator.waveAssignments.map((assignment) => assignment.method).toSet();
    for (final shard in coordinator.waveShards) {
      if (!assigned.contains(shard.method)) {
        _logger.err(
          '[ios-shard-coordinator] NOT RUN (infrastructure): ${shard.method} '
          'was never assigned to a device session; it is not a pass or a '
          'test failure.',
        );
        _results.verdict(ItTestOutcome.notRun,
            testId: shard.method,
            reason: 'infrastructure: never assigned to a device session',
            cause: ItResultCategory.ltFailure);
      }
    }
  }

  String? _iosAssignmentCoverageFailure(_IosShardCoordinator? coordinator) {
    if (coordinator == null) {
      return null;
    }
    final shards = coordinator.waveShards;
    final selected = shards.map((shard) => shard.method).toSet();
    final assigned = coordinator.waveAssignments.map((assignment) => assignment.method).toSet();
    if (assigned.length != shards.length || !assigned.containsAll(selected)) {
      return 'iOS coordinator assignments do not exhaust selected Dart shards '
          '(${assigned.length}/${selected.length}); native NoShard is not journey coverage';
    }
    return null;
  }

  Future<String?> _hyperexecuteVerdictFailure(
      ProcessResultX result, Map<String, String> env, Set<String>? expectedNativeTests,
      {required bool android,
      String? iosBuildName,
      List<IosTestShard> iosShards = const [],
      Map<String, Set<String>> iosDartNames = const {},
      _IosShardCoordinator? iosCoordinator}) async {
    final output = '${result.outText}\n${result.errText}';
    final jobId = _hyperexecuteJobId(result);
    if (jobId == null) {
      return 'no unambiguous current HyperExecute job ID in CLI output';
    }
    final headers = _nativeVerdictHeaders(env);
    try {
      final response = await _hyperexecuteJson(jobId, headers);
      final failure = _hyperexecuteJobFailure(response['data'], jobId);
      if (failure != null) {
        return failure;
      }
      final job = response['data'] as Map;
      if (RegExp(
              r'Test Execution Time:\s*0s\b|'
              r'Pass test stage percentage:\s*0(?:\.0+)?%|Failed Tasks:\s*[1-9]\d*',
              caseSensitive: false)
          .hasMatch(output)) {
        return 'job $jobId reported zero test execution, zero pass percentage, '
            'or failed tasks';
      }
      final sessions = await _hyperexecuteSessions(jobId, headers);
      final sessionFailure = _hyperexecuteSessionFailure(sessions, job, expectedNativeTests);
      if (sessionFailure != null) {
        return sessionFailure;
      }
      if (!android) {
        return await _iosInstrumentationFailure(sessions, headers,
            buildName: iosBuildName,
            shards: iosShards,
            dartNames: iosDartNames,
            job: job,
            nativeSelection: expectedNativeTests!,
            coordinator: iosCoordinator);
      }
      return await _androidInstrumentationFailure(sessions, headers,
          job: job, selected: expectedNativeTests!, env: env);
    } catch (error) {
      return 'could not verify job $jobId: ${error.runtimeType}';
    }
  }

  Map<String, String> _nativeVerdictHeaders(Map<String, String> env) =>
      getDep<LtHttp>().basicAuth(env['LT_USERNAME'] ?? '', env['LT_ACCESS_KEY'] ?? '');

  Future<String?> _iosInstrumentationFailure(Map<String, dynamic> response, Map<String, String> headers,
      {required String? buildName,
      required List<IosTestShard> shards,
      required Map<String, Set<String>> dartNames,
      required Map job,
      required Set<String> nativeSelection,
      _IosShardCoordinator? coordinator}) async {
    final sessions = (response['data'] as List).cast<Map>();
    final buildFailure = await _iosNativeBuildFailure(sessions, headers, buildName);
    if (buildFailure != null) {
      return buildFailure;
    }
    final selected = {for (final shard in shards) shard.method: shard.description};
    final observed = <String>{};
    final completed = <String>{};
    for (final session in sessions) {
      final failure = await _iosSessionInstrumentationFailure(session, headers, selected, observed,
          dartNames: dartNames, completed: completed, job: job, sessions: sessions, nativeSelection: nativeSelection);
      if (failure != null) {
        return failure;
      }
    }
    const incomplete = 'iOS native Dart results do not exhaust selected assignments';
    if (!_completeIosCoverage(observed, selected.keys.toSet())) {
      return incomplete;
    }
    // A wave verifies only its own shards; the device job checks the union
    // against every selected Dart name once its last wave ends.
    if (coordinator != null && coordinator.isSplit) {
      return coordinator.recordVerifiedDartNames(completed) ? null : 'iOS native Dart result repeated across waves';
    }
    final expectedNames = dartNames.values.expand((names) => names).toSet();
    return _completeIosCoverage(completed, expectedNames) ? null : incomplete;
  }

  bool _completeIosCoverage(Set<String> observed, Set<String> expected) =>
      observed.length == expected.length && observed.containsAll(expected);

  Future<String?> _iosSessionInstrumentationFailure(
      Map session, Map<String, String> headers, Map<String, String> selected, Set<String> observed,
      {required Map<String, Set<String>> dartNames,
      required Set<String> completed,
      required Map job,
      required List sessions,
      required Set<String> nativeSelection}) async {
    final id = session['sessionID'] as String;
    final failure = await _iosSessionVerdictFailure(session, headers, selected, observed,
        dartNames: dartNames, completed: completed, job: job, sessions: sessions, nativeSelection: nativeSelection);
    _recordIosSessionVerdict(id, session['status'] as String?, failure);
    return failure.failure;
  }

  /// Records the verdict [_iosSessionVerdictFailure] decided for session [id]:
  /// a verified pass (MOCKED when the run said so), a FAIL for a session
  /// LambdaTest failed, else NOT VERIFIED with the [failure].
  void _recordIosSessionVerdict(String id, String? status, _IosSessionVerdict verdict) {
    final reason = verdict.failure;
    if (reason == null) {
      final passed = passedRunOutcome(verdict.log ?? '');
      _results.verdict(passed.outcome, testId: verdict.method, sessionId: id, reason: passed.reason);
      return;
    }
    _results.verdict(status == 'failed' ? ItTestOutcome.fail : ItTestOutcome.notVerified,
        testId: verdict.method, sessionId: id, reason: reason, evidence: verdict.log);
  }

  Future<_IosSessionVerdict> _iosSessionVerdictFailure(
      Map session, Map<String, String> headers, Map<String, String> selected, Set<String> observed,
      {required Map<String, Set<String>> dartNames,
      required Set<String> completed,
      required Map job,
      required List sessions,
      required Set<String> nativeSelection}) async {
    final id = session['sessionID'] as String;
    final log = await _fetchLtSessionInstrumentationLog(sessionId: id, headers: headers);
    if (log == null) {
      _logger.warn(await annotateNativeNonpass(
          http: getDep<LtHttp>(),
          headers: headers,
          job: job,
          sessions: sessions,
          session: session,
          selected: nativeSelection,
          android: false,
          outcome: AndroidInstrumentationOutcome.unavailable));
      return (
        failure: 'iOS native session $id instrumentation unavailable; execution unverified',
        log: null,
        method: null
      );
    }
    final lines = _iosNativeLines(log);
    final failure = _iosXctestFailure(lines, session['scenario_name'] as String);
    if (failure != null) {
      return (failure: 'iOS native session $id: $failure', log: log, method: null);
    }
    final method = _selectedMethodFromInstrumentation(lines.join('\n'));
    if (!selected.containsKey(method) || !observed.add(method!)) {
      return (
        failure: 'iOS native session $id has missing, foreign or repeated Dart selection',
        log: log,
        method: null
      );
    }
    final description = selected[method]!;
    final dartFailure = _iosDartResultFailure(lines, description, dartNames[description] ?? const {}, completed);
    return (failure: dartFailure == null ? null : 'iOS native session $id: $dartFailure', log: log, method: method);
  }

  Future<String?> _iosNativeBuildFailure(List<Map> sessions, Map<String, String> headers, String? buildName) async {
    if (buildName == null) {
      return 'iOS current build identity unavailable';
    }
    final build = await _iosNativeBuildId(buildName, headers);
    if (build.failure != null) {
      return build.failure;
    }
    final buildId = build.id;
    if (buildId == null) {
      return 'iOS numeric native build identity unavailable';
    }
    final response = await getDep<LtHttp>().get(
        'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
        'sessions?build_id=$buildId',
        headers: headers,
        timeout: const Duration(seconds: 30));
    if (response.statusCode != 200) {
      return 'iOS build session evidence GET returned HTTP ${response.statusCode}';
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return 'iOS current build native session response malformed';
    }
    return _iosBuildSessionInventoryFailure(decoded, sessions, buildId);
  }

  Future<({String? id, String? failure})> _iosNativeBuildId(String buildName, Map<String, String> headers) async {
    final response = await getDep<LtHttp>().get(
        'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
        'builds?limit=30&sort=desc.create_timestamp',
        headers: headers,
        timeout: const Duration(seconds: 30));
    if (response.statusCode != 200) {
      return (id: null, failure: 'iOS build evidence GET returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is List) {
      for (final build in data.whereType<Map>()) {
        if (build['name'] == buildName) {
          return (id: _iosNumericBuildId(build['build_id']), failure: null);
        }
      }
    }
    return (id: null, failure: 'iOS current native build metadata missing');
  }

  String? _iosBuildSessionInventoryFailure(Map decoded, List<Map> sessions, String buildId) {
    final native = decoded['data'];
    if (native is! List || native.length != sessions.length) {
      return 'iOS current build native session inventory incomplete';
    }
    final metadata = decoded['metadata'];
    if (!_iosBuildPaginationComplete(metadata, native.length)) {
      return 'iOS build native session pagination incomplete';
    }
    final ids = <String>{};
    for (final session in native) {
      if (!_iosNativeSessionMatchesBuild(session, buildId) || !ids.add(session['session_id'] as String)) {
        return 'iOS native build/session identity or status mismatch';
      }
    }
    return ids.containsAll(sessions.map((session) => session['sessionID']))
        ? null
        : 'iOS native build sessions do not match current HE job';
  }

  bool _iosBuildPaginationComplete(dynamic metadata, int count) =>
      metadata == null ||
      metadata is Map &&
          (!metadata.containsKey('hasmore') || metadata['hasmore'] == false) &&
          (!metadata.containsKey('total') || metadata['total'] == count);

  bool _iosNativeSessionMatchesBuild(dynamic session, String buildId) =>
      session is Map &&
      session['session_id'] is String &&
      (session['session_id'] as String).isNotEmpty &&
      {'passed', 'completed'}.contains(session['status_ind']) &&
      (!session.containsKey('build_id') || _iosNumericBuildId(session['build_id']) == buildId);

  String? _iosNumericBuildId(Object? value) {
    final text = value?.toString() ?? '';
    if (!RegExp(r'^[0-9]+$').hasMatch(text)) {
      return null;
    }
    final digits = text.replaceFirst(RegExp('^0+'), '');
    return digits.isEmpty ? null : digits;
  }

  List<String> _iosNativeLines(String log) {
    final ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))');
    final barrier = RegExp('^XCTestOutputBarrier(?=Test (?:Case|Suite) )');
    final nslog = RegExp(r'^\d{4}-\d{2}-\d{2}\s+[^\r\n]*?\[[^\]\r\n]+\]\s*');
    return plainLtInstrumentationLog(log)
        .replaceAll(ansi, '')
        .split('\n')
        .map((line) => line.trim().replaceFirst(nslog, '').replaceFirst(barrier, ''))
        .toList();
  }

  String? _iosXctestFailure(List<String> lines, String selected) {
    if (patrolSkipSummary(lines.join('\n')).hasSkippedTests ||
        lines.any((line) => RegExp(r'^PATROL_SELECTION_NO_SHARD(?:\s|$)').hasMatch(line))) {
      return 'native runtime skip or empty shard is not a pass';
    }
    final pattern = RegExp(r"^Test Case '-\[(?:RunnerUITests\.)?(\w+) (\w+)\]' "
        r'(started|passed|failed|skipped)(?: \([\d.]+ seconds\))?\.?$');
    final cases = lines.where((line) => line.startsWith('Test Case ')).toList();
    final events = <String>[];
    for (final line in cases) {
      final match = pattern.firstMatch(line);
      if (match == null || '${match[1]}/${match[2]}' != selected) {
        return 'native XCTest identity malformed or not selected';
      }
      events.add(match[3]!);
    }
    if (!_iosXctestCaseComplete(events) || !_iosXctestTerminalPassed(cases)) {
      return 'native XCTest failed, skipped, duplicated or unfinished';
    }
    return _iosXctestCompletionFailure(lines, selected.split('/').first);
  }

  bool _iosXctestTerminalPassed(List<String> cases) {
    final outcomes = parseLtTestOutcomes(cases.map((line) => line.replaceFirst('RunnerUITests.', '')).join('\n'));
    return outcomes.length == 1 && outcomes.single.passed;
  }

  bool _iosXctestCaseComplete(List<String> events) =>
      events.length == 1 && events.single == 'passed' ||
      events.length == 2 && events.first == 'started' && events.last == 'passed';

  String? _iosXctestCompletionFailure(List<String> lines, String suiteName) {
    final suite = RegExp("^Test Suite '(?:RunnerUITests\\.)?${RegExp.escape(suiteName)}' "
        '(passed|failed|skipped) at .+\$');
    final ends = [
      for (var i = 0; i < lines.length; i++)
        if (suite.hasMatch(lines[i])) i
    ];
    if (ends.length != 1 || suite.firstMatch(lines[ends.single])![1] != 'passed') {
      return 'native XCTest suite completion missing or contradictory';
    }
    final trailing = lines.skip(ends.single + 1).where((line) => line.isNotEmpty).toList();
    final counts = RegExp(r'^Executed 1 test, with 0 failures? \(0 unexpected\) in '
        r'[\d.]+(?: \([\d.]+\))? seconds\.?$');
    if (!_iosXctestTrailingComplete(trailing, counts)) {
      return 'native XCTest completion counts missing or execution continued';
    }
    if (!_iosOuterCompletionPassed(trailing, counts)) {
      return 'native XCTest outer completion failed or counts contradictory';
    }
    return null;
  }

  bool _iosXctestTrailingComplete(List<String> lines, RegExp counts) =>
      lines.isNotEmpty && counts.hasMatch(lines.first) && !lines.any((line) => line.startsWith('Test Case '));

  bool _iosOuterCompletionPassed(List<String> lines, RegExp counts) =>
      !lines.any((line) => RegExp("^Test Suite '.+' (?:failed|skipped) at ").hasMatch(line)) &&
      lines.where((line) => line.startsWith('Executed ')).every(counts.hasMatch);

  String? _iosDartResultFailure(List<String> lines, String description, Set<String> names, Set<String> completed) {
    final selections = RegExp(
            r'^PATROL_SELECTION_SOURCE source=\S+ method=([A-Za-z0-9_]+)'
            r'(?: attempt=\d+)?$',
            multiLine: true)
        .allMatches(lines.join('\n'))
        .map((match) => match[1])
        .toSet();
    if (selections.length != 1) {
      return 'native Dart selection ambiguous';
    }
    final results = RegExp(
        r'^PATROL_RESULT name=(.*?) attempt=(\d+) '
        r'passed=(true|false) details=.*$',
        multiLine: true);
    final records = results.allMatches(lines.join('\n')).toList();
    if (lines.where((line) => line.startsWith('PATROL_RESULT ')).length != records.length) {
      return 'native Dart result malformed';
    }
    final expected = records.length == 1 ? _expectedDartName(records.single[1]!, description, names) : null;
    if (expected == null || !_iosDartRecordPassed(records.single)) {
      return 'native Dart result failed, repeated or does not match selected journey';
    }
    if (!completed.add(expected)) {
      return 'native Dart completion repeated across selected sessions';
    }
    return null;
  }

  bool _iosDartRecordPassed(RegExpMatch record) => record[3] == 'true' && int.parse(record[2]!) > 0;

  /// The expected `<file> <description>` name [actual] reports. Dart prefixes
  /// a test's description with its enclosing `group()` names, so the reported
  /// name may carry group segments between the file and the description.
  String? _expectedDartName(String actual, String description, Set<String> names) {
    for (final name in names) {
      final file = name.substring(0, name.length - description.length).trimRight();
      if (actual == name || actual.startsWith('$file ') && actual.endsWith(' $description')) {
        return name;
      }
    }
    return null;
  }

  Future<String?> _androidInstrumentationFailure(Map<String, dynamic> response, Map<String, String> headers,
      {required Map job, required Set<String> selected, required Map<String, String> env}) async {
    String? failure;
    for (final session in response['data'] as List) {
      if (session['status'] != 'passed') {
        continue;
      }
      final verdict = await _androidSessionVerdict(response, session, headers, job, selected, env);
      failure ??= verdict;
    }
    return failure;
  }

  Future<String?> _androidSessionVerdict(Map<String, dynamic> response, Map session, Map<String, String> headers,
      Map job, Set<String> selected, Map<String, String> env) async {
    final id = session['sessionID'] as String;
    final log = await _fetchLtSessionInstrumentationLog(sessionId: id, headers: headers);
    if (log == null) {
      await _annotateAndroidNonpass(response, session, headers, job, selected,
          outcome: AndroidInstrumentationOutcome.unavailable);
      return 'native session $id instrumentation is unavailable; '
          'cannot verify Android execution';
    }
    final verdict = androidInstrumentationVerdict(log, nativeIdentity: session['scenario_name'] as String);
    _recordAndroidVerdict(id, session['scenario_name'] as String, verdict, log, env: env);
    if (verdict.outcome == AndroidInstrumentationOutcome.passed) {
      return null;
    }
    if (verdict.outcome == AndroidInstrumentationOutcome.skipped) {
      await _annotateAndroidNonpass(response, session, headers, job, selected, outcome: verdict.outcome);
      if (itSkipHasReason(verdict.detail)) {
        _logger.info('not-run: ${verdict.detail}');
        return null;
      }
    }
    return verdict.detail;
  }

  Future<void> _annotateAndroidNonpass(
      Map<String, dynamic> response, Map session, Map<String, String> headers, Map job, Set<String> selected,
      {required AndroidInstrumentationOutcome outcome}) async {
    final annotation = await annotateNativeNonpass(
        http: getDep<LtHttp>(),
        headers: headers,
        job: job,
        sessions: response['data'] as List,
        session: session,
        selected: selected,
        outcome: outcome);
    _logger.warn(annotation);
  }

  Future<Map<String, dynamic>> _hyperexecuteJson(String suffix, Map<String, String> headers) async {
    final response = await getDep<LtHttp>().get(
      'https://api.hyperexecute.cloud/v2.0/job/$suffix',
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw HttpException('HyperExecute verdict GET returned HTTP ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  String? _hyperexecuteJobFailure(dynamic data, String jobId) {
    if (data is! Map || data['id'] != jobId) {
      return 'provider response did not identify current job $jobId';
    }
    if (data['status'] != 'passed') {
      return 'job $jobId status is ${data['status']} (not passed)';
    }
    return _hyperexecutePassedJobFailure(data);
  }

  String? _hyperexecutePassedJobFailure(Map data) {
    final tasks = data['taskCount'];
    final countFailure = _hyperexecuteCountFailure(tasks);
    if (countFailure != null) {
      return countFailure;
    }
    if (data['totalTests'] is! int || data['totalTests'] <= 0) {
      return 'current job has no positive native test count';
    }
    if (_hyperexecuteTaskIds(data['tasks'])?.length != tasks['total']) {
      return 'current job has incomplete task identity evidence';
    }
    return null;
  }

  String? _hyperexecuteCountFailure(dynamic counts) {
    if (counts is! Map) {
      return 'missing passed task counts';
    }
    final total = counts['total'];
    if (total is! int || total <= 0 || counts['passed'] != total) {
      return 'zero or incomplete passed tasks';
    }
    final otherCounts = Map<Object?, Object?>.of(counts)
      ..remove('total')
      ..remove('passed');
    if (otherCounts.values.any((count) => count != 0)) {
      return 'non-passed task counts';
    }
    return null;
  }

  String? _hyperexecuteSessionFailure(Map<String, dynamic> response, Map job, Set<String>? expectedNativeTests) {
    final sessions = response['data'];
    if (sessions is! List || sessions.isEmpty) {
      return 'current job has no executed native sessions';
    }
    final metadata = response['metadata'];
    if (!_hyperexecuteSessionsComplete(metadata, sessions.length)) {
      return 'current native-session evidence is incomplete (including pagination)';
    }
    final taskIds = _hyperexecuteTaskIds(job['tasks'])!;
    return _hyperexecuteSessionOutcomesFailure(sessions, taskIds, expectedNativeTests);
  }

  bool _hyperexecuteSessionsComplete(dynamic metadata, int count) {
    return metadata is Map && metadata['hasmore'] == false && metadata['total'] == count;
  }

  String? _hyperexecuteSessionOutcomesFailure(List sessions, Set<String> taskIds, Set<String>? selected) {
    final outcomes = <(String, String), Set<String>>{};
    for (final session in sessions) {
      final name = _hyperexecuteSessionName(session, taskIds);
      if (name == null) {
        return 'native session is not identified in the current job';
      }
      final status = session['status'];
      if (status != 'passed' && status != 'failed') {
        return 'native session ${session['sessionID']} status is $status (not passed)';
      }
      final key = (session['taskID'] as String, name);
      outcomes.putIfAbsent(key, () => <String>{}).add(status as String);
    }
    return _hyperexecuteNativeCoverageFailure(outcomes, taskIds, selected);
  }

  String? _hyperexecuteNativeCoverageFailure(
      Map<(String, String), Set<String>> outcomes, Set<String> tasks, Set<String>? selected) {
    if (selected == null || selected.isEmpty) {
      return 'selected generated native identities are unavailable; regenerate the runner';
    }
    final names = outcomes.keys.map((key) => key.$2).toSet();
    if (names.length != selected.length || !names.containsAll(selected)) {
      return 'current job native tests do not exactly match selected generated identities';
    }
    if (!outcomes.keys.map((key) => key.$1).toSet().containsAll(tasks)) {
      return 'current job lacks native execution evidence for every successful task';
    }
    if (outcomes.values.any((statuses) => !statuses.contains('passed'))) {
      return 'current job lacks a positive native pass for every task/test pair';
    }
    return null;
  }

  Set<String>? _androidArtifactSelection(AndroidLtArtifacts artifacts,
      {required String repo, String? target, String? targetRegex, String? sdk}) {
    try {
      final selection = artifacts.selection;
      final names = artifacts.selectedNativeTests;
      if (selection == null || selection.platform != 'android' || names == null || names.isEmpty) {
        throw StateError('Android artifact selection plan is missing, empty or wrong-platform');
      }
      if (names.length != selection.selectedCount) {
        throw StateError('Android artifact selection has ambiguous native identities');
      }
      selection.validate(repo, target: target, targetRegex: targetRegex, sdk: sdk);
      return Set.unmodifiable(names);
      // Selection validation uses StateError for stale or mismatched artifact plans.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _logger.err('HyperExecute Android artifact plan refused: $error');
      return null;
    }
  }

  /// Every session of HyperExecute job [jobId], across the provider's pages.
  /// Each page's `metadata.total` counts that page's sessions only (a job of
  /// 21 sessions answers total 20 with `hasmore`, then total 1), so every page
  /// must hold exactly its total of new sessions; a repeated session or cursor,
  /// or more than [_maxHyperexecuteSessionPages] pages, fails closed.
  Future<Map<String, dynamic>> _hyperexecuteSessions(String jobId, Map<String, String> headers) async {
    var response = await _hyperexecuteJson('$jobId/sessions?limit=20', headers);
    final sessions = <String, Map<String, dynamic>>{};
    final cursors = <String>{};
    for (var page = 1;; page++) {
      final metadata = _hyperexecuteSessionPage(response);
      _mergeHyperexecuteSessions(sessions, response['data']);
      if (metadata['hasmore'] == false) {
        return {
          'data': sessions.values.toList(),
          'metadata': {'total': sessions.length, 'hasmore': false}
        };
      }
      if (page >= _maxHyperexecuteSessionPages) {
        throw const FormatException('Native-session pagination exceeded the page limit');
      }
      final cursor = _hyperexecuteNextCursor(metadata, cursors);
      response =
          await _hyperexecuteJson('$jobId/sessions?limit=20&cursor=${Uri.encodeQueryComponent(cursor)}', headers);
    }
  }

  /// The pagination metadata of one sessions page, whose `total` must be the
  /// number of sessions on that page.
  Map _hyperexecuteSessionPage(Map<String, dynamic> response) {
    final metadata = response['metadata'];
    if (metadata is! Map || metadata['hasmore'] is! bool) {
      throw const FormatException('Missing native-session pagination metadata');
    }
    final total = metadata['total'];
    final data = response['data'];
    if (total is! int || data is! List || total != data.length) {
      throw const FormatException('Native-session page count does not match provider total');
    }
    return metadata;
  }

  String _hyperexecuteNextCursor(Map metadata, Set<String> cursors) {
    final cursor = metadata['cursor'];
    if (cursor is! String || cursor.isEmpty || !cursors.add(cursor)) {
      throw const FormatException('Missing or repeated native-session provider cursor');
    }
    return cursor;
  }

  void _mergeHyperexecuteSessions(Map<String, Map<String, dynamic>> sessions, dynamic data) {
    if (data is! List) {
      throw const FormatException('Invalid native-session page');
    }
    for (final value in data) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid native-session identity');
      }
      final id = value['sessionID'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('Missing native-session ID');
      }
      if (sessions.containsKey(id)) {
        throw const FormatException('Repeated native-session ID');
      }
      sessions[id] = value;
    }
  }

  String? _hyperexecuteSessionName(dynamic session, Set<String> taskIds) {
    if (session is! Map || !taskIds.contains(session['taskID'])) {
      return null;
    }
    final sessionId = session['sessionID'];
    if (sessionId is! String || sessionId.isEmpty) {
      return null;
    }
    final name = session['scenario_name'];
    if (name is! String || name.isEmpty) {
      return null;
    }
    return name;
  }

  Set<String>? _hyperexecuteTaskIds(dynamic tasks) {
    if (tasks is! List) {
      return null;
    }
    final ids = <String>{};
    for (final task in tasks) {
      if (task is! Map || task['status'] != 'passed') {
        return null;
      }
      final id = task['id'];
      if (id is! String || id.isEmpty) {
        return null;
      }
      if (!ids.add(id)) {
        return null;
      }
    }
    return ids;
  }

  Future<int> _reportLtSkippedSessions({
    required String? buildName,
    required Map<String, String> env,
    required String label,
    required PatrolSkipSummary outputSkipSummary,
  }) async {
    if (buildName == null || buildName.isEmpty) {
      return 0;
    }
    final headers = getDep<LtHttp>().basicAuth(env['LT_USERNAME'] ?? '', env['LT_ACCESS_KEY'] ?? '');
    final buildId = await _findLatestLtBuildIdByName(buildName: buildName, headers: headers);
    if (buildId == null) {
      if (outputSkipSummary.hasSkippedTests) {
        _logger.warn(
          'Could not find LambdaTest $label build "$buildName" to mark '
          'skipped session(s).',
        );
      }
      return 0;
    }
    final sessions = await _fetchLtSessions(buildId: buildId, headers: headers);
    if (sessions.isEmpty) {
      if (outputSkipSummary.hasSkippedTests) {
        _logger.warn(
          'LambdaTest $label build "$buildName" had no sessions to mark '
          'skipped.',
        );
      }
      return 0;
    }

    _warnTestsPassedOnRetry(sessions, label);
    var detected = 0;
    for (final session in sessions) {
      final sessionId = _ltSessionId(session);
      if (sessionId == null) {
        continue;
      }
      _recordLtSessionDetails(sessionId, session, label);
      if (!await _ltSessionReportedSkip(
        session: session,
        sessionId: sessionId,
        headers: headers,
        inspectLog: label != 'Android',
      )) {
        continue;
      }
      _results.verdict(ItTestOutcome.notRun, sessionId: sessionId, reason: itRuntimeSkipReason);
      detected++;
    }

    if (detected == 0 && outputSkipSummary.hasSkippedTests && sessions.length == 1) {
      final sessionId = _ltSessionId(sessions.single);
      if (sessionId != null) {
        detected = 1;
      }
    }

    if (detected > 0) {
      _logger.err(
        'LambdaTest $label detected $detected skipped session(s); '
        'skipped tests are non-pass outcomes. The real-device session status '
        'API supports passed/failed only; provider skipped status was not updated.',
      );
    } else if (outputSkipSummary.hasSkippedTests) {
      _logger.warn(
        'HyperExecute output reported ${outputSkipSummary.countLabel} skipped '
        'test(s), but the skipped LambdaTest session could not be mapped.',
      );
    }
    return detected;
  }

  /// A retried test that then passed counts as passed; name it so the flake
  /// stays visible instead of disappearing into a green run.
  void _warnTestsPassedOnRetry(List<Map<String, dynamic>> sessions, String label) {
    final statusesByTest = <String, Set<String>>{};
    for (final session in sessions) {
      final name = session['name']?.toString() ?? '';
      if (name.isNotEmpty) {
        statusesByTest.putIfAbsent(name, () => <String>{}).add(session['status_ind']?.toString() ?? '');
      }
    }
    final flaky = [
      for (final MapEntry(:key, :value) in statusesByTest.entries)
        if (value.contains('passed') && value.contains('failed')) key,
    ]..sort();
    if (flaky.isNotEmpty) {
      _logger.warn(
        'LambdaTest $label: ${flaky.length} test(s) passed only on retry '
        '(flaky): ${flaky.join(', ')}',
      );
    }
  }

  /// Records LambdaTest's own status, timing, device and evidence links of
  /// one session of the current job.
  void _recordLtSessionDetails(String sessionId, Map<String, dynamic> session, String label) {
    final seconds = num.tryParse('${session['duration'] ?? ''}');
    final version = session['version']?.toString();
    _results.session(
        sessionId,
        ItSessionDetails(
          providerStatus: session['status_ind']?.toString(),
          duration: seconds == null ? null : Duration(milliseconds: (seconds * 1000).round()),
          device: session['device']?.toString(),
          os: version == null || version.isEmpty ? null : '$label $version',
          videoUrl: session['video_url']?.toString(),
          deviceLogUrl: session['device_logs']?.toString(),
          buildId: session['build_id']?.toString(),
        ));
  }

  String? _ltSessionId(Map<String, dynamic> session) {
    final sessionId = session['session_id']?.toString() ?? session['test_id']?.toString() ?? '';
    return sessionId.isEmpty ? null : sessionId;
  }

  Future<bool> _ltSessionReportedSkip({
    required Map<String, dynamic> session,
    required String sessionId,
    required Map<String, String> headers,
    required bool inspectLog,
  }) async {
    if (session['status_ind']?.toString().trim().toLowerCase() == 'skipped') {
      return true;
    }
    if (!inspectLog) {
      return false;
    }
    final log = await _fetchLtSessionInstrumentationLog(sessionId: sessionId, headers: headers);
    return patrolSkipSummary(log ?? '').hasSkippedTests;
  }

  Future<String?> _fetchLtSessionInstrumentationLog({
    required String sessionId,
    required Map<String, String> headers,
  }) async {
    final failures = <String>[];
    for (var attempt = 0; attempt < _ltInstrumentationLogAttempts; attempt++) {
      try {
        final response = await getDep<LtHttp>().get(
          'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
          'sessions/$sessionId/log/instrumentation',
          headers: headers,
          timeout: const Duration(seconds: 30),
        );
        if (response.statusCode < 400) {
          return response.body;
        }
        final transport = response.statusCode == 599 ? ' (transport failure)' : '';
        final provider = _instrumentationProviderFailureContext(response.headers, response.body);
        failures.add('attempt ${attempt + 1}: HTTP ${response.statusCode}$transport$provider');
      } catch (error) {
        failures.add('attempt ${attempt + 1}: exception ${error.runtimeType}');
      }
      if (attempt < _ltInstrumentationLogAttempts - 1 && pollDelay > Duration.zero) {
        await Future<void>.delayed(pollDelay);
      }
    }
    _logger.err('LambdaTest native session $sessionId instrumentation fetch exhausted '
        'after $_ltInstrumentationLogAttempts attempts: ${failures.join('; ')}. '
        'Execution remains unverified; check session log publication and API access.');
    return null;
  }

  String _instrumentationProviderFailureContext(Map<String, String> headers, String body) {
    final context = <String>[];
    final code = _instrumentationProviderErrorCode(body);
    if (code != null) {
      context.add('providerCode=$code');
    }
    final normalized = headers.map((name, value) => MapEntry(name.toLowerCase(), value));
    for (final name in ['x-request-id', 'x-correlation-id', 'x-amzn-requestid']) {
      final value = normalized[name];
      if (value != null && value.isNotEmpty && value.length <= 128 && !RegExp('[^A-Za-z0-9._-]').hasMatch(value)) {
        context.add('$name=$value');
      }
    }
    return context.isEmpty ? '' : ' [${context.join(', ')}]';
  }

  String? _instrumentationProviderErrorCode(String body) {
    if (body.length > 4096) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      final error = decoded['error'];
      final codes = [decoded['code'], decoded['error_code'], decoded['errorCode'], if (error is Map) error['code']];
      const allowed = {
        'LOG_NOT_FOUND',
        'SESSION_NOT_FOUND',
        'NOT_FOUND',
        'UNAUTHORIZED',
        'FORBIDDEN',
        'RATE_LIMITED',
        'BAD_REQUEST',
        'INTERNAL_SERVER_ERROR',
        'SERVICE_UNAVAILABLE'
      };
      final recognized = codes.where(allowed.contains).toSet();
      return recognized.length == 1 ? recognized.single as String : null;
    } on FormatException {
      // Optional provider metadata is untrusted; the HTTP failure remains recorded.
      return null;
    }
  }

  Future<void> _reportHyperexecuteDiagnostics({
    required String? buildName,
    required String label,
    required Map<String, String> env,
  }) async {
    if (buildName == null || buildName.isEmpty) {
      return;
    }
    final headers = getDep<LtHttp>().basicAuth(env['LT_USERNAME'] ?? '', env['LT_ACCESS_KEY'] ?? '');
    final buildId = await _findLatestLtBuildIdByName(buildName: buildName, headers: headers);
    if (buildId == null) {
      _logger.warn(
        'Could not find LambdaTest $label build "$buildName" '
        'for diagnostics.',
      );
      return;
    }
    await getDep<LtDiagnostics>().report(buildId: buildId, platform: label, env: env);
  }

  Future<void> _renameAssignedIosSessions({
    required String buildName,
    required _IosShardCoordinator coordinator,
    required Map<String, String> env,
  }) async {
    final assignments = coordinator.waveAssignments;
    if (assignments.isEmpty) {
      _logger.warn(
        '[ios-shard-coordinator] no assignments were recorded; '
        'skipping LT session renames.',
      );
      return;
    }
    final headers = getDep<LtHttp>().basicAuth(env['LT_USERNAME']!, env['LT_ACCESS_KEY']!);
    final buildId = await _findLatestLtBuildIdByName(buildName: buildName, headers: headers);
    if (buildId == null) {
      // coverage:ignore-start
      _logger.warn(
        '[ios-shard-coordinator] could not find LT build '
        '"$buildName"; skipping session renames.',
      );
      return;
      // coverage:ignore-end
    }
    final sessions = await _fetchLtSessions(buildId: buildId, headers: headers);
    if (sessions.isEmpty) {
      // coverage:ignore-start
      _logger.warn(
        '[ios-shard-coordinator] build $buildId had no sessions; '
        'skipping session renames.',
      );
      return;
      // coverage:ignore-end
    }
    final assignmentByMethod = {for (final assignment in assignments) assignment.method: assignment};
    final fallbackAssignments = assignments.toList();
    final usedFallbackMethods = <String>{};
    var instrumentationMatches = 0;
    if (assignments.length != sessions.length) {
      _logger.warn(
        '[ios-shard-coordinator] assignment/session count mismatch '
        '(${assignments.length}/${sessions.length}); renaming '
        '${sessions.length}.',
      );
    }
    sessions.sort(_compareLtSessionStart);
    for (var index = 0; index < sessions.length; index++) {
      final session = sessions[index];
      final sessionId = _ltSessionId(session);
      if (sessionId == null) {
        continue;
      }
      final selectedMethod = await _fetchLtSessionSelectedMethod(sessionId: sessionId, headers: headers);
      final assignment = selectedMethod == null
          ? _nextFallbackAssignment(fallbackAssignments, usedFallbackMethods)
          : assignmentByMethod[selectedMethod] ??
              _IosShardAssignment(method: selectedMethod, description: selectedMethod);
      if (assignment == null) {
        _logger.warn(
          '[ios-shard-coordinator] no assignment available for '
          '$sessionId; skipping rename.',
        );
        continue;
      }
      if (selectedMethod != null) {
        instrumentationMatches++;
      }
      usedFallbackMethods.add(assignment.method);
      _results.session(sessionId, ItSessionDetails(testId: assignment.method));
      try {
        final response = await getDep<LtHttp>().patchJson(
          'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
          'sessions/$sessionId',
          headers: headers,
          body: {
            'name': assignment.method,
            'custom_data': {
              'mplatrol_assigned_method': assignment.method,
              'mplatrol_assigned_description': assignment.description,
              'mplatrol_assignment_order': index + 1,
              'mplatrol_assignment_source': selectedMethod == null ? 'coordinator-order' : 'instrumentation',
            },
          },
        );
        if (response.statusCode >= 400) {
          _logger.warn(
            '[ios-shard-coordinator] rename failed for $sessionId '
            '(HTTP ${response.statusCode}).',
          );
        }
      } catch (error) {
        // coverage:ignore-start
        _logger.warn(
          '[ios-shard-coordinator] rename failed for $sessionId: '
          '$error',
        );
        // coverage:ignore-end
      }
    }
    if (instrumentationMatches != sessions.length) {
      _logger.warn(
        '[ios-shard-coordinator] matched $instrumentationMatches/'
        '${sessions.length} session title(s) from instrumentation logs; '
        'used coordinator order for the rest.',
      );
    }
  }

  Future<String?> _findLatestLtBuildIdByName({required String buildName, required Map<String, String> headers}) async {
    try {
      final response = await getDep<LtHttp>().get(
        'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
        'builds?limit=30&sort=desc.create_timestamp',
        headers: headers,
        timeout: const Duration(seconds: 30),
      );
      final data = tryDecodeObject(response.body)?['data'];
      if (data is! List) {
        return null;
      }
      for (final item in data) {
        if (item is! Map) {
          continue;
        }
        if (item['name']?.toString() != buildName) {
          continue;
        }
        final id = item['build_id']?.toString();
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    } catch (_) {
      // Fall back below.
    }
    return _findLatestLtBuildIdFromSessions(buildName: buildName, headers: headers);
  }

  Future<String?> _findLatestLtBuildIdFromSessions({
    required String buildName,
    required Map<String, String> headers,
  }) async {
    try {
      final response = await getDep<LtHttp>().get(
        'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
        'sessions?limit=20&build=${Uri.encodeQueryComponent(buildName)}',
        headers: headers,
        timeout: const Duration(seconds: 30),
      );
      final data = tryDecodeObject(response.body)?['data'];
      if (data is! List) {
        return null;
      }
      for (final item in data) {
        if (item is! Map) {
          continue;
        }
        if (item['build_name']?.toString() != buildName) {
          continue;
        }
        final id = item['build_id']?.toString();
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchLtSessions({
    required String buildId,
    required Map<String, String> headers,
  }) async {
    try {
      final response = await getDep<LtHttp>().get(
        'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
        'sessions?build_id=$buildId&limit=100',
        headers: headers,
        timeout: const Duration(seconds: 30),
      );
      final data = tryDecodeObject(response.body)?['data'];
      if (data is! List) {
        return const [];
      }
      return [
        for (final item in data)
          if (item is Map<String, dynamic>) item,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _fetchLtSessionSelectedMethod({
    required String sessionId,
    required Map<String, String> headers,
  }) async {
    for (var attempt = 0; attempt < _ltInstrumentationLogAttempts; attempt++) {
      try {
        final response = await getDep<LtHttp>().get(
          'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
          'sessions/$sessionId/log/instrumentation',
          headers: headers,
          timeout: const Duration(seconds: 30),
        );
        if (response.statusCode < 400) {
          final method = _selectedMethodFromInstrumentation(response.body);
          if (method != null) {
            return method;
          }
        }
      } catch (_) {
        // LT can lag briefly before instrumentation logs are available.
      }
      if (attempt < _ltInstrumentationLogAttempts - 1 && pollDelay > Duration.zero) {
        await Future<void>.delayed(pollDelay);
      }
    }
    return null;
  }

  String? _selectedMethodFromInstrumentation(String body) {
    final match = RegExp(r'PATROL_SELECTION_SOURCE source=\S+ method=([A-Za-z0-9_]+)').firstMatch(body);
    return match?.group(1);
  }

  _IosShardAssignment? _nextFallbackAssignment(List<_IosShardAssignment> assignments, Set<String> usedMethods) {
    for (final assignment in assignments) {
      if (!usedMethods.contains(assignment.method)) {
        return assignment;
      }
    }
    return null;
  }

  int _compareLtSessionStart(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byStart = _sessionSortKey(a).compareTo(_sessionSortKey(b));
    if (byStart != 0) {
      return byStart;
    }
    return (a['session_id'] ?? '').toString().compareTo((b['session_id'] ?? '').toString());
  }

  String _sessionSortKey(Map<String, dynamic> session) {
    for (final key in ['start_timestamp', 'create_timestamp', 'session_id']) {
      final value = session[key]?.toString();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _hyperexecuteBinary(String repo, Map<String, String> env) {
    final explicit = env['HYPEREXECUTE_BIN'];
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final local = p.join(repo, 'hyperexecute');
    if (File(local).existsSync()) {
      return local;
    }
    return _shell.whichSync('hyperexecute') ?? _cachedHyperexecuteBinary() ?? 'hyperexecute';
  }

  Future<String> _fallbackBuildName({required String prefix, required String workingDirectory}) async {
    final gitName = await gitBuildName(prefix: prefix, workingDirectory: workingDirectory);
    final now = DateTime.now().toUtc();
    final stamp = '${_digits(now.year, 4)}${_digits(now.month)}'
        '${_digits(now.day)}T${_digits(now.hour)}${_digits(now.minute)}'
        '${_digits(now.second)}Z';
    return '$gitName-$stamp';
  }

  String _digits(int value, [int width = 2]) => value.toString().padLeft(width, '0');

  String? _cachedHyperexecuteBinary() {
    final home = _platform.environment['HOME'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return null;
    }
    final cached = p.join(home, '.hyperexecute', 'hyperexecute');
    return File(cached).existsSync() ? cached : null;
  }

  void _writeFile(String path, String content) {
    Directory(p.dirname(path)).createSync(recursive: true);
    _fileSystem.writeAsStringSync(filePath: path, newContent: content);
    _logger.info('[hyperexecute] wrote ${p.relative(path)}');
  }

  void _logHyperexecuteSummary(ProcessResultX result) {
    final interesting = <String>[];
    final seen = <String>{};
    for (final raw in [...result.outLines, ...result.errLines]) {
      final line = _redact(raw);
      if (_isHyperexecuteProgressNoise(line)) {
        continue;
      }
      if (line.contains('Build Link:') ||
          line.contains('Job ID:') ||
          line.contains('Total tests discovered:') ||
          line.contains('Test Execution Time:') ||
          line.contains('Pass test stage percentage:') ||
          line.contains('Failed Tasks:') ||
          line.contains('Failed tasks found') ||
          line.contains('ERR::TUN::') ||
          line.contains('completed successfully') ||
          RegExp(r'("msg":")?x \[\d+\]').hasMatch(line)) {
        if (!seen.add(line)) {
          continue;
        }
        interesting.add(line);
      }
    }
    interesting.take(80).forEach(_logger.info);
  }

  bool _isHyperexecuteProgressNoise(String line) {
    return line.contains('taskId:') || line.contains(' stages completed') || line.trim().isEmpty;
  }

  String _redact(String value) {
    var redacted = value.replaceAllMapped(RegExp(r'(--key\s+)[^\]\s"]+'), (match) => '${match[1]}<redacted>');
    redacted = redacted.replaceAllMapped(RegExp(r'("key"\s*:\s*")[^"]+'), (match) => '${match[1]}<redacted>');
    redacted = redacted.replaceAll(RegExp('(LT_[A-Za-z0-9]{12,})'), '<redacted>');
    redacted = redacted.replaceAllMapped(
      RegExp(r'([?&](?:token|verify|access[_-]?key)=)[^&\s"]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
    return redacted;
  }

  List<String> _missing(Map<String, String> env, List<String> required) =>
      required.where((key) => (env[key] ?? '').isEmpty).toList();

  String _androidYaml({
    required String buildName,
    required String appId,
    required String testSuiteAppId,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required int concurrency,
    String? tenantLabel,
    String? environmentLabel,
    Set<String>? onlyTests,
    bool captureNetwork = true,
  }) {
    final deviceList = _yamlInlineList(devices);
    return '''
version: "0.2"
globalTimeout: 150
concurrency: $concurrency
runson: android
autosplit: true
maxRetries: $_maxRetries
retryOnFailure: ${_maxRetries > 0}
framework:
  name: "android/espresso"
  args:
    buildName: ${_yamlString(buildName)}
    appId: ${_yamlString(appId)}
    testSuiteAppId: ${_yamlString(testSuiteAppId)}
    video: true
    deviceLog: true
    network: $captureNetwork
    tunnel: true
    localhost: true
    mitmProxy: $captureNetwork
    idleTimeout: $idleTimeoutSeconds
    deviceSelectionStrategy: any
    devices: $deviceList
${onlyTests == null ? '' : _androidTestFilter(onlyTests)}tunnel: true
jobLabel: ${_yamlJobLabel(
      staticLabels: const ['Espresso', 'mplatrol-it'],
      tenantLabel: tenantLabel,
      environmentLabel: environmentLabel,
    )}
''';
  }

  /// The HyperExecute filter that runs only [tests] (`class/method` native identities) of the uploaded test
  /// APK, as AndroidJUnitRunner `class` values `class#method`. Verified on LambdaTest 2026-10-15: job
  /// fdf64287-ce39-4a16-9d8f-59bf096a20a6 ran exactly its 2 filtered methods of an uploaded 40-method suite.
  String _androidTestFilter(Set<String> tests) => '''
    filters:
      attributes:
        - type: class
          values: ${_yamlInlineList([for (final test in tests) test.replaceFirst('/', '#')])}
''';

  String _iosYaml({
    required String buildName,
    required String appId,
    required String testSuiteAppId,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required _IosWave wave,
    required int shardCount,
    String? tenantLabel,
    String? environmentLabel,
    bool captureNetwork = true,
  }) {
    // HyperExecute runs every shard mapping on its own device at once,
    // whatever `concurrency` says, so `concurrency` states the mapping count and
    // the device cap comes from listing only one wave's shards (see
    // [_runIosDeviceJob]).
    return '''
version: "0.2"
globalTimeout: 150
concurrency: ${wave.length}
runson: ios
autosplit: true
maxRetries: $_iosMaxRetries
retryOnFailure: ${_iosMaxRetries > 0}
framework:
  name: "ios/xcui"
  args:
    buildName: ${_yamlString(buildName)}
    appId: ${_yamlString(appId)}
    testSuiteAppId: ${_yamlString(testSuiteAppId)}
    video: true
    idleTimeout: $idleTimeoutSeconds
    resignApp: true
    deviceLog: true
    network: $captureNetwork
    tunnel: true
    localhost: true
    mitmProxy: $captureNetwork
    deviceSelectionStrategy: any
    devices: ${_yamlInlineList(devices)}
    shards:
      mappings:
${_iosShardMappings(wave, shardCount)}
tunnel: true
jobLabel: ${_yamlJobLabel(
      staticLabels: const ['XCUI', 'mplatrol-it'],
      tenantLabel: tenantLabel,
      environmentLabel: environmentLabel,
    )}
''';
  }

  String _yamlJobLabel({
    required List<String> staticLabels,
    String? tenantLabel,
    String? environmentLabel,
  }) {
    final labels = [
      if (tenantLabel != null && tenantLabel.trim().isNotEmpty) tenantLabel.trim(),
      if (environmentLabel != null && environmentLabel.trim().isNotEmpty) environmentLabel.trim(),
      ...staticLabels,
    ];
    return '[${labels.map(_yamlString).join(', ')}]';
  }

  String _iosShardMappings(_IosWave wave, int shardCount) {
    // Name shards generically ("shard 1".."shard N"), like Android's autosplit.
    // HyperExecute launches one synthetic XCTest method per mapping. Each
    // synthetic method asks the local coordinator which real Patrol test this
    // session owns, then dispatches to that method. Mapping to the class makes
    // LT expand every real method into duplicate sessions; mapping to the real
    // methods lets LT/XCTest filtering race the coordinator.
    final mappings = <String>[];
    for (final i in wave) {
      mappings.add('''
        - name: "shard ${i + 1}"
          strategy: "only-testing"
          values: ${_yamlInlineList([iosCoordinatorShardOnlyTesting(i, shardCount)])}''');
    }
    return mappings.join('\n');
  }

  /// Whether a job over [selection] captures LambdaTest network logs: not when a selected test file needs an SDK
  /// the manifest lists under [certificatePinningSdksKey], which LambdaTest's capture proxy breaks.
  bool _capturesNetwork(String repo, PatrolSelectionPlan selection, String label) {
    final pinning = patrolCertificatePinningFiles(repo);
    final files = [
      for (final file in selection.files)
        if (pinning.contains(file.basename)) file.basename
    ];
    if (files.isEmpty) {
      return true;
    }
    _logger.info('[lt-network] $label: no LambdaTest network log for this job: ${files.join(', ')} need a '
        'certificate-pinning SDK ($certificatePinningSdksKey), which its capture proxy breaks.');
    return false;
  }

  String _yamlInlineList(List<String> values) => '[${values.map(_yamlString).join(', ')}]';

  String _yamlString(String value) => '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"';

  static const _iosRequiredEnv = ['LT_USERNAME', 'LT_ACCESS_KEY', 'LT_BIN'];

  static const _androidRequiredEnv = ['LT_USERNAME', 'LT_ACCESS_KEY', 'LT_BIN'];

  static const _ltInstrumentationLogAttempts = 4;

  /// At most 50 pages of 20 sessions: far above any job, so a provider that
  /// keeps paging never loops forever.
  static const _maxHyperexecuteSessionPages = 50;
}

/// How the non-passing sessions of an iOS wave ended (see `_recordIosWaveSessionOutcomes`).
enum _IosWaveNonPass { skipped, infrastructure, failed }

class _IosShardAssignment {
  const _IosShardAssignment({required this.method, required this.description});

  final String method;
  final String description;
}

class _IosShardCoordinator {
  _IosShardCoordinator._(
      {required HttpServer server, required List<IosTestShard> shards, required MplatrolLogger logger})
      : _server = server,
        _shards = shards,
        _logger = logger;

  final HttpServer _server;
  final List<IosTestShard> _shards;
  final MplatrolLogger _logger;
  final _assignments = <_IosShardAssignment>[];
  final _assignmentsBySessionKey = <String, _IosShardAssignment>{};
  final _verifiedDartNames = <String>{};
  final _failedMethods = <String>{};
  final _skippedMethods = <String, String>{};
  late _IosWave _wave = [for (var index = 0; index < _shards.length; index++) index];
  int _next = 0;
  int _waveAssignmentStart = 0;
  final _retryShards = <int>[];
  bool _waveDeferredToRetry = false;

  String get url => 'http://localhost.lambdatest.com:${_server.port}/assign';

  /// Every assignment since the last [reset], across all waves.
  List<_IosShardAssignment> get assignments => List.unmodifiable(_assignments);

  /// The assignments made since the current wave began (see [beginWave]).
  List<_IosShardAssignment> get waveAssignments => List.unmodifiable(_assignments.sublist(_waveAssignmentStart));

  /// The shards the current wave may assign.
  List<IosTestShard> get waveShards => [for (final index in _wave) _shards[index]];

  /// Whether the current wave owns only part of the shards, so a device job
  /// runs in several waves.
  bool get isSplit => _wave.length < _shards.length;

  /// Shard indices left to the retry wave by [deferWaveToRetry].
  List<int> get retryShards => List.unmodifiable(_retryShards);

  /// Whether the current wave left its unassigned shards to the retry wave.
  bool get waveDeferredToRetry => _waveDeferredToRetry;

  /// Leaves the current wave's unassigned shards to the retry wave: every
  /// session that got a shard verified it, and the rest never reached the
  /// coordinator, so those shards did not run at all.
  void deferWaveToRetry() {
    _retryShards.addAll(_wave.sublist(_next));
    _waveDeferredToRetry = true;
  }

  int get shardCount => _shards.length;

  /// Dart test names verified by the waves since the last [reset].
  Set<String> get verifiedDartNames => Set.unmodifiable(_verifiedDartNames);

  /// Restricts assignment to [wave]'s shards, keeping earlier waves'
  /// assignments: a wave session never takes another wave's shard, and a shard
  /// its wave left unassigned stays unassigned.
  void beginWave(_IosWave wave) {
    _wave = wave;
    _next = 0;
    _waveAssignmentStart = _assignments.length;
    _waveDeferredToRetry = false;
  }

  /// Methods whose assigned test failed in a wave since the last [reset].
  Set<String> get failedMethods => Set.unmodifiable(_failedMethods);

  /// Methods whose assigned test skipped itself at runtime, with the reason.
  Map<String, String> get skippedMethods => Map.unmodifiable(_skippedMethods);

  /// Records that [method]'s assigned test ran and failed.
  void recordFailedMethod(String method) => _failedMethods.add(method);

  /// Records that [method]'s assigned test skipped itself at runtime.
  void recordSkippedMethod(String method, String reason) => _skippedMethods[method] = reason;

  /// The descriptions of the tests that skipped themselves at runtime with a reason (see [itSkipHasReason]).
  Set<String> get explainedSkipDescriptions => {
        for (final shard in _shards)
          if (itSkipHasReason(_skippedMethods[shard.method])) shard.description,
      };

  /// Whether every test of the current wave that skipped itself at runtime said why.
  bool get waveSkipsExplained => waveAssignments
      .map((assignment) => _skippedMethods[assignment.method])
      .whereType<String>()
      .every(itSkipHasReason);

  /// Records [names] as one wave's verified Dart results. False when a name
  /// was already verified by an earlier wave of this device job.
  bool recordVerifiedDartNames(Set<String> names) {
    final fresh = _verifiedDartNames.intersection(names).isEmpty;
    _verifiedDartNames.addAll(names);
    return fresh;
  }

  static Future<_IosShardCoordinator> start({
    required List<IosTestShard> shards,
    required MplatrolLogger logger,
    required int port,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final coordinator = _IosShardCoordinator._(server: server, shards: List.unmodifiable(shards), logger: logger);
    server.listen(coordinator._handle);
    logger.info(
      '[ios-shard-coordinator] listening on '
      'localhost.lambdatest.com:${server.port} for ${shards.length} shard(s)',
    );
    return coordinator;
  }

  Future<void> close() => _server.close(force: true);

  /// Forgets every assignment and verified result, and reopens every shard,
  /// so the next device job can be assigned the same shards again. Only valid between jobs: an
  /// assignment request carries session ids but no device identity, so two
  /// concurrent device jobs would draw from one shard set and each run only
  /// part of it.
  void reset() {
    _assignments.clear();
    _assignmentsBySessionKey.clear();
    _verifiedDartNames.clear();
    _failedMethods.clear();
    _skippedMethods.clear();
    _retryShards.clear();
    beginWave([for (var index = 0; index < _shards.length; index++) index]);
  }

  /// Forgets the assignments, outcomes and verified Dart results ([dartNames], by description) of the shards
  /// [indices], so a later wave can assign and verify them once more. Only valid between waves.
  void reopen(List<int> indices, Map<String, Set<String>> dartNames) {
    final methods = {for (final index in indices) _shards[index].method};
    _assignments.removeWhere((assignment) => methods.contains(assignment.method));
    _assignmentsBySessionKey.removeWhere((_, assignment) => methods.contains(assignment.method));
    _failedMethods.removeAll(methods);
    _skippedMethods.removeWhere((method, _) => methods.contains(method));
    _retryShards.removeWhere(indices.contains);
    for (final index in indices) {
      _verifiedDartNames.removeAll(dartNames[_shards[index].description] ?? const <String>{});
    }
  }

  /// Checks local HTTP readiness without allocating a shard.
  ///
  /// Returns false on transport, response or deadline failure. This checks only
  /// loopback transport, not the provider tunnel or device path. The client is
  /// always closed; the caller remains responsible for closing the coordinator.
  Future<bool> checkLocalReadiness() async {
    final client = HttpClient();
    int? status;
    try {
      await (() async {
        final request = await client.getUrl(Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: '/nope'));
        request.headers.set(HttpHeaders.hostHeader, 'localhost.lambdatest.com');
        final response = await request.close();
        status = response.statusCode;
        final body = await utf8.decoder.bind(response).join();
        if (status != HttpStatus.notFound || body != '{"error":"not found"}') {
          throw const FormatException('Unexpected local readiness response');
        }
      })()
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (error) {
      _logger.err(
        'Local iOS coordinator readiness GET /nope failed on loopback port '
        '${_server.port} (${error.runtimeType}, HTTP ${status ?? 'unavailable'}). '
        'Check the local listener and HTTP response; the operation has a 2s '
        'budget. No cloud/device connectivity was tested.',
      );
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET' || request.uri.path != '/assign') {
        _writeJson(request, HttpStatus.notFound, {'error': 'not found'});
        return;
      }
      final xctestSession = (request.uri.queryParameters['xctestSession'] ?? '').trim();
      final runnerSession = (request.uri.queryParameters['runnerSession'] ?? '').trim();
      if (xctestSession.isEmpty && runnerSession.isEmpty) {
        _logger.warn(
          '[ios-shard-coordinator] rejected assignment request '
          'without XCTestSessionIdentifier or runnerSession.',
        );
        _writeJson(request, HttpStatus.preconditionRequired, {'error': 'xctestSession or runnerSession is required'});
        return;
      }
      final sessionKey = runnerSession.isEmpty ? 'xctestSession:$xctestSession' : 'runnerSession:$runnerSession';
      final existing = _assignmentsBySessionKey[sessionKey];
      if (existing != null) {
        _writeJson(request, HttpStatus.ok, {'method': existing.method});
        return;
      }
      if (_next >= _wave.length) {
        _writeJson(request, HttpStatus.conflict, {'error': 'all shards already assigned'});
        return;
      }
      final shard = _shards[_wave[_next++]];
      final assignment = _IosShardAssignment(method: shard.method, description: shard.description);
      _assignments.add(assignment);
      _assignmentsBySessionKey[sessionKey] = assignment;
      _logger.info(
        '[ios-shard-coordinator] assigned ${assignment.method} '
        '(${_assignments.length}/${_shards.length})',
      );
      _writeJson(request, HttpStatus.ok, {'method': assignment.method});
      // coverage:ignore-start
    } catch (error) {
      _writeJson(request, HttpStatus.internalServerError, {'error': error.toString()});
    }
    // coverage:ignore-end
  }

  void _writeJson(HttpRequest request, int statusCode, Map<String, Object?> body) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }
}

/// Everything one Android device job needs, shared by its first job and its retry.
typedef _AndroidRunPlan = ({
  String jobRoot,
  Map<String, String> env,
  AndroidLtArtifacts artifacts,
  Set<String> selected,
  int idleTimeoutSeconds,
  int maxParallel,
  String? tenantLabel,
  String? environmentLabel,
  bool captureNetwork,
});

/// Everything one iOS device job needs, shared by its waves.
typedef _IosRunPlan = ({
  String repo,
  Map<String, String> env,
  IosHyperexecuteArtifacts artifacts,
  int idleTimeoutSeconds,
  List<IosTestShard> shards,
  Map<String, Set<String>> dartNames,
  PatrolSelectionPlan selection,
  _IosShardCoordinator? coordinator,
  int maxParallel,
  String? tenantLabel,
  String? environmentLabel,
  bool captureNetwork,
});

/// One iOS session's verification: the failure (null for a verified pass),
/// its instrumentation log and the Dart selection method it ran, when known.
typedef _IosSessionVerdict = ({String? failure, String? log, String? method});

/// The shard indices run as one HyperExecute job, in assignment order.
typedef _IosWave = List<int>;

typedef _StallWatch = ({
  Future<void> detected,
  Future<String?> diagnostic,
  void Function() stop,
});

/// One running LambdaTest leg of [LtHyperexecuteRunner] and, once known, its test users' session cap.
class _UserLeg {
  _UserLeg(this.label);

  final String label;
  LtUserSessionCap? cap;

  /// The leg's presence in [cap]; null without a cap.
  LtUserLeg? present;

  /// Joins [found] (null for none) the first time a cap is known.
  void join(LtUserSessionCap? found) {
    if (cap != null || found == null) {
      return;
    }
    cap = found;
    present = found.join(label);
  }
}
