import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/android_sdk_build_identity.dart';
import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/lt_app_upload.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/transient_build_failure.dart';
import 'package:path/path.dart' as p;

class AndroidLtArtifacts {
  AndroidLtArtifacts({required this.appId, required this.testSuiteAppId, this.selection});

  final String appId;
  final String testSuiteAppId;
  final PatrolSelectionPlan? selection;

  /// Exact native identifiers selected for these uploaded artifacts, not a verdict.
  Set<String>? get selectedNativeTests => selection == null
      ? null
      : {
          for (final file in selection!.files)
            for (final test in file.tests) androidLtNativeIdentity(file.basename, test.method),
        };
}

/// The `class/method` identity LambdaTest and the instrumentation report for
/// the generated Android test [method] of Patrol test file [basename].
String androidLtNativeIdentity(String basename, String method) =>
    'mplatrol.e2e.${androidPatrolTestClassName(basename)}/$method';

/// Drives the LambdaTest Android login E2E end to end: start one fresh tunnel,
/// `patrol build android`, upload the app APK and test APK directly to
/// LambdaTest, trigger the Espresso run, then poll the build until a terminal
/// status and pass only on `passed`.
///
/// This is the Dart port of `the app/scripts/lt_android_full.sh`. Every
/// system action goes through [MplatrolShell] so it can be mocked: the tunnel runs
/// via [MplatrolShell.start] (a backgrounded process whose buffered output is
/// polled for the ready line) and each curl call via [MplatrolShell.runArgs] (an
/// exact argument vector, never a shell string). Every credential / path is read
/// from the `env` map passed to [run] (never `Platform.environment`) so tests
/// are deterministic.
class LtAndroidRunner with LtRunSupport, LtAppUpload {
  /// [pollDelay] is the wait between tunnel-ready checks, trigger retries and
  /// build-status polls. It defaults to two seconds so a real run backs off
  /// instead of hammering LambdaTest; tests pass [Duration.zero]. [uploadPolicy]
  /// sets the APK upload retry waits.
  LtAndroidRunner({this.pollDelay = const Duration(seconds: 2), this.uploadPolicy = const LtUploadPolicy()});

  /// Delay between poll/retry iterations (see the constructor).
  @override
  final Duration pollDelay;

  /// How APK uploads retry (see [LtAppUpload.uploadLtApp]).
  @override
  final LtUploadPolicy uploadPolicy;

  /// LambdaTest Espresso build trigger endpoint.
  static const _ltEspressoBuildUrl = 'https://mobile-api.lambdatest.com/framework/v1/espresso/build';

  /// LambdaTest mobile-automation API base for build/session/log queries.
  static const _ltMobileAutomationUrl = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1';

  /// Max extra `patrol build android` attempts after a transient
  /// dependency/network build failure (see [transientBuildFailureMarkers]).
  static const _buildRetryAttempts = 2;

  /// Delay between build retries.
  static const _buildRetryDelay = Duration(seconds: 5);

  /// Max attempts for the Espresso trigger after transient tunnel responses.
  static const _triggerAttempts = 10;

  /// Seconds LambdaTest may keep the build queued before it starts; sent as
  /// `queueTimeout` in the trigger payload. The poll budget is sized from this
  /// so a build that waits out the full queue is never misreported as stuck.
  static const _queueTimeoutSeconds = 3600;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  FileSystem get _fileSystem => getDep<FileSystem>();
  LtHttp get _http => getDep<LtHttp>();
  // coverage:ignore-start
  PlatformWrapper get _platform => getDep<PlatformWrapper>();
  // coverage:ignore-end

  /// Runs the full LambdaTest Android flow for [target] on [devices] through a
  /// fresh LambdaTest tunnel (its name taken from `LT_TUNNEL_NAME` in [env] when
  /// set, otherwise auto-assigned by LambdaTest).
  ///
  /// [idleTimeoutSeconds] is the per-test idle timeout sent to LambdaTest.
  /// [env] supplies every credential and path: `LT_USERNAME`, `LT_ACCESS_KEY`,
  /// `LT_BIN` (the LambdaTest tunnel binary path), and the build secrets `lambdatest.required-env` names.
  ///
  /// Returns [ExitCode.success] when the build reaches a passing status, and a
  /// non-zero code otherwise. The backgrounded tunnel is always killed before
  /// returning, on every success and failure path.
  Future<int> run({
    required String? target,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    bool reuseLast = false,
  }) async {
    final missing = _missingRequiredEnv(env);
    if (missing.isNotEmpty) {
      _logger.err('Missing required environment values: ${missing.join(', ')}');
      return ExitCode.config.code;
    }

    final repo = _fileSystem.getAppDirectory().path;
    final ltUser = env['LT_USERNAME']!;
    final ltKey = env['LT_ACCESS_KEY']!;
    final ltBin = env['LT_BIN']!;
    final auth = '$ltUser:$ltKey';
    final buildName = await gitBuildName(prefix: 'PatrolAndroid', workingDirectory: repo);

    ({MplatrolProcess process, bool ready, String name})? tunnel;
    try {
      // Start the tunnel inside the try so a failure to launch it (e.g. a
      // missing LT_BIN raising a ProcessException) is caught here and returned
      // as a clean exit code, not propagated out of the runner.
      tunnel = await getDep<LtTunnel>().start(
        ltBin: ltBin,
        ltUser: ltUser,
        ltKey: ltKey,
        tunnelName: env['LT_TUNNEL_NAME'],
      );
      if (!tunnel.ready) {
        return ExitCode.unavailable.code;
      }

      return await _runWithTunnel(
        repo: repo,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        tunnelName: tunnel.name,
        devices: devices,
        idleTimeoutSeconds: idleTimeoutSeconds,
        buildName: buildName,
        auth: auth,
        env: env,
        reuseLast: reuseLast,
      );
    } catch (error) {
      // HTTP/network errors surface as exceptions now that the LT calls use
      // package:http instead of curl; return a clean exit code, not a crash.
      _logger.err('LambdaTest Android E2E failed: $error');
      return ExitCode.software.code;
    } finally {
      // The tunnel may be null if start() threw before assigning it.
      tunnel?.process.kill();
    }
  }

  /// Everything after the tunnel is up: build, upload, trigger, poll, read.
  /// Split out so [run] keeps the single kill-the-tunnel cleanup.
  Future<int> _runWithTunnel({
    required String repo,
    required String? target,
    required String tunnelName,
    required List<String> devices,
    required int idleTimeoutSeconds,
    required String buildName,
    required String auth,
    required Map<String, String> env,
    required bool reuseLast,
    String? targetRegex,
    String? sdk,
  }) async {
    final cachePath = p.join(repo, 'build/app/outputs/lt-last.json');
    final artifacts = await buildUploadAndroid(
      repo: repo,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      buildName: buildName,
      cachePath: cachePath,
      auth: auth,
      env: env,
      reuseLast: reuseLast,
    );
    if (artifacts == null) {
      return reuseLast ? ExitCode.usage.code : ExitCode.software.code;
    }

    final buildId = await _triggerEspresso(
      appId: artifacts.appId,
      testId: artifacts.testSuiteAppId,
      devices: devices,
      buildName: buildName,
      tunnelName: tunnelName,
      idleTimeoutSeconds: idleTimeoutSeconds,
      auth: auth,
    );
    if (buildId == null) {
      return ExitCode.software.code;
    }
    _logger.info('Triggered build $buildId');

    final status = await _pollBuild(buildId: buildId, idleTimeoutSeconds: idleTimeoutSeconds, auth: auth);
    // A LambdaTest device run can end either `passed` or `completed`; both are a
    // pass (kept in sync with the iOS runner's `_isPass`).
    if (status != 'passed' && status != 'completed') {
      final passedSessions = await _passedSessionCount(buildId: buildId, auth: auth);
      if (passedSessions != null) {
        _logger.warn(
          'LambdaTest Android build $buildId reported $status, '
          'but all $passedSessions session(s) passed; treating as pass.',
        );
        _logger.success('LambdaTest Android E2E passed (build $buildId).');
        return ExitCode.success.code;
      }
      _logger.err('LambdaTest Android E2E did not pass (build $buildId, status "$status").');
      await getDep<LtDiagnostics>().report(buildId: buildId, platform: 'Android', env: env);
      return ExitCode.software.code;
    }

    _logger.success('LambdaTest Android E2E passed (build $buildId).');
    return ExitCode.success.code;
  }

  /// Builds and uploads the Android app + instrumentation APKs once, returning
  /// the LambdaTest app ids that HyperExecute's `android/espresso` YAML can use.
  Future<AndroidLtArtifacts?> buildUploadAndroid({
    required String repo,
    required String? target,
    required String buildName,
    required String auth,
    required Map<String, String> env,
    required bool reuseLast,
    String? targetRegex,
    String? sdk,
    String? cachePath,
    String? tenant,
  }) async {
    try {
      final selection = planPatrolSdkSelection(repo,
          platform: 'android', target: target, targetRegex: targetRegex, sdk: sdk, tenant: tenant);
      _logger.info('[sdk-selection] selected=${selection.selectedCount} '
          'excluded=${selection.excludedCount} (registrations, not coverage certification)');
      for (final excluded in selection.excluded) {
        _logger.info('[sdk-excluded] ${excluded.file}: ${excluded.reason}');
      }
      if (selection.selectedCount == 0) {
        throw StateError('No eligible Android native tests; nothing will be built or scheduled.');
      }
      return await _buildSelectedAndroid(selection,
          buildName: buildName,
          auth: auth,
          env: env,
          reuseLast: reuseLast,
          cachePath: cachePath ?? p.join(repo, 'build/app/outputs/lt-last.json'));
      // Preparation APIs report absent/stale evidence as StateError; surface fatal diagnostics.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _logger.err('Android SDK selection/artifact refused: ${error.message}');
      return null;
    } on LtUploadFailure catch (failure) {
      reportLtUploadFailure(failure, repo: repo);
      return null;
    }
  }

  Future<AndroidLtArtifacts?> _buildSelectedAndroid(
    PatrolSelectionPlan selection, {
    required String buildName,
    required String auth,
    required Map<String, String> env,
    required bool reuseLast,
    required String cachePath,
  }) async {
    final repo = selection.repo;
    final generator = androidPatrolGeneratorIdentity(env: env);
    if (!reuseLast) {
      final current = androidSdkBuildIdentity(selection, env: env, nativeGeneratorIdentity: generator);
      final cached = _reuseSharedAppIds(current, env: env, selection: selection, quiet: true) ??
          _reuseCachedAppIds(cachePath, env: env, selection: selection, buildIdentity: current, automatic: true);
      if (cached != null) {
        return AndroidLtArtifacts(appId: cached.$1, testSuiteAppId: cached.$2, selection: selection);
      }
    }
    final before = <String, String>{};
    if (!reuseLast) {
      (String, String)? shared;
      final code = await buildAndroid(
          repo: repo,
          target: selection.target,
          targetRegex: selection.targetRegex,
          sdk: selection.sdk,
          env: env,
          selection: selection,
          sdkBuildInputDigests: before,
          reusePrepared: (identity) => (shared = _reuseSharedAppIds(identity, env: env, selection: selection)) != null);
      if (code != ExitCode.success.code) {
        return null;
      }
      if (shared case (final appId, final testId)) {
        return AndroidLtArtifacts(appId: appId, testSuiteAppId: testId, selection: selection);
      }
    }
    final after = <String, String>{};
    final identity =
        androidSdkBuildIdentity(selection, env: env, nativeGeneratorIdentity: generator, inputDigests: after);
    if (!reuseLast && before['@identity'] != identity) {
      _refuseAndroidInputDrift(repo, before, after);
    }
    if (reuseLast) {
      final cached = _reuseCachedAppIds(cachePath, env: env, selection: selection, buildIdentity: identity);
      return cached == null
          ? null
          : AndroidLtArtifacts(appId: cached.$1, testSuiteAppId: cached.$2, selection: selection);
    }
    final receipt = await uploadPatrolSdkArtifacts(
        selection: selection,
        buildIdentity: identity,
        nativeGeneratorIdentity: generator,
        appApk: appApkPath(repo),
        testApk: testApkPath(repo),
        upload: () async {
          final ids = await _uploadSelectedPair(repo, buildName: buildName, auth: auth);
          if (androidSdkBuildIdentity(selection, env: env, nativeGeneratorIdentity: generator) != identity) {
            throw StateError('Android build inputs changed during upload; receipt not recorded.');
          }
          return ids;
        });
    final data = receipt.toJson();
    final appId = (data['app'] as Map)['id'] as String;
    final testId = (data['test'] as Map)['id'] as String;
    saveCachedAppIds(cachePath, appId, testId,
        nativeGeneratorIdentity: generator, sdkReceipt: receipt, sdkSelection: selection, sdkBuildIdentity: identity);
    final shared = sharedArtifactPath('android', identity, env);
    if (shared != null) {
      Directory(p.dirname(shared)).createSync(recursive: true);
      // Written aside and renamed, so a concurrent reader never sees half a record.
      final aside = '$shared.$pid.tmp';
      saveCachedAppIds(aside, appId, testId,
          nativeGeneratorIdentity: generator, sdkReceipt: receipt, sdkSelection: selection, sdkBuildIdentity: identity);
      File(aside).renameSync(shared);
      _logger.info('[artifact-cache] recorded the Android upload for build identity ${shortIdentity(shared)}');
    }
    return AndroidLtArtifacts(appId: appId, testSuiteAppId: testId, selection: selection);
  }

  /// The ids another checkout or run uploaded for build [identity], from the
  /// per-user artifact cache; null (after logging why, unless [quiet] and
  /// nothing was recorded) when they cannot be reused.
  (String, String)? _reuseSharedAppIds(String identity,
      {required Map<String, String> env, required PatrolSelectionPlan selection, bool quiet = false}) {
    final path = sharedArtifactPath('android', identity, env);
    if (path == null) {
      return null;
    }
    final miss = sharedArtifactMiss(path);
    if (miss != null) {
      if (!quiet || File(path).existsSync()) {
        _logger.info('[artifact-cache] miss: $miss; building and uploading the Android pair');
      }
      return null;
    }
    final ids = _reuseCachedAppIds(path, env: env, selection: selection, buildIdentity: identity, automatic: true);
    if (ids != null) {
      _logger.info('[artifact-cache] hit: build identity ${shortIdentity(path)} was uploaded '
          '${_age(File(path).lastModifiedSync())} ago; skipping the Android build and upload');
    }
    return ids;
  }

  String _age(DateTime since) {
    final age = DateTime.now().difference(since);
    return age.inHours >= 1 ? '${age.inHours}h' : '${age.inMinutes}m';
  }

  /// Uploads the app and test APKs at the same time.
  Future<({String appId, String testId})> _uploadSelectedPair(
    String repo, {
    required String buildName,
    required String auth,
  }) async {
    final [app, test] = await Future.wait([
      _uploadWithProgress(label: 'app APK', file: appApkPath(repo), name: '$buildName-app', auth: auth),
      _uploadWithProgress(label: 'test APK', file: testApkPath(repo), name: '$buildName-test', auth: auth),
    ]);
    return (appId: app, testId: test);
  }

  Never _refuseAndroidInputDrift(String repo, Map<String, String> before, Map<String, String> after) {
    final names = {...before.keys, ...after.keys}
        .where((name) => name != '@identity' && before[name] != after[name])
        .toList()
      ..sort();
    const relative = '.mplatrol/android_sdk_build_input_drift.json';
    final diagnostic = File(p.join(repo, relative));
    diagnostic.parent.createSync(recursive: true);
    diagnostic.writeAsStringSync(jsonEncode({
      'schema': 1,
      'before': before['@identity'],
      'after': after['@identity'],
      'changed': [
        for (final name in names) {'input': name, 'before': before[name], 'after': after[name]},
      ],
    }));
    throw StateError('Android compilation inputs changed during build: '
        '${names.take(12).join(', ')} (${names.length} differing inputs). '
        'Upload refused; private input hashes: $relative.');
  }

  List<String> _missingRequiredEnv(Map<String, String> env) {
    final required = ['LT_USERNAME', 'LT_ACCESS_KEY', 'LT_BIN', ...getDep<MplatrolConfig>().it.ltRequiredEnv];
    return required.where((key) => (env[key] ?? '').isEmpty).toList(growable: false);
  }

  /// Read the app/test ids cached by the last build+upload (`--reuse-last`),
  /// returning null (with a clear error logged) when there is no usable cache.
  (String, String)? _reuseCachedAppIds(String cachePath,
      {required Map<String, String> env,
      required PatrolSelectionPlan selection,
      required String buildIdentity,
      bool automatic = false}) {
    final mode = automatic ? 'artifact-auto-reuse' : 'reuse-last';
    void miss(String reason) {
      if (automatic) {
        _logger.info('[$mode] miss: $reason Building and uploading a fresh pair.');
      } else {
        _logger.err('--$mode: $reason');
      }
    }

    return loadCachedAppIds(
      cachePath,
      nativeGeneratorIdentity: androidPatrolGeneratorIdentity(env: env),
      sdkSelection: selection,
      sdkBuildIdentity: buildIdentity,
      onSdkInvalid: miss,
      onMissing: () => miss(
        'no cached LambdaTest build at $cachePath. Run '
        '`mplatrol run lt-android` once to build + upload before reusing.',
      ),
      onIncomplete: () => miss(
        'cached build at $cachePath is incomplete or its native '
        'generator identity is missing or changed; run '
        'a full `mplatrol run lt-android` to rebuild.',
      ),
      onLoaded: (appId, testId) {
        _logger.info('[$mode] app=$appId test=$testId (skipping build+upload; not a test verdict)');
        getDep<ItRunResults>().buildReused();
      },
    );
  }

  /// The app-under-test APK `patrol build android` produces (deterministic path).
  static String appApkPath(String repo) => p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk');

  /// The instrumentation (androidTest) APK `patrol build android` produces.
  static String testApkPath(String repo) =>
      p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk');

  /// `patrol build android` for the login E2E and verify both APKs landed. The
  /// `patrol build` step also (re)generates Patrol's shared `test_bundle.dart`.
  ///
  /// Reused by [run] (LambdaTest flow) and by `mplatrol build`, where it is the
  /// bundle generator: it runs concurrently with the iOS `flutter build ios
  /// --config-only` (which never reads the bundle), and the iOS `xcodebuild`
  /// (which does) runs only after this finishes. Returns [ExitCode.success] when
  /// the build succeeds and both the app and instrumentation APKs exist, else a
  /// non-zero code (after logging).
  ///
  /// Args:
  ///   repo: Prepared APP root.
  ///   target: Optional selected Patrol test file.
  ///   targetRegex: Optional supported whole-file selection expression.
  ///   sdk: Optional declared SDK selection.
  ///   env: Resolved runtime/build controls.
  ///   selection: Artifact-bound Android selection plan, when activated.
  ///   sdkBuildInputDigests: Caller-owned private hashes captured before compilation.
  ///   reusePrepared: Called with the build identity once the build is
  ///     prepared; true skips compiling (the caller reuses an upload of it).
  Future<int> buildAndroid({
    required String repo,
    required String? target,
    String? targetRegex,
    String? sdk,
    Map<String, String>? env,
    PatrolSelectionPlan? selection,
    Map<String, String>? sdkBuildInputDigests,
    bool Function(String identity)? reusePrepared,
  }) async {
    try {
      preparedAndroidApplicationId(repo);
      // Binding failures must precede compiler preparation, build and upload.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      _logger.err(error.message.toString());
      return ExitCode.config.code;
    }
    final command = await getDep<LocalRunner>().preparePatrolCliCommand(repo);
    if (command == null) {
      return ExitCode.software.code;
    }
    final args = _prepareAndroidBuild(repo,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        runnerEnv: env ?? _platform.environment,
        selection: selection,
        sdkBuildInputDigests: sdkBuildInputDigests);
    final prepared = sdkBuildInputDigests?['@identity'];
    if (prepared != null && (reusePrepared?.call(prepared) ?? false)) {
      return ExitCode.success.code;
    }
    final result = await _buildAndroidWithRetry(repo, args, command);
    if (result == null || result.exitCode != ExitCode.success.code) {
      return ExitCode.software.code;
    }
    return _androidBuildOutputs(repo);
  }

  List<String> _prepareAndroidBuild(
    String repo, {
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required Map<String, String> runnerEnv,
    required PatrolSelectionPlan? selection,
    Map<String, String>? sdkBuildInputDigests,
  }) {
    // Regenerate the Patrol runner so its @Test methods match + name + group the
    // current Patrol tests before the build compiles them.
    final methodCount = generateAndroidPatrolRunner(repo,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        selection: selection,
        patrolRunner: androidLambdaTestPatrolRunner,
        env: runnerEnv);
    _logger.info('Generated $methodCount Android LambdaTest Patrol @Test method(s)');
    final buildTarget =
        _selectedBuildTarget(repo, target: target, targetRegex: targetRegex, sdk: sdk, selection: selection);
    // No target → build the whole suite (patrol bundles every *_test.dart).
    writeE2eRuntimeAssetConfig(repo, runnerEnv);
    final e2eDefineArgs = e2eDartDefineArgs(repo, runnerEnv);
    if (selection != null) {
      prepareAndroidSdkBuildProperties(repo);
      prepareAndroidPatrolSdkAssets(selection,
          buildIdentity: androidSdkBuildIdentity(selection,
              env: runnerEnv,
              nativeGeneratorIdentity: androidPatrolGeneratorIdentity(env: runnerEnv),
              inputDigests: sdkBuildInputDigests),
          nativeGeneratorIdentity: androidPatrolGeneratorIdentity(env: runnerEnv));
    }
    _clearStaleAndroidBuildOutputs(repo);
    _logger.info(
      'patrol build android'
      '${buildTarget == null ? ' (whole suite)' : ' (target: $buildTarget)'}'
      '${targetRegex == null ? '' : ' (target-regex: $targetRegex)'}'
      '${sdk == null ? '' : ' (sdk: $sdk)'}',
    );
    if (selection != null) {
      return androidSdkBuildArguments(selection, runnerEnv);
    }
    final packageName = preparedAndroidApplicationId(repo);
    return [
      'build',
      'android',
      '--package-name',
      packageName,
      '--no-label',
      if (buildTarget != null) ...['--target', buildTarget],
      '--dart-define=LT_PROXY=true',
      '--dart-define=E2E_TEST_BRIDGE=true',
      '--dart-define=PATROL_APP_PACKAGE_NAME=$packageName',
      ...e2eDefineArgs,
    ];
  }

  String? _selectedBuildTarget(
    String repo, {
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required PatrolSelectionPlan? selection,
  }) {
    final wrapperTarget = selection != null || target == null || targetRegex != null || sdk != null
        ? retargetPatrolTestBundle(
            repo,
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            selection: selection,
          )
        : null;
    if (wrapperTarget != null) {
      _logger.info(
        '[bundle] LambdaTest Android generated run target -> $wrapperTarget',
      );
    } else {
      removeFilteredPatrolTestTarget(repo);
    }
    return wrapperTarget ?? target;
  }

  Future<ProcessResultX?> _buildAndroidWithRetry(String repo, List<String> buildArgs, List<String> command) async {
    final verboseBuild = _logger.level.index <= Level.debug.index;
    var result = await _runPatrolBuildAndroidOnce(repo, buildArgs, verboseBuild, command);
    for (var attempt = 1;
        attempt <= _buildRetryAttempts &&
            result != null &&
            result.exitCode != ExitCode.success.code &&
            _isTransientBuildFailure(result);
        attempt++) {
      _logger.warn(
        '[build-retry] patrol build android failed on a transient '
        'dependency/network error (attempt $attempt/$_buildRetryAttempts); '
        'retrying in ${_buildRetryDelay.inSeconds}s.',
      );
      await getDep<SleepFunction>()(_buildRetryDelay);
      result = await _runPatrolBuildAndroidOnce(repo, buildArgs, verboseBuild, command);
    }
    return result;
  }

  int _androidBuildOutputs(String repo) {
    final appApk = appApkPath(repo);
    final testApk = testApkPath(repo);
    if (!_fileSystem.fileExistsSync(appApk)) {
      _logger.err('App APK not produced at $appApk');
      return ExitCode.software.code;
    }
    if (!_fileSystem.fileExistsSync(testApk)) {
      _logger.err('Test APK not produced at $testApk');
      return ExitCode.software.code;
    }
    return ExitCode.success.code;
  }

  /// Stops the Flutter Gradle plugin from resetting every build type's ABI
  /// filters to all platforms, so the LambdaTest-only `ndk.abiFilters 'arm64-v8a'`
  /// that [generateAndroidPatrolRunner] adds takes effect: about a third less
  /// debug APK to upload on each run.
  static const _keepArm64OnlyGradleProperty = androidSdkAbiBuildProperty;

  /// One `patrol build android` attempt. Owns the progress spinner and the
  /// quiet-build failure-tail logging. Returns the process result (including a
  /// non-zero exit), or `null` when the process could not be launched.
  Future<ProcessResultX?> _runPatrolBuildAndroidOnce(
      String repo, List<String> buildArgs, bool verboseBuild, List<String> command) async {
    final progress = verboseBuild ? null : _logger.progress('Building Android APKs with Patrol');
    final ProcessResultX result;
    try {
      result = await _shell.runArgs(
        'env',
        [_keepArm64OnlyGradleProperty, ...command, ...buildArgs],
        workingDirectory: repo,
        throwOnError: false,
        silent: !verboseBuild,
        forceVerbose: verboseBuild,
      );
    } catch (error) {
      progress?.fail('patrol build android failed');
      _logger.err('patrol build android failed: $error');
      return null;
    }
    if (result.exitCode != ExitCode.success.code) {
      progress?.fail('patrol build android failed');
      formatQuietBuildFailureTail(
        lines: [...result.outLines, ...result.errLines],
        exitCode: result.exitCode,
      ).forEach(_logger.err);
      _logger.err('patrol build android failed (exit ${result.exitCode}).');
      return result;
    }
    progress?.complete('Built Android APKs with Patrol');
    return result;
  }

  bool _isTransientBuildFailure(ProcessResultX result) =>
      isTransientBuildFailure('${result.outText}\n${result.errText}');

  void _clearStaleAndroidBuildOutputs(String repo) {
    // Keep Flutter's incremental inputs/results; Gradle invalidates them when
    // Dart, testcase discovery, dependencies, or native configuration change.
    // Remove deliverables so an unsuccessful build cannot upload old APKs.
    final paths = [
      p.join(repo, 'build/app/outputs/flutter-apk'),
      appApkPath(repo),
      testApkPath(repo),
    ];
    var removed = 0;
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
        removed++;
        continue;
      }
      final directory = Directory(path);
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
        removed++;
      }
    }
    if (removed > 0) {
      _logger.detail('[lt-android] cleared $removed stale build output(s)');
    }
  }

  /// Direct LT upload of [file] as [name], retried (see [LtAppUpload.uploadLtApp]).
  Future<String> _uploadWithProgress({
    required String label,
    required String file,
    required String name,
    required String auth,
  }) async {
    final progress = _logger.progress('Uploading $label to LambdaTest');
    try {
      final uploaded = await uploadLtApp(file: file, name: name, headers: _http.basicAuthRaw(auth));
      progress.complete('Uploaded $label to LambdaTest');
      _logger.detail('[lt-android] $label uploaded as $uploaded');
      return uploaded;
    } catch (_) {
      progress.fail('Uploading $label to LambdaTest failed');
      rethrow;
    }
  }

  Future<String?> _triggerEspresso({
    required String appId,
    required String testId,
    required List<String> devices,
    required String buildName,
    required String tunnelName,
    required int idleTimeoutSeconds,
    required String auth,
  }) async {
    // LambdaTest categorises Android instrumentation under its "espresso"
    // framework (see _ltEspressoBuildUrl); the tests themselves are Patrol.
    _logger.info(
      'Triggering LambdaTest Android run on $devices '
      '(tunnel: $tunnelName)',
    );
    final payload = {
      'app': appId,
      'testSuite': testId,
      'device': devices,
      'queueTimeout': _queueTimeoutSeconds,
      'idleTimeout': idleTimeoutSeconds,
      'deviceLog': true,
      'video': true,
      'build': buildName,
      'tunnel': true,
      'tunnelName': tunnelName,
      'localhost': true,
      'mitmProxy': true,
    };
    String? lastTransientReason;
    for (var attempt = 1; attempt <= _triggerAttempts; attempt++) {
      final response = await _http.postJson(_ltEspressoBuildUrl, headers: _http.basicAuthRaw(auth), body: payload);
      final decoded = tryDecodeObject(response.body);
      if (decoded == null) {
        _logger.err('LT response was not valid JSON: ${response.body}');
        return null;
      }
      final buildId = _extractBuildId(decoded['buildId']);
      if (buildId != null) {
        return buildId;
      }
      final reason = _transientTriggerReason(decoded);
      if (reason != null && attempt < _triggerAttempts) {
        if (reason == lastTransientReason) {
          _logger.detail('LambdaTest Android trigger still not ready.');
        } else {
          _logger.warn(
            'LambdaTest Android trigger not ready yet: $reason; '
            'retrying...',
          );
          lastTransientReason = reason;
        }
        await Future<void>.delayed(pollDelay);
        continue;
      }
      _logger.err('No buildId in LT response: ${response.body}');
      return null;
    }
    return null;
  }

  String? _transientTriggerReason(Map<String, dynamic> response) {
    final displayMessage = _triggerMessage(response);
    final message = displayMessage.toLowerCase();
    if (message.contains('tunnel') && (message.contains('not running') || message.contains('disconnected'))) {
      return displayMessage;
    }
    return null;
  }

  String _triggerMessage(Map<String, dynamic> response) {
    final raw = response['message'];
    if (raw is List) {
      return raw.map((item) => item.toString()).join(' ');
    }
    return raw?.toString() ?? '';
  }

  String? _extractBuildId(dynamic raw) {
    if (raw is List) {
      if (raw.isEmpty) {
        return null;
      }
      final first = raw.first.toString();
      return first.isEmpty ? null : first;
    }
    if (raw == null) {
      return null;
    }
    final value = raw.toString();
    return value.isEmpty ? null : value;
  }

  /// Polls the build endpoint until a terminal status_ind, returning the last
  /// seen status (lower-cased). A populated end_timestamp is deliberately
  /// ignored — returning early would tear down the tunnel mid-test (see body).
  Future<String> _pollBuild({required String buildId, required int idleTimeoutSeconds, required String auth}) async {
    var status = '?';
    var loggedStatus = '';
    final maxAttempts = maxPollAttempts(
      queueTimeoutSeconds: _queueTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds,
    );
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      Map<String, dynamic>? data;
      try {
        final response = await _http.get('$_ltMobileAutomationUrl/builds/$buildId', headers: _http.basicAuthRaw(auth));
        final decoded = tryDecodeObject(response.body)?['data'];
        data = decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        data = null; // transient network/timeout — keep polling
      }
      status = data?['status_ind']?.toString().toLowerCase() ?? '?';
      // Log only on a status change. The poll runs every few seconds, so logging
      // every tick repeats the same line for minutes. end_timestamp is NOT shown
      // (or used): LambdaTest populates it while the test is still running, so it
      // reads as "ended" mid-run — see the terminal-status note below.
      if (status != loggedStatus) {
        _logger.info('build $buildId status=$status');
        loggedStatus = status;
      }

      // Return ONLY on a terminal status_ind — never on a populated
      // end_timestamp. LambdaTest sets end_timestamp while the test is still
      // running, and run() kills the tunnel the moment this returns; an early
      // return cuts the device off from staging mid-test (the login WebView
      // then lands on chrome-error). The tunnel must stay up until the run
      // truly ends.
      if (LtRunSupport.terminalStatuses.contains(status)) {
        return status;
      }
      await Future<void>.delayed(pollDelay);
    }
    return status;
  }

  Future<int?> _passedSessionCount({required String buildId, required String auth}) async {
    try {
      final response = await _http.get(
        '$_ltMobileAutomationUrl/sessions?build_id=$buildId',
        headers: _http.basicAuthRaw(auth),
      );
      final decoded = tryDecodeObject(response.body)?['data'];
      if (decoded is! List || decoded.isEmpty) {
        return null;
      }
      var passed = 0;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) {
          return null;
        }
        final status = item['status_ind']?.toString().toLowerCase();
        if (status != 'passed' && status != 'completed') {
          return null;
        }
        passed += 1;
      }
      return passed;
    } catch (error) {
      _logger.detail(
        '[lt-android] could not inspect LambdaTest sessions for '
        '$buildId: $error',
      );
      return null;
    }
  }
}
