import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/checkout_independent_inputs.dart';
import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/trash_mover.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/lt_app_upload.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class IosHyperexecuteArtifacts {
  IosHyperexecuteArtifacts({
    required this.appPath,
    required this.testSuitePath,
    required this.appId,
    required this.testSuiteAppId,
    required this.productsDir,
    this.testSuites = const [],
  });

  final String appPath;
  final String testSuitePath;

  /// `lt://…` ids of the pre-uploaded IPAs (verified GitLab package upload →
  /// LT url-fetch). The HyperExecute yaml references these instead of local
  /// `appPath`s so the CLI never has to move the IPAs itself — its uploader
  /// breaks behind a TLS-intercepting proxy with `tls: bad record MAC`.
  final String appId;
  final String testSuiteAppId;

  final String productsDir;
  final List<IosHyperexecuteTestSuite> testSuites;
}

class IosHyperexecuteTestSuite {
  IosHyperexecuteTestSuite({required this.shard, required this.testSuitePath});

  final IosTestShard shard;
  final String testSuitePath;
}

/// Runs the unified login Patrol E2E on a LambdaTest iOS real device via the
/// XCUITest framework.
///
/// This is the Dart port of `the app/scripts/run_ios_lambdatest_xcui.sh`
/// and the iOS counterpart to the LambdaTest Android runner. The flow is:
///
/// 1. `flutter build ios --config-only --profile` for the Patrol target.
/// 2. `xcodebuild build-for-testing` with the `PATROL_ENABLED` compile flag.
/// 3. Re-sign the XCUITest runner `.app` + its `.xctest` (LambdaTest cannot
///    provision the templatrole-signed runner `xcodebuild test` would normally
///    sign per-destination, so it is signed here with the auto-provisioned
///    profile + `get-task-allow` entitlements).
/// 4. Package the app `.app` and the runner `.app` into `Payload/`-style IPAs.
/// 5. Upload both to the GitLab generic package registry, then register them
///    with LambdaTest by URL (server-side fetch, to dodge the direct-upload
///    body cap that 502s on large IPAs).
/// 6. Trigger the XCUITest run (with `tunnel: true` so the device reaches
///    staging) and poll the build until it reaches a terminal status.
///
/// The build steps (flutter, xcodebuild, git) run through [MplatrolShell.run]
/// since they are single binaries with shell-safe argument strings. Every
/// other external action runs as an exact argument vector through
/// [MplatrolShell.runArgs] (curl, codesign, ditto, plutil, zip) and all
/// file/directory work goes through `dart:io`, so nothing relies on a shell to
/// parse idioms. Credentials, tool defaults, and the signing identity all come
/// from the supplied `env` map; the repository location is derived from
/// [FileSystem]. Nothing is hardcoded to an absolute path.
class LtIosRunner with LtRunSupport, LtAppUpload {
  /// [pollDelay] is the wait between build-status polls. It defaults to two
  /// seconds so a real run backs off instead of hammering LambdaTest; tests
  /// pass [Duration.zero]. [uploadPolicy] sets the IPA upload retry waits.
  LtIosRunner({this.pollDelay = const Duration(seconds: 2), this.uploadPolicy = const LtUploadPolicy()});

  /// Delay between build-status poll iterations (see the constructor).
  @override
  final Duration pollDelay;

  /// How IPA uploads retry (see [LtAppUpload.uploadLtApp]).
  @override
  final LtUploadPolicy uploadPolicy;

  /// Build-products directory (relative to the iOS dir) that
  /// `xcodebuild build-for-testing` writes to, used when `XCUI_PRODUCTS_DIR` is
  /// not set in `env`.
  static const defaultProductsDir = 'build/xcui-lt/Build/Products/Profile-iphoneos';

  /// Seconds LambdaTest may keep the build queued before it starts; sent as
  /// `queueTimeout` in the trigger payload. The poll budget is sized from this
  /// so a build that waits out the full queue is never misreported as stuck.
  static const _queueTimeoutSeconds = 600;
  static const _perTestCacheSchema = 2;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  FileSystem get _fileSystem => getDep<FileSystem>();
  LtHttp get _http => getDep<LtHttp>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// Builds, signs, uploads, triggers, and polls the LambdaTest iOS XCUITest
  /// run for the unified login E2E — ONE LambdaTest build per discovered test so
  /// the dashboard shows each test by name.
  ///
  /// LambdaTest's iOS build API resolves `only-testing` ONLY for the literal
  /// target class `RunnerUITests`, and it names every iOS session
  /// `testInvocations()` regardless. So the only way a test's NAME reaches the
  /// dashboard is a dedicated BUILD per test, whose uploaded `.xctest` holds just
  /// that one test in `RunnerUITests` (regenerated per build) and whose `build`
  /// name is the test description. The app `.ipa` is byte-identical across those
  /// builds (only `RunnerUITests.m` changes), so it is uploaded once and reused.
  ///
  /// [target] is the Patrol entrypoint (e.g.
  /// `patrol_test/patrol_login_test.dart`). One fresh LambdaTest tunnel is
  /// started (its name auto-assigned and read back) so the device routes staging
  /// traffic through it. [devices] are `Name-OSVersion` specs. [idleTimeoutSeconds]
  /// is the per-test idle timeout passed to LambdaTest. [env] supplies all
  /// credentials, tool paths, and the signing identity.
  ///
  /// Returns [ExitCode.success] only when every per-test build passes, and a
  /// non-zero code on any failure (missing config, build, signing, upload,
  /// trigger, or a failed/timed-out run).
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
      _logger.err(
        'Missing required environment variables for the LambdaTest '
        'iOS run: ${missing.join(', ')}.',
      );
      return ExitCode.usage.code;
    }
    if (devices.isEmpty) {
      _logger.err('No LambdaTest iOS devices supplied.');
      return ExitCode.usage.code;
    }

    final iosDir = _fileSystem.getIosDirectory().path;
    final productsDir = p.join(iosDir, env['XCUI_PRODUCTS_DIR'] ?? defaultProductsDir);
    final perTestCachePath = p.join(productsDir, 'lt-last-pertest.json');

    final buildName = env['LT_BUILD_NAME'] ?? await gitBuildName(prefix: 'PatrolIOS', workingDirectory: iosDir);

    try {
      final shards = iosTestShards(
        _fileSystem.getAppDirectory().path,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        env: env,
      );
      if (shards.isEmpty) {
        _logger.err(
          targetRegex != null || sdk != null
              ? 'No iOS Patrol test shards matched the requested filter.'
              : 'No selected XCTest identities are available to verify an iOS run.',
        );
        return targetRegex != null || sdk != null ? ExitCode.usage.code : ExitCode.unavailable.code;
      }

      // `--reuse-last` re-triggers the previously uploaded app + per-test bundles
      // (a flaky retry or an idle-timeout/device tweak) and skips the ~15-min
      // build + ~400MB upload; a normal run builds each per-test bundle, uploads,
      // and caches the ids.
      final builds = reuseLast
          ? _loadPerTestCache(
              perTestCachePath,
              expectedInputs: _perTestCacheInputs(
                target: target,
                targetRegex: targetRegex,
                sdk: sdk,
                env: env,
              ),
            )
          : await _buildAllPerTest(
              shards: shards,
              target: target,
              targetRegex: targetRegex,
              sdk: sdk,
              iosDir: iosDir,
              productsDir: productsDir,
              cachePath: perTestCachePath,
              buildName: buildName,
              env: env,
            );

      // Start the tunnel only now — right before the device run. Held open
      // through the ~15-min build/resign/upload it drops, leaving the device
      // with no network egress (every request status 0) and the test idling out.
      final tunnel = await getDep<LtTunnel>().start(
        ltBin: env['LT_BIN']!,
        ltUser: env['LT_USERNAME']!,
        ltKey: env['LT_ACCESS_KEY']!,
        tunnelName: env['LT_TUNNEL_NAME'],
      );
      try {
        if (!tunnel.ready) {
          return ExitCode.unavailable.code;
        }
        return await _triggerAndPollPerTest(
          builds: builds,
          shards: shards,
          devices: devices,
          tunnelName: tunnel.name,
          idleTimeoutSeconds: idleTimeoutSeconds,
          buildName: buildName,
          env: env,
        );
      } finally {
        tunnel.process.kill();
      }
    } on _RunnerFailure catch (failure) {
      _logger.err(failure.message);
      return failure.exitCode;
    } on LtUploadFailure catch (failure) {
      reportLtUploadFailure(failure, repo: _fileSystem.getAppDirectory().path);
      return ExitCode.software.code;
    } catch (error) {
      // HTTP/network errors (timeouts, connection failures) surface as
      // exceptions now that the LT calls use package:http instead of curl;
      // return a clean exit code rather than crashing the CLI.
      _logger.err('LambdaTest iOS run failed (${error.runtimeType})');
      return ExitCode.software.code;
    }
  }

  /// Builds + uploads ONE LambdaTest build per [shards] entry: each rebuilds the
  /// `.xctest` with only that test in `RunnerUITests` and re-signs the runner,
  /// but the app `.ipa` (byte-identical across builds) is uploaded once on the
  /// first iteration and reused for the rest. Caches and returns the
  /// `(app, testId, description)` of every test for the trigger phase.
  Future<List<({String app, String id, String name})>> _buildAllPerTest({
    required List<IosTestShard> shards,
    required String? target,
    required String iosDir,
    required String productsDir,
    required String cachePath,
    required String buildName,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
  }) async {
    _logger.info(
      'Building ${shards.length} per-test LambdaTest build(s) — '
      'one named build per test (the app is uploaded once and reused).',
    );
    final builds = <({String app, String id, String name})>[];
    String? appId;
    for (final shard in shards) {
      // The UPLOAD name stays the clean base buildName — LambdaTest's app/test
      // upload `name` field rejects non-ASCII (e.g. the em dash) and long
      // free-text. The per-test description goes on the TRIGGER's build name
      // (the dashboard label), sanitised, in _triggerAndPollPerTest.
      final (builtApp, testId) = await _buildResignUpload(
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        iosDir: iosDir,
        productsDir: productsDir,
        buildName: buildName,
        cachePath: cachePath,
        env: env,
        onlyTest: shard.method,
        reuseAppId: appId,
      );
      appId ??= builtApp;
      builds.add((app: builtApp, id: testId, name: shard.description));
    }
    _savePerTestCache(
      cachePath,
      builds,
      inputs: _perTestCacheInputs(
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        env: env,
      ),
    );
    return builds;
  }

  /// The LambdaTest BUILD name (dashboard label) for a per-test build: the base
  /// build name + the test description, joined with a plain ASCII separator and
  /// stripped of characters LambdaTest's name field rejects (it 400s on the em
  /// dash and other non-`[A-Za-z0-9 ._-]` characters).
  String _perTestBuildName(String base, String description) {
    final safe = description.replaceAll(RegExp('[^A-Za-z0-9 ._-]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return '$base - $safe';
  }

  /// Triggers one LambdaTest build per cached [builds] entry (named after the
  /// test, `only-testing: [RunnerUITests]`), polls them all concurrently, and
  /// passes only if every per-test build passed. The dashboard then shows one
  /// build per test, named after it.
  Future<int> _triggerAndPollPerTest({
    required List<({String app, String id, String name})> builds,
    required List<IosTestShard> shards,
    required List<String> devices,
    required String tunnelName,
    required int idleTimeoutSeconds,
    required String buildName,
    required Map<String, String> env,
  }) async {
    if (builds.length != shards.length ||
        List.generate(builds.length, (index) => index)
            .any((index) => builds[index].name != shards[index].description)) {
      _logger.err('Cached iOS test inventory does not match selected XCTest identities; rebuild.');
      return ExitCode.unavailable.code;
    }
    _logger.info(
      'Triggering ${builds.length} per-test LambdaTest build(s) — '
      'one named build per test.',
    );
    // Trigger all up front (each is a quick POST), then poll concurrently: the
    // builds run in parallel on LambdaTest, so wall-clock is ~one run, not N.
    final triggered = <(String, String, String)>[];
    for (var index = 0; index < builds.length; index++) {
      final build = builds[index];
      final buildId = await _trigger(
        appId: build.app,
        testId: build.id,
        devices: devices,
        tunnelName: tunnelName,
        idleTimeoutSeconds: idleTimeoutSeconds,
        buildName: _perTestBuildName(buildName, build.name),
        // Only the literal target class resolves on the build API; the uploaded
        // .xctest already holds just this test in RunnerUITests.
        onlyTesting: const ['RunnerUITests'],
        env: env,
      );
      triggered.add((buildId, build.name, shards[index].onlyTesting));
    }

    final codes = await Future.wait([
      for (final (buildId, _, identity) in triggered)
        _pollUntilTerminal(
            buildId: buildId,
            idleTimeoutSeconds: idleTimeoutSeconds,
            expectedNativeTests: {identity},
            expectedSessions: devices.length,
            env: env),
    ]);

    final failed = [
      for (var i = 0; i < triggered.length; i++)
        if (codes[i] != ExitCode.success.code) triggered[i].$2,
    ];
    _logger.info('per-test builds: ${triggered.length - failed.length}/${triggered.length} passed');
    for (final name in failed) {
      _logger.err('  ❌ $name');
    }
    return failed.isEmpty ? ExitCode.success.code : ExitCode.software.code;
  }

  List<String> _missingRequiredEnv(Map<String, String> env) {
    final required = ['LT_USERNAME', 'LT_ACCESS_KEY', 'LT_BIN', ...getDep<MplatrolConfig>().it.ltRequiredEnv];
    return required.where((key) => (env[key] ?? '').isEmpty).toList();
  }

  /// Build + resign + package + upload the IPAs, returning the LambdaTest
  /// `(appId, testId)`.
  ///
  /// [onlyTest] (a `RunnerUITests` method name) regenerates the runner with just
  /// that one test so the built `.xctest` holds only it — the per-test path. When
  /// null, the whole suite is built and the result is cached for `--reuse-last`
  /// (the per-test path caches the full list in its caller instead, so it does
  /// NOT cache here).
  ///
  /// [reuseAppId], when set, SKIPS packaging + uploading the app `.ipa` and
  /// returns it as the app id: across per-test builds the app `.ipa` is
  /// byte-identical (only `RunnerUITests.m` changes, so the incremental rebuild
  /// only relinks the `.xctest`), so it is uploaded once and reused. The test
  /// `.ipa` still rebuilds, re-signs, and re-uploads every time.
  Future<(String, String)> _buildResignUpload({
    required String? target,
    required String iosDir,
    required String productsDir,
    required String buildName,
    required String cachePath,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String? onlyTest,
    String? reuseAppId,
  }) async {
    final appPath = p.join(productsDir, 'Runner.app');
    final runnerPath = p.join(productsDir, 'RunnerUITests-Runner.app');
    final repo = _fileSystem.getAppDirectory().path;
    final bundle = await _generateIosTestBundle(repo, target: target, targetRegex: targetRegex, sdk: sdk);
    final bundleId = await _readBundleId(iosDir);
    // Regenerate RunnerUITests.m so its -[test_*] methods match + name + group
    // the current Patrol tests before the xcodebuild step
    // compiles them into the .xctest LambdaTest statically extracts. With
    // onlyTest the runner holds just that one test (the per-test build).
    final methodCount = generateIosPatrolRunner(
      repo,
      bundleId: bundleId,
      onlyTest: onlyTest,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env,
    );
    _logger.info('Generated RunnerUITests with $methodCount test method(s)');
    await _flutterConfigOnly(bundle: bundle, bundleId: bundleId, env: env);
    await _xcodebuildForTesting(iosDir: iosDir, bundleId: bundleId);
    await _resign(env: env, appPath: appPath, runnerPath: runnerPath);

    // The app .ipa is byte-identical across per-test builds, so package + upload
    // it once (reuseAppId == null) and reuse the id on every later build.
    final appId = reuseAppId ??
        await _uploadToLambdaTest(
          ipaPath: await _packageIpa(appPath, '$productsDir/Runner.ipa'),
          ltName: '$buildName-app',
          env: env,
        );
    final testIpa = await _packageIpa(runnerPath, '$productsDir/RunnerUITests-Runner.ipa');
    final testId = await _uploadToLambdaTest(ipaPath: testIpa, ltName: '$buildName-test', env: env);
    // The whole-suite path caches a single {app, test} here; the per-test path
    // caches the full list in its caller, so it must not clobber that here.
    if (onlyTest == null) {
      // coverage:ignore-start
      saveCachedAppIds(cachePath, appId, testId, nativeGeneratorIdentity: iosPatrolGeneratorIdentity());
      // coverage:ignore-end
    }
    return (appId, testId);
  }

  /// Persists the per-test builds for a later `--reuse-last`, including a small
  /// non-secret build-input fingerprint so stale uploaded IPAs are not reused
  /// after changing the E2E target or Dart define file.
  /// The app id is shared by every per-test build (uploaded once), so it is
  /// stored once at the top level. Kept separate from [saveCachedAppIds] (the
  /// single-build cache lt-android also uses) so the two shapes never collide.
  void _savePerTestCache(
    String cachePath,
    List<({String app, String id, String name})> builds, {
    required Map<String, Object?> inputs,
  }) {
    ltFileSystem.writeAsStringSync(
      filePath: cachePath,
      newContent: jsonEncode({
        'schema': _perTestCacheSchema,
        'inputs': inputs,
        'app': builds.isEmpty ? '' : builds.first.app,
        'tests': [
          for (final build in builds) {'id': build.id, 'name': build.name},
        ],
      }),
    );
  }

  /// Reads the per-test cache written by [_savePerTestCache] for `--reuse-last`,
  /// throwing [_RunnerFailure] (usage) when it is missing or empty so the run
  /// fails clearly instead of triggering zero builds.
  List<({String app, String id, String name})> _loadPerTestCache(
    String cachePath, {
    required Map<String, Object?> expectedInputs,
  }) {
    if (!ltFileSystem.fileExistsSync(cachePath)) {
      throw _RunnerFailure(
        '--reuse-last: no per-test LambdaTest cache at $cachePath. Run '
        '`mplatrol run lt-ios` once to build + upload before reusing.',
        ExitCode.usage.code,
      );
    }
    final cache = tryDecodeObject(ltFileSystem.readAsStringSync(cachePath));
    if (cache?['schema'] != _perTestCacheSchema || jsonEncode(cache?['inputs']) != jsonEncode(expectedInputs)) {
      throw _RunnerFailure(
        '--reuse-last: per-test cache at $cachePath was created by an older '
        'runner or different E2E build inputs. Run `mplatrol run lt-ios` '
        'without --reuse-last to rebuild and upload fresh IPAs.',
        ExitCode.usage.code,
      );
    }
    final app = cache?['app'] as String?;
    final tests = cache?['tests'];
    final builds = <({String app, String id, String name})>[];
    if (app != null && app.isNotEmpty && tests is List) {
      for (final test in tests) {
        if (test is Map && test['id'] is String && (test['id'] as String).isNotEmpty && test['name'] is String) {
          builds.add((app: app, id: test['id'] as String, name: test['name'] as String));
        }
      }
    }
    if (builds.isEmpty) {
      throw _RunnerFailure(
        '--reuse-last: per-test cache at $cachePath is empty or invalid; run a '
        'full `mplatrol run lt-ios` to rebuild.',
        ExitCode.usage.code,
      );
    }
    _logger.info(
      '[reuse-last] app=$app, ${builds.length} test(s) '
      '(skipping build+upload)',
    );
    return builds;
  }

  Map<String, Object?> _perTestCacheInputs({
    required String? target,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    String selectionCoordinatorUrl = '',
  }) {
    final repo = _fileSystem.getAppDirectory().path;
    return {
      'nativeGenerator': iosPatrolGeneratorIdentity(),
      'selectionCoordinatorUrl': selectionCoordinatorUrl,
      'target': target ?? '',
      'targetRegex': targetRegex ?? '',
      'sdk': sdk ?? '',
      'dartDefines': const ['LT_PROXY=true', 'E2E_TEST_BRIDGE=true'],
      'defineFile': _e2eDefineFileStamp(repo: repo, env: env),
    };
  }

  Map<String, Object?> _e2eDefineFileStamp({required String repo, required Map<String, String> env}) {
    final explicit = (env[e2eDartDefineFileEnv] ?? env[e2eDartDefineFileFallbackEnv] ?? '').trim();
    final rawPath = explicit.isEmpty ? defaultE2eDartDefineFile : explicit;
    final path = p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(repo, rawPath));
    final file = File(path);
    if (explicit.isEmpty && !file.existsSync()) {
      return const {'path': '', 'exists': false};
    }
    if (!file.existsSync()) {
      // coverage:ignore-start
      return {'path': path, 'exists': false};
      // coverage:ignore-end
    }
    final stat = file.statSync();
    return {'path': path, 'exists': true, 'length': stat.size, 'modifiedMicros': stat.modified.microsecondsSinceEpoch};
  }

  /// `flutter build ios --config-only` for the login E2E, returning the app's
  /// `PRODUCT_BUNDLE_IDENTIFIER` (needed by the xcodebuild step) on success, or
  /// null (after logging) on failure.
  ///
  /// Reused by `mplatrol build` as the iOS arm that runs concurrently with the
  /// Android `patrol build android`. `--config-only` only writes the Flutter
  /// xcconfig (it records the target path but does NOT read `test_bundle.dart`),
  /// so it is safe to run while the Android arm is generating that bundle.
  Future<String?> buildIosConfigOnly({required String? target}) async {
    final iosDir = _fileSystem.getIosDirectory().path;
    try {
      // Regenerate RunnerUITests.m so `mplatrol build` compiles the CURRENT
      // tests (the Android arm regenerates its runner too). This writes only
      // RunnerUITests.m — never test_bundle.dart — so it stays parallel-safe
      // with the concurrent Android bundle generation.
      final repo = _fileSystem.getAppDirectory().path;
      final bundleId = await _readBundleId(iosDir);
      final methodCount = generateIosPatrolRunner(
        repo,
        bundleId: bundleId,
        target: target,
        env: _platform.environment,
      );
      _logger.info('Generated RunnerUITests with $methodCount test method(s)');
      // `mplatrol build` compiles the bundle the Android arm's `patrol build`
      // generates, so it targets Patrol's shared `test_bundle.dart`.
      final sharedBundle = p.join(target != null ? p.dirname(target) : patrolTestDirectory(repo), 'test_bundle.dart');
      await _flutterConfigOnly(bundle: sharedBundle, bundleId: bundleId);
      return bundleId;
    } on _RunnerFailure catch (failure) {
      _logger.err(failure.message);
      return null;
    }
  }

  /// `xcodebuild build-for-testing` for the login E2E (reads the now-stable
  /// `test_bundle.dart`), returning [ExitCode.success] or a non-zero code after
  /// logging. Reused by `mplatrol build` after the bundle has been generated.
  Future<int> buildIosForTesting({required String bundleId}) async {
    final iosDir = _fileSystem.getIosDirectory().path;
    try {
      await _xcodebuildForTesting(iosDir: iosDir, bundleId: bundleId);
    } on _RunnerFailure catch (failure) {
      _logger.err(failure.message);
      return failure.exitCode;
    }
    return ExitCode.success.code;
  }

  /// Builds, re-signs, and packages the iOS app + XCUITest runner IPAs for
  /// HyperExecute `ios/xcui`. This deliberately does not upload or trigger the
  /// old mobile API path; HyperExecute consumes the local IPA paths in YAML.
  /// Patrol shards are represented in HyperExecute YAML only; this packages one
  /// full XCUITest runner IPA so the iOS run stays a single LambdaTest build.
  Future<IosHyperexecuteArtifacts?> buildIosForHyperexecute({
    required String? target,
    required Map<String, String> env,
    String? targetRegex,
    String? sdk,
    bool reuseLast = false,
    List<IosTestShard> shards = const [],
    PatrolSelectionPlan? selection,
    String selectionCoordinatorUrl = '',
  }) async {
    final iosDir = _fileSystem.getIosDirectory().path;
    final productsDir = p.join(iosDir, env['XCUI_PRODUCTS_DIR'] ?? defaultProductsDir);
    final appPath = p.join(productsDir, 'Runner.app');
    final runnerPath = p.join(productsDir, 'RunnerUITests-Runner.app');
    final appIpa = p.join(productsDir, 'Runner.ipa');
    final testIpa = p.join(productsDir, 'RunnerUITests-Runner.ipa');
    final inputCachePath = p.join(productsDir, 'hyperexecute-inputs.json');

    final inputs = _perTestCacheInputs(
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env,
      selectionCoordinatorUrl: selectionCoordinatorUrl,
    );
    IosHyperexecuteArtifacts reuse((String, String) ids) => IosHyperexecuteArtifacts(
        appPath: appIpa, testSuitePath: testIpa, appId: ids.$1, testSuiteAppId: ids.$2, productsDir: productsDir);
    try {
      final identity = _heIosIdentity(inputs, env, shards, selection);
      if (_sharedIosUpload(identity, env, quiet: true) case final ids?) {
        return reuse(ids);
      }
      final miss = _heIosCacheMiss(inputCachePath, identity, appIpa, testIpa);
      if (miss == null) {
        _logger.info('[reuse] exact iOS artifact receipt matched; skipping build/package');
        getDep<ItRunResults>().buildReused();
        return _recordSharedIosUpload(
            identity,
            env,
            await _uploadVerifiedHeIos(
              inputs: inputs,
              env: env,
              shards: shards,
              identity: identity,
              appIpa: appIpa,
              testIpa: testIpa,
              productsDir: productsDir,
              receiptPath: inputCachePath,
              selection: selection,
            ));
      }
      if (reuseLast) {
        _logger.err('--reuse-last: cached HyperExecute IPAs have different E2E inputs '
            'or invalid artifacts: $miss; rebuild without --reuse-last.');
        return null;
      }
      _logger.info('[reuse] iOS artifact cache miss: $miss; building normally');
      final receipt = File(inputCachePath);
      if (receipt.existsSync()) {
        receipt.deleteSync();
      }
      final prepared = await _prepareHeIos(
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        env: env,
        selection: selection,
        selectionCoordinatorUrl: selectionCoordinatorUrl,
      );
      final compiledIdentity = _heIosIdentity(inputs, env, shards, selection);
      if (_sharedIosUpload(compiledIdentity, env) case final ids?) {
        return reuse(ids);
      }
      await _xcodebuildForTesting(iosDir: iosDir, bundleId: prepared);
      await _resign(env: env, appPath: appPath, runnerPath: runnerPath);
      await _packageIpa(appPath, appIpa);
      await _packageIpa(runnerPath, testIpa);
      if (_heIosIdentity(inputs, env, shards, selection) != compiledIdentity) {
        throw _RunnerFailure('iOS compiled inputs changed during build; rebuild.', 69);
      }
      receipt.writeAsStringSync(jsonEncode({
        'schema': 3,
        'identity': compiledIdentity,
        'artifacts': _heIosPair(appIpa, testIpa),
      }));
      return _recordSharedIosUpload(
          compiledIdentity,
          env,
          await _uploadVerifiedHeIos(
            inputs: inputs,
            env: env,
            shards: shards,
            identity: compiledIdentity,
            appIpa: appIpa,
            testIpa: testIpa,
            productsDir: productsDir,
            receiptPath: inputCachePath,
            selection: selection,
          ));
    } on _RunnerFailure catch (failure) {
      _logger.err(failure.message);
      return null;
    } on LtUploadFailure catch (failure) {
      reportLtUploadFailure(failure, repo: _fileSystem.getAppDirectory().path);
      return null;
    } catch (error) {
      _logger.err('Preparing iOS HyperExecute IPAs failed (${error.runtimeType}); '
          'check prepared dependency inputs and artifact files.');
      return null;
    }
  }

  /// The app and test ids an earlier upload of build [identity] got, from the
  /// per-user artifact cache shared by every checkout; null (after logging
  /// why, unless [quiet] and nothing was recorded) when there is none to reuse.
  (String, String)? _sharedIosUpload(String identity, Map<String, String> env, {bool quiet = false}) {
    final path = sharedArtifactPath('ios', identity, env);
    if (path == null) {
      return null;
    }
    final record = File(path).existsSync() ? tryDecodeObject(File(path).readAsStringSync()) : null;
    final ids = _sharedIosIds(record, identity);
    final miss = sharedArtifactMiss(path) ??
        (ids == null ? 'the upload recorded for build identity ${shortIdentity(path)} is malformed' : null);
    if (miss != null) {
      if (!quiet || File(path).existsSync()) {
        _logger.info('[artifact-cache] miss: $miss; building and uploading the iOS pair');
      }
      return null;
    }
    final age = DateTime.now().difference(File(path).lastModifiedSync());
    _logger.info('[artifact-cache] hit: build identity ${shortIdentity(path)} was uploaded '
        '${age.inHours >= 1 ? '${age.inHours}h' : '${age.inMinutes}m'} ago '
        '(app=${ids!.$1} test=${ids.$2}); skipping the iOS build, package and upload');
    getDep<ItRunResults>().buildReused();
    return ids;
  }

  (String, String)? _sharedIosIds(Map<String, dynamic>? record, String identity) {
    final app = record?['app'];
    final test = record?['test'];
    return record?['schema'] == 1 &&
            record?['identity'] == identity &&
            app is String &&
            app.isNotEmpty &&
            test is String &&
            test.isNotEmpty
        ? (app, test)
        : null;
  }

  /// Records [uploaded] as the upload of build [identity] in the per-user
  /// artifact cache, and returns it.
  IosHyperexecuteArtifacts _recordSharedIosUpload(
      String identity, Map<String, String> env, IosHyperexecuteArtifacts uploaded) {
    final path = sharedArtifactPath('ios', identity, env);
    if (path != null) {
      Directory(p.dirname(path)).createSync(recursive: true);
      // Written aside and renamed, so a concurrent reader never sees half a record.
      final aside = File('$path.$pid.tmp')
        ..writeAsStringSync(jsonEncode({
          'schema': 1,
          'identity': identity,
          'app': uploaded.appId,
          'test': uploaded.testSuiteAppId,
        }));
      aside.renameSync(path);
      _logger.info('[artifact-cache] recorded the iOS upload for build identity ${shortIdentity(path)}');
    }
    return uploaded;
  }

  Future<String> _prepareHeIos({
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required Map<String, String> env,
    required PatrolSelectionPlan? selection,
    required String selectionCoordinatorUrl,
  }) async {
    final repo = _fileSystem.getAppDirectory().path;
    final bundle =
        await _generateIosTestBundle(repo, target: target, targetRegex: targetRegex, sdk: sdk, selection: selection);
    final bundleId = await _readBundleId(_fileSystem.getIosDirectory().path);
    final count = generateIosPatrolRunner(repo,
        bundleId: bundleId,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        selection: selection,
        selectionCoordinatorUrl: selectionCoordinatorUrl,
        env: env);
    _logger.info('Generated RunnerUITests with $count test method(s)');
    await _flutterConfigOnly(bundle: bundle, bundleId: bundleId, env: env);
    return bundleId;
  }

  String? _heIosCacheMiss(String receiptPath, String identity, String app, String test) {
    if (!File(app).existsSync() || !File(test).existsSync()) {
      return 'missing HyperExecute IPA(s), including RunnerUITests-Runner.ipa';
    }
    final file = File(receiptPath);
    if (!file.existsSync()) {
      return 'artifact receipt is missing';
    }
    final receipt = tryDecodeObject(file.readAsStringSync());
    if (receipt?['schema'] != 3 || receipt?['identity'] != identity) {
      return 'artifact input receipt is malformed, outdated or stale';
    }
    return jsonEncode(receipt?['artifacts']) == jsonEncode(_heIosPair(app, test)) ? null : 'compiled IPA pair changed';
  }

  Map<String, Object> _heIosPair(String app, String test) => {
        for (final path in [app, test])
          p.basename(path): {
            'path': path,
            'digest': (FingerprintBuilder()..addBytes(File(path).readAsBytesSync())).finish(),
          },
      };

  Future<IosHyperexecuteArtifacts> _uploadVerifiedHeIos({
    required Map<String, Object?> inputs,
    required Map<String, String> env,
    required List<IosTestShard> shards,
    required String identity,
    required String appIpa,
    required String testIpa,
    required String productsDir,
    required String receiptPath,
    required PatrolSelectionPlan? selection,
  }) async {
    if (_heIosIdentity(inputs, env, shards, selection) != identity ||
        _heIosCacheMiss(receiptPath, identity, appIpa, testIpa) != null) {
      throw _RunnerFailure('iOS inputs or IPA pair changed before upload; rebuild.', 69);
    }
    final result =
        await _uploadHyperexecuteArtifacts(appIpa: appIpa, testIpa: testIpa, productsDir: productsDir, env: env);
    if (_heIosIdentity(inputs, env, shards, selection) != identity ||
        _heIosCacheMiss(receiptPath, identity, appIpa, testIpa) != null) {
      throw _RunnerFailure('iOS inputs or IPA pair changed during upload; rebuild.', 69);
    }
    return result;
  }

  String _heIosIdentity(Map<String, Object?> inputs, Map<String, String> env, List<IosTestShard> supplied,
      PatrolSelectionPlan? selection) {
    final repo = _fileSystem.getAppDirectory().path;
    final methods = _heIosMethods(repo, inputs, env, supplied, selection);
    if (!File(p.join(repo, 'pubspec.yaml')).existsSync()) {
      throw StateError('Prepared iOS app pubspec is missing');
    }
    final compilerEnv = {..._platform.environment, ...env};
    final builder = FingerprintBuilder()
      ..addString('he-ios-compiled-pair:2:profile:config-only:patrol-enabled')
      ..addString(jsonEncode({...inputs}..remove('defineFile')))
      ..addString(jsonEncode(methods))
      ..addString(selection == null
          ? 'sdk-selection:none'
          : 'sdk-selection:${selection.requirementsDigest}:${selection.capabilityDigest}')
      ..addString(jsonEncode(e2eRuntimeDartDefines(repo, env)))
      ..addString(jsonEncode({
        for (final key in const [
          'DEVELOPER_DIR',
          'SDKROOT',
          'FLUTTER_ROOT',
          'PATH',
          'CC',
          'CXX',
          'XCODE_XCCONFIG_FILE',
          'CODESIGN_TEAM',
          'CODESIGN_IDENTITY',
          'LT_IOS_PROVISIONING_PROFILE',
          'XCUI_PRODUCTS_DIR',
          'DART_DEFINES',
          'OTHER_SWIFT_FLAGS',
          'OTHER_CFLAGS',
          'OTHER_LDFLAGS'
        ])
          if (compilerEnv.containsKey(key)) key: compilerEnv[key],
      }));
    final assets = _heIosAssets(repo);
    final credentials = _heIosCredentialPayload(repo, env, assets);
    for (final relative in {
      'lib',
      'ios',
      patrolTestDirectory(repo),
      'integration_test',
      'assets',
      'tenants',
      'pubspec.yaml',
      'pubspec.lock',
      'pubspec_overrides.yaml',
      'build.yaml',
      'mplatrol.yaml',
      'Makefile',
      'melos.yaml',
      '.fvmrc',
      '.fvm/fvm_config.json',
      '.dart_tool/version',
      '.flutter-plugins',
      '.flutter-plugins-dependencies',
      ...assets,
    }.toList()
      ..sort()) {
      _heIosHashPath(builder, p.join(repo, relative), 'app/$relative', {}, credentials);
    }
    for (final key in ['LT_IOS_PROVISIONING_PROFILE', 'XCODE_XCCONFIG_FILE']) {
      if (env[key]?.isNotEmpty ?? false) {
        _heIosHashPath(builder, env[key]!, 'compiler/$key', {}, null);
      }
    }
    _heIosPackages(builder, repo);
    return builder.finish();
  }

  String? _heIosCredentialPayload(String repo, Map<String, String> env, List<String> assets) {
    final path = e2eCredentialsFilePath(repo, env);
    if (path == null) {
      return null;
    }
    if (p.extension(path).toLowerCase() != '.json') {
      throw StateError('Runtime credential input must be a JSON file, not compiled source');
    }
    final compiled = [...assets, 'lib', 'ios', patrolTestDirectory(repo), 'assets', 'tenants'];
    if (compiled.any((input) => p.equals(p.join(repo, input), path) || p.isWithin(p.join(repo, input), path))) {
      return null;
    }
    return path;
  }

  List<String> _heIosMethods(String repo, Map<String, Object?> inputs, Map<String, String> env,
      List<IosTestShard> supplied, PatrolSelectionPlan? selection) {
    final selected = iosTestShards(repo,
        target: _heOptionalSelection(inputs['target']),
        targetRegex: _heOptionalSelection(inputs['targetRegex']),
        sdk: _heOptionalSelection(inputs['sdk']),
        env: env,
        selection: selection);
    final methods = selected.map((shard) => shard.onlyTesting).toList();
    if (methods.isEmpty ||
        (supplied.isNotEmpty &&
            jsonEncode(supplied.map((shard) => shard.onlyTesting).toList()) != jsonEncode(methods))) {
      throw _RunnerFailure('Selected iOS identities do not match producer inputs.', 69);
    }
    return methods;
  }

  String? _heOptionalSelection(Object? value) => value == '' ? null : value as String?;

  void _heIosPackages(FingerprintBuilder builder, String repo) {
    final config = File(p.join(repo, '.dart_tool', 'package_config.json'));
    final bytes = config.readAsBytesSync();
    builder.addBytes(checkoutIndependentBytes(repo, '.dart_tool/package_config.json', bytes));
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || data['configVersion'] != 2 || data['packages'] is! List) {
      throw StateError('Prepared iOS package resolution must contain a package list');
    }
    final packages = (data['packages'] as List).cast<Map>().toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    final names = <String>{};
    for (final package in packages) {
      final name = package['name'] as String;
      if (!names.add(name)) {
        throw StateError('Duplicate prepared iOS package identity');
      }
      final root = _heIosPackageRoot(config, package);
      if (p.equals(p.normalize(root), p.normalize(repo))) {
        continue;
      }
      for (final input in {
        package['packageUri'] as String? ?? 'lib/',
        'ios',
        'darwin',
        'macos',
        'src',
        'native',
        'hook',
        'hooks',
        'pubspec.yaml',
        'pubspec.lock',
        'build.yaml',
        ..._heIosAssets(root),
      }.toList()
        ..sort()) {
        _heIosHashPath(builder, p.join(root, input), 'package:$name/$input', {}, null);
      }
    }
  }

  String _heIosPackageRoot(File config, Map package) {
    final uri = config.parent.uri.resolve(package['rootUri'] as String);
    if (uri.scheme != 'file' || !Directory(uri.toFilePath()).existsSync()) {
      throw StateError('Prepared iOS package roots must be existing local directories');
    }
    final source = package['packageUri'] as String? ?? 'lib/';
    if (p.isAbsolute(source) || p.split(p.normalize(source)).contains('..')) {
      throw StateError('Invalid resolved iOS package source path');
    }
    return uri.toFilePath();
  }

  List<String> _heIosAssets(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return [];
    }
    final doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) {
      throw StateError('Malformed iOS build asset metadata');
    }
    final flutter = doc['flutter'];
    if (flutter == null) {
      return [];
    }
    if (flutter is! YamlMap) {
      throw StateError('Malformed Flutter build asset metadata');
    }
    final paths = <Object?>[
      for (final asset in flutter['assets'] as List? ?? []) asset is Map ? asset['path'] : asset,
      ...flutter['shaders'] as List? ?? [],
      ..._heIosFontAssets(flutter['fonts']),
    ];
    return paths.map(_heIosAssetPath).toList();
  }

  List<Object?> _heIosFontAssets(Object? fonts) => [
        for (final font in fonts as List? ?? [])
          for (final entry in (font as Map)['fonts'] as List) (entry as Map)['asset'],
      ];

  String _heIosAssetPath(Object? value) {
    if (value is! String || value.isEmpty || p.isAbsolute(value) || p.split(p.normalize(value)).contains('..')) {
      throw StateError('Invalid declared iOS build asset path');
    }
    return value;
  }

  void _heIosHashPath(
      FingerprintBuilder builder, String path, String label, Set<String> ancestors, String? credentials) {
    if (p.equals(path, credentials ?? '') || _heIosOutput(label)) {
      return;
    }
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    builder.addString(label);
    if (type == FileSystemEntityType.notFound) {
      builder.addString('absent');
    } else if (type == FileSystemEntityType.link) {
      final resolved = File(path).resolveSymbolicLinksSync();
      builder.addString(resolved);
      _heIosHashPath(builder, resolved, label, ancestors, credentials);
    } else if (type == FileSystemEntityType.directory) {
      _heIosHashDirectory(builder, path, label, ancestors, credentials);
    } else if (type == FileSystemEntityType.file) {
      final bytes = File(path).readAsBytesSync();
      builder.addBytes(label.startsWith('app/')
          ? checkoutIndependentBytes(_fileSystem.getAppDirectory().path, label.substring(4), bytes)
          : bytes);
    } else {
      throw StateError('Unsupported iOS compilation input type');
    }
  }

  void _heIosHashDirectory(
      FingerprintBuilder builder, String path, String label, Set<String> ancestors, String? credentials) {
    final real = Directory(path).resolveSymbolicLinksSync();
    if (ancestors.contains(real)) {
      throw StateError('Cyclic iOS compilation input link');
    }
    final entries = Directory(path).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      _heIosHashPath(builder, entry.path, '$label/${p.basename(entry.path)}', {...ancestors, real}, credentials);
    }
  }

  bool _heIosOutput(String label) =>
      p.split(label).any(['.git', '.symlinks', '.gradle', 'DerivedData'].contains) ||
      ['/ios/build', '/darwin/build', '/macos/build']
          .any((suffix) => label.endsWith(suffix) || label.contains('$suffix/')) ||
      _sharedPatrolBundle(label);

  /// Patrol's shared bundle files, which a concurrent Android build rewrites.
  /// iOS compiles its own [iosPatrolTestBundleFile] (hashed with the rest of
  /// the test directory) and only copies `test_bundle.dart` scaffolding.
  bool _sharedPatrolBundle(String label) =>
      p.split(label).length == 3 &&
      const {
        'test_bundle.dart',
        'test_bundle_test.dart',
        'mplatrol_filtered_test.dart',
        'mplatrol_filtered_test_bundle_test.dart',
      }.contains(p.basename(label));

  /// Uploads the app + test-suite [appIpa]/[testIpa] to LambdaTest (each named
  /// by its basename) at the same time, and returns the HyperExecute artifacts
  /// referencing them. The first failed upload's error is thrown.
  Future<IosHyperexecuteArtifacts> _uploadHyperexecuteArtifacts({
    required String appIpa,
    required String testIpa,
    required String productsDir,
    required Map<String, String> env,
  }) async {
    final ids = await Future.wait([
      for (final ipa in [appIpa, testIpa]) _uploadToLambdaTest(ipaPath: ipa, ltName: p.basename(ipa), env: env),
    ]);
    return IosHyperexecuteArtifacts(
      appPath: appIpa,
      testSuitePath: testIpa,
      appId: ids[0],
      testSuiteAppId: ids[1],
      productsDir: productsDir,
    );
  }

  /// Writes the iOS-owned [iosPatrolTestBundleFile] importing exactly the
  /// Patrol files this iOS run selects, and returns its repo-relative path.
  ///
  /// The iOS custom build compiles a bundle, not the raw test (see
  /// [_flutterConfigOnly]), so the bundle decides which Dart tests run and the
  /// names they report: each selected file's `main()` is grouped under its own
  /// basename, so every Dart test name is `<file basename> <description>`.
  /// Patrol's shared `test_bundle.dart` and `mplatrol_filtered_test.dart` belong to
  /// the Android arm, which regenerates them while an `lt-all` iOS build runs
  /// concurrently; compiling them made iOS run Android's selection. The shared
  /// bundle is only read as the scaffolding templatrole (its PatrolAppService
  /// code is target-independent and matches the installed Patrol version); a
  /// fresh checkout without one gets the scaffolding from patrol_cli's bundler
  /// (see [generatePatrolBundleTemplatrole]).
  Future<String> _generateIosTestBundle(
    String repo, {
    required String? target,
    required String? targetRegex,
    required String? sdk,
    PatrolSelectionPlan? selection,
  }) async {
    final testDirectory = patrolTestDirectoryPath(repo);
    final templatrolePath = p.join(testDirectory, 'test_bundle.dart');
    final modules = [
      for (final file
          in discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex, sdk: sdk, selection: selection))
        file.basename,
    ];
    if (modules.isEmpty) {
      // coverage:ignore-start
      throw _RunnerFailure('No selected Patrol tests in $testDirectory to bundle.', ExitCode.usage.code);
      // coverage:ignore-end
    }
    final bundlePath = p.join(testDirectory, iosPatrolTestBundleFile);
    final retargeted = _replaceBundleRegion(
      _replaceBundleRegion(
        await _bundleTemplatrole(templatrolePath, modules.first),
        marker: 'GENERATED TEST IMPORTS',
        body: modules.map((m) => "import '$m.dart' as $m;").join('\n'),
        bundlePath: templatrolePath,
      ),
      marker: 'GENERATED TEST GROUPS',
      body: modules.map((m) => "  group('$m', () { $m.main(); });").join('\n'),
      bundlePath: templatrolePath,
    );
    File(bundlePath).writeAsStringSync(retargeted);
    _logger.info('[bundle] $iosPatrolTestBundleFile -> ${modules.join(', ')}');
    return p.relative(bundlePath, from: repo).replaceAll('\\', '/');
  }

  /// Patrol's shared bundle at [templatrolePath] when an Android build left one,
  /// otherwise scaffolding generated for [module] without touching that file.
  Future<String> _bundleTemplatrole(String templatrolePath, String module) async {
    final templatrole = File(templatrolePath);
    if (templatrole.existsSync()) {
      return templatrole.readAsStringSync();
    }
    _logger.info('[bundle] no $templatrolePath yet (fresh checkout); generating Patrol scaffolding');
    try {
      return await generatePatrolBundleTemplatrole(module);
    } on PatrolBundleTemplatroleException catch (error) {
      throw _RunnerFailure(error.message, error.exitCode);
    }
  }

  /// Replaces the text between `// START: <marker>` and `// END: <marker>` in
  /// [content] with [body] (keeping the markers). Throws when a marker is absent
  /// — a bundle we can't safely retarget.
  String _replaceBundleRegion(
    String content, {
    required String marker,
    required String body,
    required String bundlePath,
  }) {
    final start = '// START: $marker';
    final end = '// END: $marker';
    final startIdx = content.indexOf(start);
    final endIdx = content.indexOf(end);
    if (startIdx < 0 || endIdx < 0 || endIdx < startIdx) {
      throw _RunnerFailure(
        '$bundlePath is missing the "$marker" markers; cannot retarget it. '
        'Regenerate it with `mplatrol build`.',
        ExitCode.software.code,
      );
    }
    return '${content.substring(0, startIdx + start.length)}\n$body\n'
        '${content.substring(endIdx)}';
  }

  Future<void> _flutterConfigOnly({required String bundle, required String bundleId, Map<String, String>? env}) async {
    // Build from a generated Patrol test [bundle], NOT the raw test file. The
    // bundle hosts the PatrolAppService and reports appReady to the native
    // runner; building the raw target leaves `patrolAppService` uninitialized
    // (LateInitializationError) so the XCUITest handshake never completes. The
    // Android runner gets this for free via `patrol build android`; the iOS
    // custom build must point at the bundle itself.
    final repo = _fileSystem.getAppDirectory().path;
    await _cleanIfSimulatorFrameworks(repo);
    final runnerEnv = env ?? _platform.environment;
    writeE2eRuntimeAssetConfig(repo, runnerEnv);
    writeIosDartDefines(repo, [
      'LT_PROXY=true',
      'E2E_TEST_BRIDGE=true',
      'PATROL_APP_BUNDLE_ID=$bundleId',
      ...e2eRuntimeDartDefines(repo, runnerEnv).entries.map((entry) => '${entry.key}=${entry.value}'),
    ]);
    final e2eDefinesFlags = e2eDartDefineFlags(repo, runnerEnv);
    _logger.info('[build] dart pub global run fvm:main flutter build ios (--config-only --profile)');
    final configResult = await _shell.run(
      '$_patrolEnabledEnv dart pub global run fvm:main flutter build ios --config-only --profile '
      '--target=${shellQuote(bundle)} '
      '--dart-define=LT_PROXY=true --dart-define=E2E_TEST_BRIDGE=true '
      '--dart-define=PATROL_APP_BUNDLE_ID=${shellQuote(bundleId)} '
      '--no-pub --no-tree-shake-icons'
      '$e2eDefinesFlags',
      throwOnError: false,
      quietBuild: true,
      workingDirectory: repo,
    );
    if (configResult.exitCode != ExitCode.success.code) {
      throw _RunnerFailure(
        'dart pub global run fvm:main flutter build ios --config-only failed '
        '(exit ${configResult.exitCode}).',
        ExitCode.software.code,
      );
    }
  }

  Future<void> _xcodebuildForTesting({required String iosDir, required String bundleId}) async {
    // PATROL_ENABLED (Swift compilation condition) gates Patrol's native
    // automation server. With Flutter's Swift Package Manager integration,
    // Patrol's Package.swift reads PATROL_ENABLED from the environment instead
    // and only then weak-links XCTest, so it is exported too ([_patrolEnabledEnv]);
    // without it the link fails on XCUIApplication in PatrolImpl.o. PATROL_TARGET_BUNDLE_ID (ObjC macro) tells
    // RunnerUITests.m which app XCUIApplication launches on LambdaTest. Both
    // must match the Makefile recipe or the XCUITest run idles out. `-quiet`
    // drops xcodebuild's command-line settings echo + per-file progress (it is
    // a pure build, so there are no test lines to lose); warnings/errors still
    // print and quietBuild surfaces the tail on failure.
    await _clearStaleSwiftModules(iosDir);
    _logger.info('[build] xcodebuild build-for-testing (PATROL_ENABLED)');
    final buildResult = await _shell.run(
      '$_patrolEnabledEnv xcodebuild build-for-testing -quiet -workspace Runner.xcworkspace '
      '-scheme Runner -configuration Profile -destination generic/platform=iOS '
      '-derivedDataPath build/xcui-lt '
      "GCC_PREPROCESSOR_DEFINITIONS='\$(inherited) PATROL_TARGET_BUNDLE_ID=$bundleId' "
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS='\$(inherited) PATROL_ENABLED' "
      // Patrol's SPM package weak-links XCTest (and its Swift support library)
      // into the app target; CocoaPods added these platform folders to the
      // search paths, SPM does not.
      "FRAMEWORK_SEARCH_PATHS='\$(inherited) \$(PLATFORM_DIR)/Developer/Library/Frameworks' "
      "LIBRARY_SEARCH_PATHS='\$(inherited) \$(PLATFORM_DIR)/Developer/usr/lib' "
      // Weak, so the app still launches where XCTest's Swift support library is not on its rpath (dyld
      // "Library not loaded: @rpath/libXCTestSwiftSupport.dylib" on iOS 17 devices).
      "OTHER_LDFLAGS='\$(inherited) -weak-lXCTestSwiftSupport' "
      'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES '
      'CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_USER_SCRIPT_SANDBOXING=NO',
      throwOnError: false,
      quietBuild: true,
      workingDirectory: iosDir,
    );
    if (buildResult.exitCode != ExitCode.success.code) {
      reportTestLessons('${buildResult.outText}\n${buildResult.errText}',
          repo: _fileSystem.getAppDirectory().path, logger: _logger);
      throw _RunnerFailure(
        'xcodebuild build-for-testing failed (exit ${buildResult.exitCode}).',
        ExitCode.software.code,
      );
    }
  }

  /// Xcode keys the Swift explicit precompiled modules in `build/xcui-lt` by path, so after a pod or plugin version
  /// switch on the same lane it reused modules of the old SDK and the link failed (r12 cyberdyne: Visa SDK 1.2.0 to
  /// 1.3.0, `Undefined symbols ... VPCardProvisioningRequest.init(walletCode:walletName:)`). The digest of
  /// `ios/Podfile.lock` and the resolved plugin set is kept in [_podsDigestFile]; when it differs, or is missing
  /// beside existing caches, the Swift module caches go to the Trash before the build. When they cannot, it
  /// warns and keeps the old digest, so the next build tries again.
  Future<void> _clearStaleSwiftModules(String iosDir) async {
    final derived = p.join(iosDir, 'build', 'xcui-lt');
    final stamp = File(p.join(derived, _podsDigestFile));
    final digest = _podsDigest(iosDir);
    final previous = stamp.existsSync() ? stamp.readAsStringSync().trim() : null;
    if (previous != digest) {
      final caches = [
        for (final cache in const [
          'Build/Intermediates.noindex/SwiftExplicitPrecompiledModules',
          'ModuleCache.noindex',
          // SwiftPM keeps the evaluated package graph here; Patrol's manifest
          // must be evaluated again when its PATROL_ENABLED input changes.
          'SourcePackages',
        ])
          if (Directory(p.join(derived, cache)).existsSync()) p.join(derived, cache),
      ];
      if (caches.isNotEmpty) {
        final outcome = await getDep<TrashMover>().move(caches, dryRun: false);
        if (outcome.failed.isNotEmpty) {
          _logger.warn('[ios-build] pods changed since the last build, but the stale Swift module caches could not '
              'go to the Trash (${outcome.failed.join(', ')}); if the link fails, move $derived to the Trash.');
          return;
        }
        _logger.info('[ios-build] pods changed since the last build; cleared stale Swift module caches');
      }
    }
    stamp
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(digest);
  }

  static const _podsDigestFile = 'mplatrol-pods.digest';

  /// Exported for Flutter's SPM integration: Patrol's Package.swift is
  /// evaluated with the build's environment, not its build settings.
  static const _patrolEnabledEnv = 'env PATROL_ENABLED=1';

  /// Changes the build digest so DerivedData resolved before PATROL_ENABLED
  /// was exported (Patrol's package graph without XCTest) is cleared once.
  static const _digestSchema = 'spm-patrol-enabled-env:1';

  /// The digest of `ios/Podfile.lock` and the resolved plugin set (`.flutter-plugins-dependencies` without its
  /// creation date) of the checkout [iosDir] belongs to.
  String _podsDigest(String iosDir) {
    final fingerprint = FingerprintBuilder()..addString(_digestSchema);
    final podfileLock = File(p.join(iosDir, 'Podfile.lock'));
    fingerprint.addString(podfileLock.existsSync() ? podfileLock.readAsStringSync() : '');
    final plugins = File(p.join(p.dirname(iosDir), '.flutter-plugins-dependencies'));
    final resolved = plugins.existsSync() ? jsonDecode(plugins.readAsStringSync()) : null;
    fingerprint.addString(jsonEncode(resolved is Map ? resolved['plugins'] : null));
    return fingerprint.finish();
  }

  /// Flutter keeps native-asset frameworks (package:objective_c, ...) in
  /// `build/native_assets/ios` keyed only by name, so a simulator build leaves
  /// IOSSIMULATOR frameworks that a later device build embeds unchanged. When
  /// one is found, do the iOS equivalent of `flutter clean` (`build`,
  /// `ios/build`, `.dart_tool/flutter_build`) so the next build starts fresh.
  /// Nothing is touched when the frameworks are device builds or absent.
  Future<void> _cleanIfSimulatorFrameworks(String repo) async {
    final assets = Directory(p.join(repo, 'build', 'native_assets', 'ios'));
    if (!assets.existsSync() || !await _hasSimulatorFramework(assets)) {
      return;
    }
    _logger.info('[build] simulator native assets found; cleaning iOS build state');
    for (final path in [
      p.join(repo, 'build'),
      p.join(repo, 'ios', 'build'),
      p.join(repo, '.dart_tool', 'flutter_build'),
    ]) {
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  }

  Future<bool> _hasSimulatorFramework(Directory assets) async {
    for (final framework in assets.listSync().whereType<Directory>()) {
      final name = p.basenameWithoutExtension(framework.path);
      final binary = p.join(framework.path, name);
      if (!File(binary).existsSync()) {
        continue;
      }
      final build = await _shell.runArgs('vtool', ['-show-build', binary], throwOnError: false);
      if (build.outText.contains('IOSSIMULATOR')) {
        return true;
      }
    }
    return false;
  }

  /// Fails before upload when a native-asset framework listed in the app's
  /// `NativeAssetsManifest.json` is missing from `Runner.app/Frameworks` or was
  /// built for the simulator (the device then fails dlopen at app start).
  Future<void> _verifyNativeAssets(String appPath) async {
    final manifest =
        File(p.join(appPath, 'Frameworks', 'App.framework', 'flutter_assets', 'NativeAssetsManifest.json'));
    if (!manifest.existsSync()) {
      return;
    }
    final assets = (jsonDecode(manifest.readAsStringSync()) as Map)['native-assets'];
    final arm64 = assets is Map ? assets['ios_arm64'] : null;
    if (arm64 is! Map) {
      return;
    }
    for (final mapping in arm64.values) {
      final relative = (mapping as List).last as String;
      final binary = p.join(appPath, 'Frameworks', relative);
      if (!File(binary).existsSync()) {
        throw _RunnerFailure(
          'Native-asset framework $relative is listed in NativeAssetsManifest.json but '
          'missing from $appPath/Frameworks; the app would fail dlopen on the device. '
          'Run a full clean (build, ios/build, .dart_tool/flutter_build) and rebuild.',
          ExitCode.software.code,
        );
      }
      final build = await _shell.runArgs('vtool', ['-show-build', binary], throwOnError: false);
      if (build.outText.contains('IOSSIMULATOR')) {
        throw _RunnerFailure(
          'Native-asset framework $relative is built for the iOS simulator, not the device. '
          'Run a full clean (build, ios/build, .dart_tool/flutter_build) and rebuild.',
          ExitCode.software.code,
        );
      }
    }
  }

  /// The app's `PRODUCT_BUNDLE_IDENTIFIER` for the Profile config, read from the
  /// Xcode project (never hard-coded) — needed for the PATROL_* build inputs.
  Future<String> _readBundleId(String iosDir) async {
    final result = await _shell.run(
      'xcodebuild -showBuildSettings -workspace Runner.xcworkspace '
      '-scheme Runner -configuration Profile',
      throwOnError: false,
      silent: true,
      workingDirectory: iosDir,
    );
    for (final line in result.outLines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('PRODUCT_BUNDLE_IDENTIFIER = ')) {
        return trimmed.split(' = ').last.trim();
      }
    }
    throw _RunnerFailure('Could not read PRODUCT_BUNDLE_IDENTIFIER from the Xcode project.', ExitCode.software.code);
  }

  Future<void> _resign({required Map<String, String> env, required String appPath, required String runnerPath}) async {
    await _verifyNativeAssets(appPath);
    _logger.info('[resign] re-signing the XCUITest runner for LambdaTest');
    final team = env[iosTeamIdEnv] ?? IosCodesign.teamId;
    final xctestPath = p.join(runnerPath, 'PlugIns', 'RunnerUITests.xctest');

    final xctestIdResult = await _shell.runArgs(
        'plutil',
        [
          '-extract',
          'CFBundleIdentifier',
          'raw',
          p.join(xctestPath, 'Info.plist'),
        ],
        throwOnError: false);
    if (xctestIdResult.exitCode != ExitCode.success.code) {
      throw _RunnerFailure(
        'Could not read the RunnerUITests.xctest bundle id '
        '(build first; exit ${xctestIdResult.exitCode}).',
        ExitCode.software.code,
      );
    }
    final xctestId = xctestIdResult.outText.trim();
    final runnerId = '$xctestId.xctrunner';

    // Identity + profile are auto-derived (like run_ios_lambdatest_xcui.sh)
    // unless the env overrides them: an Apple Development cert, and the profile
    // whose strings include the xctrunner bundle id.
    final codesign = getDep<IosCodesign>();
    final identity = env['CODESIGN_IDENTITY'] ?? await codesign.developerIdentity();
    if (identity == null || identity.isEmpty) {
      throw _RunnerFailure(
        'No Apple Development signing identity in the keychain '
        '(set CODESIGN_IDENTITY, or see `mplatrol doctor`).',
        ExitCode.usage.code,
      );
    }
    final profile = env['LT_IOS_PROVISIONING_PROFILE'] ?? await codesign.provisioningProfile(runnerId, team: team);
    if (profile == null || profile.isEmpty) {
      throw _RunnerFailure(
        'No provisioning profile for $runnerId (and no $team.* wildcard) — '
        'open ios/Runner.xcworkspace in Xcode once (RunnerUITests target) to '
        'create it, or see `mplatrol doctor`.',
        ExitCode.usage.code,
      );
    }

    File(profile).copySync(p.join(runnerPath, 'embedded.mobileprovision'));

    await _embedFrameworks(appPath: appPath, runnerPath: runnerPath);

    final runnerEntitlements = _entitlements('$team.$runnerId', team);
    final xctestEntitlements = _entitlements('$team.$xctestId', team);

    // Sign nested frameworks/dylibs first, then the xctest, then the runner.
    await _signNestedFrameworks(runnerPath: runnerPath, identity: identity);

    final signXctest = await _codesign(identity: identity, entitlements: xctestEntitlements, bundlePath: xctestPath);
    final signRunner = await _codesign(identity: identity, entitlements: runnerEntitlements, bundlePath: runnerPath);
    if (signXctest.exitCode != ExitCode.success.code || signRunner.exitCode != ExitCode.success.code) {
      throw _RunnerFailure(
        'codesign of the XCUITest runner failed (xctest exit '
        '${signXctest.exitCode}, runner exit ${signRunner.exitCode}).',
        ExitCode.software.code,
      );
    }

    final verify = await _shell.runArgs('codesign', ['--verify', '--verbose', runnerPath], throwOnError: false);
    if (verify.exitCode != ExitCode.success.code) {
      throw _RunnerFailure(
        'codesign --verify of the re-signed runner failed '
        '(exit ${verify.exitCode}).',
        ExitCode.software.code,
      );
    }
  }

  /// Embeds the app's frameworks into the runner. The xctest links ~95 @rpath
  /// frameworks that live in Runner.app/Frameworks; on the device the build
  /// products dir does not exist, so without this the runner fails to dlopen
  /// Flutter.framework and never loads. `ditto` so a rebuilt framework wins.
  Future<void> _embedFrameworks({required String appPath, required String runnerPath}) async {
    final destFrameworks = Directory(p.join(runnerPath, 'Frameworks'))..createSync(recursive: true);
    final sourceFrameworks = Directory(p.join(appPath, 'Frameworks'));
    if (!sourceFrameworks.existsSync()) {
      return;
    }
    for (final entry in sourceFrameworks.listSync()) {
      final name = p.basename(entry.path);
      if (!name.endsWith('.framework') && !name.endsWith('.dylib')) {
        continue;
      }
      await _shell.runArgs('ditto', [entry.path, p.join(destFrameworks.path, name)], throwOnError: false);
    }
  }

  /// Signs every nested `.framework`/`.dylib` under [runnerPath] with the bare
  /// identity (no entitlements) before the xctest and runner are signed.
  Future<void> _signNestedFrameworks({required String runnerPath, required String identity}) async {
    final root = Directory(runnerPath);
    if (!root.existsSync()) {
      return;
    }
    for (final entry in root.listSync(recursive: true, followLinks: false)) {
      final name = p.basename(entry.path);
      if (!name.endsWith('.framework') && !name.endsWith('.dylib')) {
        continue;
      }
      await _shell.runArgs('codesign', ['--force', '--sign', identity, entry.path], throwOnError: false);
    }
  }

  /// Signs [bundlePath] with [identity] and an entitlements plist written to a
  /// temp file (the shell version used a `<(printf ...)` process substitution,
  /// which has no `runArgs` equivalent).
  Future<ProcessResultX> _codesign({
    required String identity,
    required String entitlements,
    required String bundlePath,
  }) async {
    final entitlementsFile = File(
      p.join(Directory.systemTemp.createTempSync('lt_ios_entitlements').path, 'entitlements.plist'),
    )..writeAsStringSync(entitlements);
    try {
      return await _shell.runArgs(
          'codesign',
          [
            '--force',
            '--sign',
            identity,
            '--entitlements',
            entitlementsFile.path,
            bundlePath,
          ],
          throwOnError: false);
    } finally {
      final dir = entitlementsFile.parent;
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  }

  String _entitlements(String appIdentifier, String team) {
    final body = <String>[
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<plist version="1.0"><dict>',
      '<key>application-identifier</key><string>$appIdentifier</string>',
      '<key>com.apple.developer.team-identifier</key><string>$team</string>',
      '<key>get-task-allow</key><true/>',
      '<key>keychain-access-groups</key><array><string>$team.*</string></array>',
      '</dict></plist>',
    ];
    return body.join();
  }

  Future<String> _packageIpa(String appPath, String outIpa) {
    final ipaName = p.basename(outIpa);
    return _withProgress(
      'Packaging $ipaName',
      () async {
        final stageDir = '$outIpa.payload';

        removeIfExists(stageDir);
        removeIfExists(outIpa);
        final payloadDir = Directory(p.join(stageDir, 'Payload'))..createSync(recursive: true);
        // `ditto` (already used for the framework copies) does the recursive
        // .app copy, preserving symlinks/resource forks a real bundle carries.
        final copyResult = await _shell.runArgs(
            'ditto',
            [
              appPath,
              p.join(payloadDir.path, p.basename(appPath)),
            ],
            throwOnError: false);
        if (copyResult.exitCode != ExitCode.success.code) {
          removeIfExists(stageDir);
          throw _RunnerFailure('Staging $ipaName failed (ditto exit ${copyResult.exitCode}).', ExitCode.software.code);
        }

        final zipResult = await _shell.runArgs(
          'zip',
          ['-r', '-q', outIpa, 'Payload'],
          workingDirectory: stageDir,
          throwOnError: false,
        );
        removeIfExists(stageDir);

        if (zipResult.exitCode != ExitCode.success.code) {
          throw _RunnerFailure('Packaging $ipaName failed (exit ${zipResult.exitCode}).', ExitCode.software.code);
        }
        return outIpa;
      },
      completeMessage: 'Packaged $ipaName',
      failMessage: 'Packaging $ipaName failed',
    );
  }

  /// Uploads [ipaPath] straight to LambdaTest and returns the `lt://` app id.
  ///
  /// The upload must be DIRECT, not a url-fetch registration: the HyperExecute
  /// CLI downloads the test-suite IPA right back for local test discovery, and
  /// url-fetch is asynchronous — LT returns the app id in about a second and
  /// ingests the bytes in the background (its ingest of this test suite from a
  /// GitLab package URL was observed to never complete), so discovery dies
  /// with "corrupted or expired". A direct upload has the bytes at LT when the
  /// call returns. Retries, the machine-wide upload cap and the attempt
  /// timeout are [LtAppUpload.uploadLtApp]'s.
  Future<String> _uploadToLambdaTest({
    required String ipaPath,
    required String ltName,
    required Map<String, String> env,
  }) {
    final artifactName = p.basename(ipaPath);
    return _withProgress(
      'Uploading $artifactName to LambdaTest',
      () => uploadLtApp(
        file: ipaPath,
        name: ltName,
        headers: _http.basicAuth(env['LT_USERNAME']!, env['LT_ACCESS_KEY']!),
      ),
      completeMessage: 'Uploaded $artifactName to LambdaTest',
      failMessage: 'Uploading $artifactName to LambdaTest failed',
    );
  }

  Future<T> _withProgress<T>(
    String message,
    Future<T> Function() action, {
    String? completeMessage,
    String? failMessage,
  }) async {
    final progress = _logger.progress(message);
    try {
      final result = await action();
      progress.complete(completeMessage ?? message);
      return result;
    } catch (_) {
      progress.fail(failMessage ?? '$message failed');
      rethrow;
    }
  }

  Future<String> _trigger({
    required String appId,
    required String testId,
    required List<String> devices,
    required String tunnelName,
    required int idleTimeoutSeconds,
    required String buildName,
    required Map<String, String> env,
    List<String> onlyTesting = const [],
  }) async {
    _logger.info(
      '[trigger] $buildName on ${devices.join(', ')}'
      '${onlyTesting.isEmpty ? '' : ' (only-testing: ${onlyTesting.join(', ')})'}',
    );
    final user = env['LT_USERNAME']!;
    final key = env['LT_ACCESS_KEY']!;

    final payload = <String, dynamic>{
      'app': appId,
      'testSuite': testId,
      'device': devices,
      'video': true,
      'deviceLog': true,
      'network': true,
      'queueTimeout': _queueTimeoutSeconds,
      'idleTimeout': idleTimeoutSeconds,
      'build': buildName,
      // Class-level only-testing (`[RunnerUITests]`) so this build runs the one
      // test its uploaded .xctest holds. Only the literal target class resolves
      // on the build API (a method id or a different class errors); the single
      // session is still named testInvocations() but the BUILD name identifies
      // the test.
      if (onlyTesting.isNotEmpty) 'only-testing': onlyTesting,
      if (tunnelName.isNotEmpty) ...{'tunnel': true, 'tunnelName': tunnelName},
    };

    final response = await _http.postJson(
      'https://mobile-api.lambdatest.com/framework/v1/xcui/build',
      headers: _http.basicAuth(user, key),
      body: payload,
    );
    if (response.statusCode >= 400) {
      throw _RunnerFailure(
        'Triggering the XCUITest run failed '
        '(HTTP ${response.statusCode}): ${response.body}',
        ExitCode.software.code,
      );
    }
    final body = _decodeJson(response.body, context: 'XCUITest trigger');
    final buildId = _firstBuildId(body['buildId']);
    if (buildId.isEmpty) {
      throw _RunnerFailure('No buildId in the LambdaTest trigger response: ${response.body}', ExitCode.software.code);
    }
    _logger.info('[trigger] buildId=$buildId');
    return buildId;
  }

  Future<int> _pollUntilTerminal({
    required String buildId,
    required int idleTimeoutSeconds,
    required Set<String> expectedNativeTests,
    required int expectedSessions,
    required Map<String, String> env,
  }) async {
    _logger.info('[poll] waiting for build $buildId to finish');
    final user = env['LT_USERNAME']!;
    final key = env['LT_ACCESS_KEY']!;
    final maxAttempts = maxPollAttempts(
      queueTimeoutSeconds: _queueTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds,
    );
    var loggedStatus = '';

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      String? status;
      try {
        final response = await _http.get(
          'https://mobile-api.lambdatest.com/mobile-automation/api/v1/builds/$buildId',
          headers: _http.basicAuth(user, key),
        );
        status = response.statusCode == 200 ? _statusFromBuild(response.body) : null;
      } catch (_) {
        status = null; // transient network/timeout — keep polling
      }
      // Log only on a status change — the poll runs every few seconds and would
      // otherwise repeat the same line for minutes.
      if ((status ?? '?') != loggedStatus) {
        _logger.info('[poll] status=${status ?? '?'}');
        loggedStatus = status ?? '?';
      }
      if (status != null && LtRunSupport.terminalStatuses.contains(status)) {
        if (_isPass(status)) {
          try {
            await _verifyNativeBuild(buildId, expectedNativeTests, expectedSessions, _http.basicAuth(user, key));
          } catch (error) {
            final reason = error is _NativeEvidenceFailure ? error.safeReason : '${error.runtimeType}';
            _logger.err('LambdaTest iOS run $buildId is not verified: $reason');
            await getDep<LtDiagnostics>().report(buildId: buildId, platform: 'iOS', env: env);
            return ExitCode.unavailable.code;
          }
          _logger.success('LambdaTest iOS run $buildId passed (status: $status).');
          return ExitCode.success.code;
        }
        _logger.err('LambdaTest iOS run $buildId did not pass (status: $status).');
        await getDep<LtDiagnostics>().report(buildId: buildId, platform: 'iOS', env: env);
        return ExitCode.software.code;
      }
      await Future<void>.delayed(pollDelay);
    }

    _logger.err(
      'LambdaTest iOS run $buildId did not reach a terminal status '
      'after $maxAttempts polls.',
    );
    await getDep<LtDiagnostics>().report(buildId: buildId, platform: 'iOS', env: env);
    return ExitCode.unavailable.code;
  }

  bool _isPass(String status) => status == 'passed' || status == 'completed';

  Future<String> _nativeEvidenceGet(String suffix, Map<String, String> headers) async {
    final response = await _http.get(
      'https://mobile-api.lambdatest.com/mobile-automation/api/v1/$suffix',
      headers: headers,
      timeout: const Duration(seconds: 30),
    );
    if (response.statusCode != 200) {
      throw _NativeEvidenceFailure(
        'Native evidence GET failed',
        httpStatus: response.statusCode,
      );
    }
    return response.body;
  }

  Future<void> _verifyNativeBuild(
      String buildId, Set<String> selected, int expectedSessions, Map<String, String> headers) async {
    if (selected.isEmpty) {
      throw const _NativeEvidenceFailure('Selected XCTest identities are unavailable');
    }
    final body = await _nativeEvidenceGet('sessions?build_id=${Uri.encodeQueryComponent(buildId)}', headers);
    final response = jsonDecode(body);
    final sessions = response is Map ? response['data'] : null;
    if (sessions is! List || sessions.length != expectedSessions || sessions.isEmpty) {
      throw const _NativeEvidenceFailure('Current build native session inventory is incomplete');
    }
    _validateNativeSessionMetadata(response, sessions.length);
    final seen = <String>{};
    for (final session in sessions) {
      final id = _nativeSessionId(session, buildId);
      if (!seen.add(id)) {
        throw const _NativeEvidenceFailure('Duplicate native session identity');
      }
      final log = await _nativeEvidenceGet('sessions/${Uri.encodeComponent(id)}/log/instrumentation', headers);
      final failure = _xctestEvidenceFailure(log, selected);
      if (failure != null) {
        throw _NativeEvidenceFailure(failure);
      }
    }
  }

  void _validateNativeSessionMetadata(Map response, int count) {
    final metadata = response['metadata'];
    if (metadata != null &&
        (metadata is! Map ||
            metadata['hasmore'] == true ||
            (metadata.containsKey('total') && metadata['total'] != count))) {
      throw const _NativeEvidenceFailure('Native session pagination is incomplete or malformed');
    }
  }

  String _nativeSessionId(dynamic session, String buildId) {
    if (session is! Map || session['session_id'] is! String || (session['session_id'] as String).isEmpty) {
      throw const _NativeEvidenceFailure('Native session identity is missing');
    }
    if (session.containsKey('build_id')) {
      final actual = _canonicalBuildId(session['build_id']);
      final expected = _canonicalBuildId(buildId);
      if (actual == null || expected == null || actual != expected) {
        throw const _NativeEvidenceFailure('Native session belongs to another build');
      }
    }
    if (!_isPass(session['status_ind']?.toString().toLowerCase() ?? '')) {
      throw const _NativeEvidenceFailure('Native session did not finish successfully');
    }
    return session['session_id'] as String;
  }

  String? _canonicalBuildId(Object? value) {
    if (value is int) {
      return value > 0 ? '$value' : null;
    }
    if (value is! String || !RegExp(r'^[0-9]+$').hasMatch(value)) {
      return null;
    }
    final digits = value.replaceFirst(RegExp('^0+'), '');
    return digits.isEmpty ? null : digits;
  }

  String? _xctestEvidenceFailure(String log, Set<String> selected) {
    final ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))');
    final normalized = log.replaceAll(ansi, '');
    if (patrolSkipSummary(normalized).hasSkippedTests) {
      return 'runtime skipped tests are not passes';
    }
    final events = <String, List<String>>{};
    final cases = <String>[];
    final barrier = RegExp('^XCTestOutputBarrier(?=Test (?:Case|Suite) )');
    final lines = normalized.split('\n').map((line) => line.trim().replaceFirst(barrier, '')).toList();
    final pattern = RegExp(
      r"^Test Case '-\[(?:RunnerUITests\.)?(\w+) (\w+)\]' "
      r'(started|passed|failed|skipped)(?: \([\d.]+ seconds\))?\.?$',
    );
    for (final line in lines.where((line) => line.startsWith('Test Case '))) {
      final match = pattern.firstMatch(line);
      if (match == null || !selected.contains('${match[1]}/${match[2]}')) {
        return 'native XCTest identity is malformed or not selected';
      }
      events.putIfAbsent('${match[1]}/${match[2]}', () => []).add(match[3]!);
      cases.add(line.replaceFirst('RunnerUITests.', ''));
    }
    if (events.length != selected.length || !events.keys.toSet().containsAll(selected)) {
      return 'native XCTest results do not exhaust selected identities';
    }
    if (events.values.any((statuses) => !_completeXCTestCase(statuses))) {
      return 'native XCTest skipped, failed, duplicated or did not finish';
    }
    final outcomes = parseLtTestOutcomes(cases.join('\n'));
    if (outcomes.length != selected.length || outcomes.any((outcome) => !outcome.passed)) {
      return 'native XCTest terminal pass evidence is incomplete';
    }
    return _xctestCompletionFailure(lines, selected);
  }

  bool _completeXCTestCase(List<String> statuses) =>
      (statuses.length == 1 && statuses.single == 'passed') ||
      (statuses.length == 2 && statuses.first == 'started' && statuses.last == 'passed');

  String? _xctestCompletionFailure(List<String> lines, Set<String> selected) {
    final classes = selected.map((identity) => identity.split('/').first).toSet();
    if (classes.length != 1) {
      return 'Native XCTest completion requires one selected suite';
    }
    final suite = RegExp(
      "^Test Suite '(?:RunnerUITests\\.)?${RegExp.escape(classes.single)}' "
      r'(passed|failed|skipped) at .+$',
    );
    final completions = [
      for (var index = 0; index < lines.length; index++)
        if (suite.hasMatch(lines[index])) index,
    ];
    if (completions.length != 1 || suite.firstMatch(lines[completions.single])![1] != 'passed') {
      return 'native XCTest suite completion is missing or contradictory';
    }
    final end = completions.single;
    if (lines.skip(end + 1).any((line) => line.startsWith('Test Case '))) {
      return 'native XCTest continued after suite completion';
    }
    final counts = RegExp(r'^Executed ([1-9]\d*) tests?, with 0 failures? \(0 unexpected\)');
    final summary = lines.skip(end + 1).where((line) => line.isNotEmpty).firstOrNull;
    final match = summary == null ? null : counts.firstMatch(summary);
    return match != null && int.parse(match[1]!) == selected.length
        ? null
        : 'native XCTest completion counts are missing or incomplete';
  }

  String? _statusFromBuild(String responseBody) {
    final data = tryDecodeObject(responseBody)?['data'];
    if (data is! Map<String, dynamic>) {
      return null;
    }
    final status = data['status_ind'];
    return status is String && status.isNotEmpty ? status.toLowerCase() : null;
  }

  String _firstBuildId(dynamic raw) {
    if (raw is List) {
      return raw.isEmpty ? '' : raw.first.toString();
    }
    if (raw == null) {
      return '';
    }
    return raw.toString();
  }

  /// A JSON object from [body], or a [_RunnerFailure] when the response is not a
  /// JSON map (so callers fail fast with [context] in the message).
  Map<String, dynamic> _decodeJson(String body, {required String context}) {
    final decoded = tryDecodeObject(body);
    if (decoded != null) {
      return decoded;
    }
    throw _RunnerFailure('$context returned a non-JSON response: $body', ExitCode.software.code);
  }
}

/// Internal control-flow exception so each step can fail with a message + exit
/// code and [LtIosRunner.run] can convert it to a single logged return value.
class _RunnerFailure implements Exception {
  _RunnerFailure(this.message, this.exitCode);

  final String message;
  final int exitCode;
}

/// Carries only locally controlled reasons, never provider bodies or URLs.
class _NativeEvidenceFailure implements Exception {
  const _NativeEvidenceFailure(this.reason, {this.httpStatus});

  final String reason;
  final int? httpStatus;

  String get safeReason => httpStatus == null ? reason : '$reason (HTTP $httpStatus)';
}
