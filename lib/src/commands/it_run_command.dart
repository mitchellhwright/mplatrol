import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/e2e_credentials_server.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:mplatrol/src/it_target_selector.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/lt_hyperexecute_runner.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/prepare_hook.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:path/path.dart' as p;

/// `mplatrol run <variant>` runs the project's prepare hook, then the app's Patrol suite on one of the four
/// variants. `mplatrol run all` coordinates all four variants.
class ItRunCommand extends BaseCommand {
  ItRunCommand() {
    argParser
      ..addOption(
        'tenant',
        valueHelp: 'tenant[,tenant2]',
        help: 'The tenant (white-label flavor) to prepare and run against; comma-separated for several '
            '(default: tenant in mplatrol.yaml, else "default").',
      )
      ..addOption(
        'environment',
        abbr: 'e',
        valueHelp: 'staging',
        help: 'The backend environment the tests run against (default: '
            'MPLATROL_E2E_ENVIRONMENT/E2E_ENVIRONMENT, then environment in '
            'mplatrol.yaml, else staging).',
      )
      ..addOption(
        'device',
        abbr: 'd',
        valueHelp: 'id',
        help: 'Device to target. Local variants use a device/simulator id; '
            'LambdaTest variants use one or more comma-separated LT device '
            'specs ("Name-OSVersion"), each run as its own HyperExecute job '
            '(default: the best local spec device, or the configured LambdaTest devices).',
      )
      ..addFlag(
        'reuse-last',
        negatable: false,
        help: 'Reuse supported cached artifacts for unchanged '
            'tenant/environment/target inputs, skipping prepare/build/upload '
            'where safe. Run once normally to populate it.',
      )
      ..addFlag(
        'develop',
        negatable: false,
        help: 'Iterate on one test: run `patrol develop` for --target on a local '
            'android/ios device, attached to this terminal. After the first '
            'build, edit the test and press R to hot-restart it in seconds.',
      )
      ..addOption(
        'target',
        valueHelp: 'patrol_test/foo_test.dart',
        help: 'Run a SINGLE patrol test file (for debugging one scenario). '
            'Omitted (default): run the whole Patrol test suite — every '
            'test in one build, each as its own orchestrated process.',
      )
      ..addOption(
        'target-regex',
        valueHelp: 'regex',
        help: 'Filter Patrol tests by file path/name or patrolTest description. '
            'File matches keep every test in that file; description matches '
            'keep only matching tests.',
      )
      ..addOption(
        'sdk',
        valueHelp: 'sdkName',
        help: 'Run Patrol tests for an SDK by matching the SDK name as tokens '
            'in test file names or patrolTest descriptions (for example, '
            '--sdk=payments matches payments_sdk_smoke_test.dart).',
      )
      ..addFlag(
        'coverage',
        negatable: false,
        help: 'Collect E2E (journey) line coverage from the local android or ios run through Patrol (debug build, '
            'Dart VM service): lcov at <app>/.mplatrol/reports/coverage/lcov-<tenant>-<variant>-<timestamp>.info, '
            'filtered to app code, with the totals in summary.json and the console. Not available on LambdaTest.',
      )
      ..addOption(
        'ci-report',
        allowed: const [ciReportTeamCity],
        valueHelp: ciReportTeamCity,
        help: 'Also print per-test results and run statistics as TeamCity '
            'service messages (on automatically when TEAMCITY_VERSION is set).',
      )
      ..addOption(
        'junit',
        valueHelp: 'path',
        help: 'Write the per-test JUnit XML report to this path (default: '
            '<app>/.mplatrol/reports/junit-<tenant>-<variant>-<timestamp>.xml).',
      )
      ..addOption(
        'order',
        allowed: const [testOrderRandom, testOrderDeclared],
        defaultsTo: testOrderRandom,
        help: 'Test order: random (a seeded shuffle, so tests sharing test users and server state '
            'collide differently every run) or declared (discovery order, to debug an order-specific failure).',
      )
      ..addOption(
        'seed',
        valueHelp: 'n',
        help: 'Reproduce the test order of an earlier run (printed as "[order] seed=<n>", and in '
            'summary.json and the JUnit report). Default: a fresh random seed per run.',
      );
  }

  MplatrolConfig get config => getDep<MplatrolConfig>();

  @override
  String get name => 'run';

  @override
  String get description => 'Run the app Patrol E2E suite on a variant '
      '(${ItVariant.runIds.join(', ')}). Pass the variant '
      'from the command line.';

  @override
  String get invocation => 'mplatrol run [${ItVariant.runIds.join('|')}]';

  void _validateDevelopInput(List<String> rest) {
    final variant = rest.isEmpty ? null : ItVariant.fromId(rest.first);
    if (variant != ItVariant.androidLocal && variant != ItVariant.iosLocal) {
      usageException('--develop runs on one local device: pass the android or ios variant.');
    }
    if ((argResults['target'] as String?)?.trim().isEmpty ?? true) {
      usageException('--develop needs --target=patrol_test/<file>_test.dart (one test file).');
    }
    for (final conflicting in const ['reuse-last', 'target-regex', 'sdk']) {
      if (argResults.wasParsed(conflicting)) {
        usageException('--develop cannot be combined with --$conflicting.');
      }
    }
  }

  static const _coverageNotOnLambdaTest = '--coverage works on the local android and ios variants only. Patrol '
      'collects coverage from the Dart VM service of a debug build, over a local adb or simulator connection to this '
      'machine; LambdaTest runs a prebuilt app on a remote device with no such connection. Run `mplatrol run '
      'android --coverage` or `mplatrol run ios --coverage`.';

  void _validateCoverageInput(List<String> rest) {
    if (!(argResults['coverage'] as bool)) {
      return;
    }
    if (argResults['develop'] as bool) {
      usageException('--coverage cannot be combined with --develop.');
    }
    const lambdaTestTokens = [ItVariant.allId, ItVariant.ltAllId, 'lt-android', 'lt-ios'];
    if (rest.length == 1 && lambdaTestTokens.contains(rest.first)) {
      usageException(_coverageNotOnLambdaTest);
    }
  }

  @override
  void validateInput() {
    final rest = argResults.rest;
    if (rest.isEmpty) {
      usageException('Pass a variant: ${ItVariant.runIds.join(', ')}.');
    }
    if (rest.length > 1) {
      usageException('Pass at most one variant: ${ItVariant.runIds.join(', ')}.');
    }
    if (rest.length == 1 && !ItVariant.runIds.contains(rest.first)) {
      usageException('Unknown variant "${rest.first}". Expected one of: ${ItVariant.runIds.join(', ')}.');
    }
    if (rest.length == 1 &&
        (rest.first == ItVariant.allId || rest.first == ItVariant.ltAllId) &&
        argResults['device'] != null) {
      usageException('--device can only target one variant. Omit --device for ${rest.first}, or run a single variant.');
    }
    if (rest.length == 1 && ItVariant.autoIds.contains(rest.first) && argResults['device'] != null) {
      usageException('--device already picks the target. Omit --device for ${rest.first}, or run android, ios, '
          'lt-android or lt-ios.');
    }
    if (argResults['develop'] as bool) {
      _validateDevelopInput(rest);
    }
    _validateCoverageInput(rest);
    final targetRegex = (argResults['target-regex'] as String?)?.trim();
    if (targetRegex != null) {
      if (targetRegex.isEmpty) {
        usageException('--target-regex cannot be empty.');
      }
      try {
        RegExp(targetRegex);
      } on FormatException catch (error) {
        usageException('Invalid --target-regex "$targetRegex": ${error.message}');
      }
    }
    final sdk = (argResults['sdk'] as String?)?.trim();
    if (sdk != null && sdk.isEmpty) {
      usageException('--sdk cannot be empty.');
    }
    try {
      _testOrder();
    } on FormatException catch (error) {
      usageException(error.message);
    }
  }

  /// Runs the tests; on SIGTERM or SIGINT it stops them and still reports (see [ItRunStop]), ending with
  /// the signal's exit code.
  @override
  Future<int> runCommand() async {
    final stop = getDep<ItRunStop>()..watch();
    try {
      final code = await _run();
      return stop.isStopping ? stop.exitCode : code;
    } finally {
      await getDep<LocalDeviceLeases>().releaseAll();
      await stop.close();
    }
  }

  Future<int> _run() async {
    final repo = fileSystem.getAppDirectory(throwIfNotFound: false).path;
    final order = _testOrder();
    getDep<ItTestOrder>().order = order;
    logger.info(order.banner);
    await _warnIfLowDisk(repo);
    final baseEnv = <String, String>{...platformWrapper.environment};
    final startedAt = DateTime.now();
    final ciReport = ItCiReportOptions(
      repo: repo,
      startedAt: startedAt,
      ciReport: argResults['ci-report'] as String?,
      junitPath: _resolveTrimmedOption('junit'),
    );
    final variants = await _resolveVariants(baseEnv);
    if (variants == null) {
      return ExitCode.unavailable.code;
    }
    final tenants = _resolveTenants();
    final environment = _resolveEnvironment();
    final target = argResults['target'] as String?;
    final targetRegex = _resolveTrimmedOption('target-regex');
    final sdk = _resolveTrimmedOption('sdk');
    final runs = <_ResolvedRun>[];
    for (final variant in variants) {
      switch (variant) {
        case ItVariant.androidLocal:
        case ItVariant.iosLocal:
          await getDep<LocalDeviceLeases>().hold(variant == ItVariant.iosLocal ? 'ios' : 'android',
              label: 'mplatrol run ${variant.id}', device: argResults['device'] as String?);
          final localDeviceId = await _resolveDevice(variant);
          if (localDeviceId == null) {
            logger.err(
              'No local ${variant == ItVariant.iosLocal ? 'iOS device or simulator' : 'Android device'} '
              'found. Boot one (see `mplatrol devices`) or pass --device.',
            );
            return ExitCode.unavailable.code;
          }
          runs.add(_ResolvedRun.local(variant: variant, deviceId: localDeviceId));
        case ItVariant.ltAndroid:
        case ItVariant.ltIos:
          final ltDevices = _resolveLtDevices(variant);
          if (ltDevices.isEmpty) {
            logger.err(
              'No LambdaTest ${variant == ItVariant.ltIos ? 'iOS' : 'Android'} '
              'devices configured. Add one to mplatrol.yaml or pass --device.',
            );
            return ExitCode.usage.code;
          }
          runs.add(_ResolvedRun.lt(variant: variant, devices: ltDevices));
      }
    }
    if ((argResults['coverage'] as bool) && runs.any((run) => run.isLt)) {
      logger.err(_coverageNotOnLambdaTest);
      return ExitCode.usage.code;
    }
    // One tenant on LambdaTest only can free the checkout once uploaded; several
    // tenants or a local variant still need it.
    getDep<ItLegDir>().expectedUploads = tenants.length == 1 && runs.every((run) => run.isLt) ? runs.length : 0;
    var firstFailure = ExitCode.success.code;
    final stop = getDep<ItRunStop>();
    for (final tenant in tenants) {
      final code = stop.isStopping
          ? stop.exitCode
          : await getDep<ItRunResults>().withTenant(
              tenant,
              environment,
              () => _runForTenant(
                    tenant: tenant,
                    runs: runs,
                    target: target,
                    targetRegex: targetRegex,
                    sdk: sdk,
                    environment: environment,
                    baseEnv: baseEnv,
                    ciReport: ciReport,
                  ));
      if (code != ExitCode.success.code && firstFailure == ExitCode.success.code) {
        firstFailure = code;
      }
      if (code != ExitCode.success.code) {
        logger.err('tenant $tenant failed with exit $code; rerun the same test order with ${order.reproduce}.');
      }
      await _publishCiReport(() {
        for (final run in runs) {
          getDep<ItRunResults>().endUnstarted(
              ItRunLeg(tenant: tenant, environment: environment, variant: run.variant.id, order: order),
              exitCode: code,
              planned: () => plannedPatrolTests(ciReport.repo, target: target, targetRegex: targetRegex, sdk: sdk));
        }
      });
    }
    await _publishCiReport(() => getDep<ItCiReporter>().finish(ciReport));
    final leg = getDep<ItLegDir>();
    await getDep<DiskJanitor>().afterRun(checkout: repo, legDir: leg.path, checkoutReleased: leg.released);
    return firstFailure;
  }

  /// The `--order`/`--seed` test order; a fresh seed for every call without
  /// `--seed`, so resolve it once per run. Throws [FormatException] for a bad seed.
  TestOrder _testOrder() => TestOrder.parse(order: argResults['order'] as String?, seed: argResults['seed'] as String?);

  /// Warns before anything builds when the disk is nearly full (see [DiskSpace.lowDiskWarning]).
  Future<void> _warnIfLowDisk(String repo) async {
    final warning = await getDep<DiskSpace>().lowDiskWarning(repo.isEmpty ? p.current : repo);
    if (warning != null) {
      logger.warn(warning);
    }
  }

  /// Runs one CI report step; a reporting failure is a warning and never
  /// changes the run's verdicts or exit code.
  Future<void> _publishCiReport(FutureOr<void> Function() step) async {
    try {
      await step();
    } catch (error) {
      logger.warn('[ci-report] could not publish CI results (${error.runtimeType}: $error); '
          'the run verdict is unchanged.');
    }
  }

  Future<int> _runForTenant({
    required String tenant,
    required List<_ResolvedRun> runs,
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required String environment,
    required Map<String, String> baseEnv,
    required ItCiReportOptions ciReport,
  }) async {
    final repo = fileSystem.getAppDirectory(throwIfNotFound: false);
    var runEnv = {...baseEnv, e2eEnvironmentEnv: environment, e2eTenantEnv: tenant};
    logger.info(
      'Running ${tenant.trim().isEmpty ? '' : '[tenant:$tenant] '}'
      '${runs.length == 1 ? runs.single.variant.label : 'all ${runs.length} variants'} '
      '(env: $environment)',
    );

    // The prepare hook (idempotent). --reuse-last re-triggers already-built artifacts. Skip prepare only when
    // every selected variant has a safe reuse path; otherwise prepare and let unsupported local variants build
    // from the current tree.
    final reuseLast = argResults['reuse-last'] as bool;
    final inputsRevision = (runEnv[ltInputsRevisionEnv] ?? '').trim();
    final localReuseDecisions = reuseLast
        ? _localReuseDecisions(
            repo: repo.path,
            runs: runs,
            tenant: tenant,
            environment: environment,
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            androidTestTimeoutMs: resolveAndroidTestTimeoutMs(runEnv),
            inputsRevision: inputsRevision,
            explicit: true,
          )
        : _localReuseDecisions(
            repo: repo.path,
            runs: runs,
            tenant: tenant,
            environment: environment,
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            androidTestTimeoutMs: resolveAndroidTestTimeoutMs(runEnv),
            inputsRevision: inputsRevision,
          );
    final localReuseLast = {
      for (final run in runs.where((run) => !run.isLt))
        run.variant: localReuseDecisions[run.variant]?.reuseLast ?? false,
    };
    final skipPrepare = runs.every((run) {
      if (run.isLt) {
        return reuseLast;
      }
      return localReuseLast[run.variant] ?? false;
    });
    if (skipPrepare) {
      logger.info(
        '[reuse-last] skipping prepare for "$tenant" — reusing the '
        'previously built app.',
      );
    } else {
      if (reuseLast) {
        _logRejectedLocalReuseDecisions(localReuseDecisions);
        logger.warn(
          '--reuse-last applies to LT and matching local iOS/Android '
          'builds; '
          'preparing anyway because at least one selected run cannot reuse.',
        );
      }
      final prepCode = await getDep<PrepareHook>().run(
        repo: repo.path,
        tenant: tenant,
        environment: environment,
        platforms: {for (final run in runs) run.isAndroid ? 'android' : 'ios'},
      );
      if (prepCode != ExitCode.success.code) {
        logger.err('Prepare failed for "$tenant" (exit $prepCode); not running the test.');
        return prepCode;
      }
    }

    final credentialsServer = await getDep<E2eCredentialsServer>().start(
      repo: repo.path,
      env: runEnv,
      tenant: tenant,
      environment: environment,
      userType: runEnv[e2eUserTypeEnv],
      reuseLast: reuseLast,
    );
    if (credentialsServer == null) {
      logger.warn('[e2e-creds] the credential provider has no login for $tenant/$environment; tests that sign '
          'in will fail or skip. See "Credentials" in the README.');
      runEnv = {...runEnv, e2eSkipHappyLoginTestEnv: 'true'};
    }
    try {
      final ltEnv = runs.any((run) => run.isLt) ? _ltEnv(runEnv) : null;
      if (runs.length == 1) {
        final code = await _runResolved(
          runs.single,
          target,
          targetRegex: targetRegex,
          sdk: sdk,
          tenant: tenant,
          environment: environment,
          baseEnv: runEnv,
          reuseLast: reuseLast,
          localReuseLast: localReuseLast,
          ltEnv: ltEnv,
          credentialsServer: credentialsServer,
          report: (inputsRevision: inputsRevision, options: ciReport),
        );
        return code;
      }
      final results = await _runResolvedGroups(
        runs,
        target,
        targetRegex: targetRegex,
        sdk: sdk,
        tenant: tenant,
        environment: environment,
        baseEnv: runEnv,
        reuseLast: reuseLast,
        localReuseLast: localReuseLast,
        ltEnv: ltEnv,
        credentialsServer: credentialsServer,
        report: (inputsRevision: inputsRevision, options: ciReport),
      );
      final failures = results.where((result) => result.code != 0).toList();
      if (failures.isEmpty) {
        return ExitCode.success.code;
      }
      for (final failure in failures) {
        logger.err(
          '${failure.variant.label} failed with exit '
          '${failure.code} for tenant "$tenant".',
        );
      }
      return failures.first.code;
    } finally {
      await credentialsServer?.close();
    }
  }

  Future<List<({ItVariant variant, int code})>> _runResolvedGroups(
    List<_ResolvedRun> runs,
    String? target, {
    required String? targetRegex,
    required String? sdk,
    required String tenant,
    required String environment,
    required Map<String, String> baseEnv,
    required bool reuseLast,
    required Map<ItVariant, bool> localReuseLast,
    required Future<Map<String, String>>? ltEnv,
    required E2eCredentialsServerHandle? credentialsServer,
    required _LegReport report,
  }) async {
    Future<int> runOne(_ResolvedRun run) => _runResolved(
          run,
          target,
          targetRegex: targetRegex,
          sdk: sdk,
          tenant: tenant,
          environment: environment,
          baseEnv: baseEnv,
          reuseLast: reuseLast,
          localReuseLast: localReuseLast,
          ltEnv: ltEnv,
          credentialsServer: credentialsServer,
          report: report,
        );

    // Variants that share a platform (e.g. local Android and LambdaTest
    // Android) mutate the same generated files in the one working tree — the
    // native Patrol runner, the filtered test bundle, and the build outputs —
    // so they must run sequentially. The two platform groups run concurrently
    // but are NOT independent: both build from the one the app
    // patrol_test/ directory. Android owns Patrol's shared test_bundle.dart and
    // mplatrol_filtered_test.dart wrapper; every iOS variant compiles its own
    // mplatrol_ios_test_bundle.dart and must never write, delete, or compile the
    // Android files (see iosPatrolTestBundleFile).
    final platformGroups = <bool, List<_ResolvedRun>>{};
    for (final run in runs) {
      platformGroups.putIfAbsent(run.isAndroid, () => []).add(run);
    }

    final grouped = await Future.wait(
      platformGroups.values.map((group) async {
        final results = <ItVariant, int>{};
        for (final run in group) {
          results[run.variant] = await runOne(run);
        }
        return results;
      }),
    );

    final codes = {for (final result in grouped) ...result};
    return [
      for (final run in runs) (variant: run.variant, code: codes[run.variant]!),
    ];
  }

  /// Runs one variant as a CI report leg and reports its per-test results.
  Future<int> _runResolved(
    _ResolvedRun run,
    String? target, {
    required String? targetRegex,
    required String? sdk,
    required String tenant,
    required String environment,
    required Map<String, String> baseEnv,
    required bool reuseLast,
    required Map<ItVariant, bool> localReuseLast,
    required Future<Map<String, String>>? ltEnv,
    required E2eCredentialsServerHandle? credentialsServer,
    required _LegReport report,
  }) async {
    final leg =
        ItRunLeg(tenant: tenant, environment: environment, variant: run.variant.id, order: getDep<ItTestOrder>().order);
    final code = await getDep<ItRunResults>().withLeg(
      leg,
      device: run.localDeviceId,
      () => _runVariant(run, target,
          targetRegex: targetRegex,
          sdk: sdk,
          tenant: tenant,
          environment: environment,
          baseEnv: baseEnv,
          reuseLast: reuseLast,
          localReuseLast: localReuseLast,
          ltEnv: ltEnv,
          credentialsServer: credentialsServer,
          inputsRevision: report.inputsRevision),
    );
    final stop = getDep<ItRunStop>();
    await _publishCiReport(() {
      getDep<ItRunResults>().endLeg(leg,
          exitCode: stop.isStopping ? stop.exitCode : code,
          planned: () => plannedPatrolTests(report.options.repo, target: target, targetRegex: targetRegex, sdk: sdk));
      getDep<ItCiReporter>().reportLeg(leg, report.options);
    });
    return code;
  }

  Future<int> _runVariant(
    _ResolvedRun run,
    String? target, {
    required String? targetRegex,
    required String? sdk,
    required String tenant,
    required String environment,
    required Map<String, String> baseEnv,
    required bool reuseLast,
    required Map<ItVariant, bool> localReuseLast,
    required Future<Map<String, String>>? ltEnv,
    required E2eCredentialsServerHandle? credentialsServer,
    required String inputsRevision,
  }) async {
    switch (run.variant) {
      case ItVariant.androidLocal:
      case ItVariant.iosLocal:
        final env = credentialsServer == null ? baseEnv : credentialsServer.envFor(run.variant, baseEnv);
        final shouldReuseLast = localReuseLast[run.variant] ?? reuseLast;
        if (shouldReuseLast) {
          getDep<ItRunResults>().buildReused();
        }
        final repo = fileSystem.getAppDirectory(throwIfNotFound: false).path;
        final request = LocalReuseRequest(
          variant: run.variant,
          deviceId: run.localDeviceId!,
          tenant: tenant,
          environment: environment,
          target: target,
          targetRegex: targetRegex,
          sdk: sdk,
          androidTestTimeoutMs: resolveAndroidTestTimeoutMs(env),
          inputsRevision: inputsRevision,
          coverage: argResults['coverage'] as bool,
        );
        const metadata = LocalReuseMetadataStore();
        var buildFingerprint = metadata.evaluate(repo: repo, request: request).fingerprint;
        final coverage = argResults['coverage'] as bool;
        final coverageReports = getDep<E2eCoverageReports>();
        final legStartedAt = DateTime.now();
        if (coverage) {
          coverageReports.prepare(repo);
        }
        final code = await _runLocal(
          variant: run.variant,
          deviceId: run.localDeviceId!,
          target: target,
          targetRegex: targetRegex,
          sdk: sdk,
          env: env,
          reuseLast: shouldReuseLast,
          develop: argResults['develop'] as bool,
          coverage: coverage,
          onBuildStarted: () {
            if (!shouldReuseLast) {
              metadata.invalidateForBuild(repo: repo, variant: run.variant);
            }
            buildFingerprint = metadata.evaluate(repo: repo, request: request).fingerprint;
          },
        );
        var legCode = code;
        if (coverage) {
          final lcov = await coverageReports.collect(
              repo: repo, tenant: tenant, variant: run.variant.id, startedAt: legStartedAt);
          if (lcov == null && legCode == ExitCode.success.code) {
            legCode = ExitCode.software.code;
          }
        }
        _recordLocalReuseMetadata(
          code: code,
          repo: repo,
          run: run,
          request: request,
          buildFingerprint: buildFingerprint,
          reuseLast: shouldReuseLast,
        );
        return legCode;
      case ItVariant.ltAndroid:
        final env = _runtimeEnv(run.variant, await ltEnv!, credentialsServer);
        if (targetRegex == null && sdk == null) {
          return getDep<LtHyperexecuteRunner>().runAndroid(
            target: target,
            devices: run.ltDevices!,
            idleTimeoutSeconds: config.it.idleTimeout,
            env: env,
            tenantLabel: tenant,
            environmentLabel: environment,
            reuseLast: reuseLast,
          );
        }
        return getDep<LtHyperexecuteRunner>().runAndroid(
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            devices: run.ltDevices!,
            idleTimeoutSeconds: config.it.idleTimeout,
            env: env,
            tenantLabel: tenant,
            environmentLabel: environment,
            reuseLast: reuseLast);
      case ItVariant.ltIos:
        final env = _runtimeEnv(run.variant, await ltEnv!, credentialsServer);
        if (targetRegex == null && sdk == null) {
          return getDep<LtHyperexecuteRunner>().runIos(
            target: target,
            devices: run.ltDevices!,
            idleTimeoutSeconds: config.it.idleTimeout,
            env: env,
            tenantLabel: tenant,
            environmentLabel: environment,
            reuseLast: reuseLast,
          );
        }
        return getDep<LtHyperexecuteRunner>().runIos(
            target: target,
            targetRegex: targetRegex,
            sdk: sdk,
            devices: run.ltDevices!,
            idleTimeoutSeconds: config.it.idleTimeout,
            env: env,
            tenantLabel: tenant,
            environmentLabel: environment,
            reuseLast: reuseLast);
    }
  }

  Map<ItVariant, LocalReuseDecision> _localReuseDecisions({
    required String repo,
    required List<_ResolvedRun> runs,
    required String tenant,
    required String environment,
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required int androidTestTimeoutMs,
    required String inputsRevision,
    bool explicit = false,
  }) {
    final decisions = <ItVariant, LocalReuseDecision>{};
    const metadata = LocalReuseMetadataStore();
    for (final run in runs.where((run) => !run.isLt)) {
      final request = LocalReuseRequest(
        variant: run.variant,
        deviceId: run.localDeviceId!,
        tenant: tenant,
        environment: environment,
        target: target,
        targetRegex: targetRegex,
        sdk: sdk,
        androidTestTimeoutMs: androidTestTimeoutMs,
        inputsRevision: inputsRevision,
        coverage: argResults['coverage'] as bool,
      );
      final decision = metadata.evaluate(
        repo: repo,
        request: request,
        explicit: explicit,
      );
      decisions[run.variant] = decision;
      if (decision.reuseLast) {
        logger.info(
          '[reuse-last] automatically reusing cached ${run.variant.label} '
          'build for "$tenant" (${decision.reason}).',
        );
      } else if (!explicit) {
        logger.info(
          '[reuse-last] rebuilding ${run.variant.label} for "$tenant": '
          '${decision.reason}.',
        );
      }
    }
    return decisions;
  }

  void _logRejectedLocalReuseDecisions(
    Map<ItVariant, LocalReuseDecision> decisions,
  ) {
    for (final entry in decisions.entries) {
      if (entry.value.reuseLast) {
        continue;
      }
      logger.warn(
        '[reuse-last] ${entry.key.label} cannot reuse the cached local build: '
        '${entry.value.reason}.',
      );
    }
  }

  Future<int> _runLocal({
    required ItVariant variant,
    required String deviceId,
    required String? target,
    required String? targetRegex,
    required String? sdk,
    required Map<String, String> env,
    required bool reuseLast,
    bool develop = false,
    bool coverage = false,
    void Function()? onBuildStarted,
  }) {
    return getDep<LocalRunner>().run(
      variant: variant,
      deviceId: deviceId,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env,
      reuseLast: reuseLast,
      develop: develop,
      coverage: coverage,
      onBuildStarted: onBuildStarted,
    );
  }

  void _recordLocalReuseMetadata({
    required int code,
    required String repo,
    required _ResolvedRun run,
    required LocalReuseRequest request,
    required String buildFingerprint,
    required bool reuseLast,
  }) {
    final completedAndroidBuild =
        run.variant == ItVariant.androidLocal && !reuseLast && getDep<LocalRunner>().androidBuildSucceeded == true;
    final completedIosBuild =
        run.variant == ItVariant.iosLocal && !reuseLast && getDep<LocalRunner>().iosBuildSucceeded == true;
    if (run.isLt || (code != ExitCode.success.code && !completedAndroidBuild && !completedIosBuild)) {
      return;
    }
    const metadata = LocalReuseMetadataStore();
    if (metadata.evaluate(repo: repo, request: request).fingerprint != buildFingerprint) {
      logger.warn('[reuse-last] source/build inputs changed during the local run; '
          'not recording this build for reuse.');
      return;
    }
    if (code != ExitCode.success.code) {
      final artifacts = completedIosBuild ? 'iOS build' : 'Android APKs';
      logger.info('[reuse-last] retaining the built $artifacts after a '
          'failing test run; the next unchanged run can reuse them.');
    }
    metadata.recordSuccessfulRun(
      repo: repo,
      request: request,
    );
  }

  Map<String, String> _runtimeEnv(
    ItVariant variant,
    Map<String, String> env,
    E2eCredentialsServerHandle? credentialsServer,
  ) {
    if (credentialsServer == null) {
      return env;
    }
    return credentialsServer.envFor(variant, env);
  }

  /// The local device/simulator id to target. An explicit `--device` always wins. Otherwise only devices that
  /// meet [LocalDeviceSpec] are considered: with none, returns null (the caller prints the boot hint); with
  /// several, the best-first one (booted, newest runtime, lowest UDID) is used and named. Never prompts.
  Future<String?> _resolveDevice(ItVariant variant) async {
    final explicit = argResults['device'] as String?;
    if (explicit != null) {
      return explicit;
    }
    final isIos = variant == ItVariant.iosLocal;
    final devices = isIos ? await _specIosSimulators() : await _specAndroidEmulators();
    if (devices.isEmpty) {
      return null;
    }
    if (devices.length > 1) {
      logger.info(
        '${devices.length} devices meet the local device spec; using ${devices.first.label} (${devices.first.id}).',
      );
    }
    return devices.first.id;
  }

  /// The booted spec AVD, booting it when no conforming emulator is up. Other emulators and physical
  /// phones are skipped with a warning; a physical phone runs only through `--device`.
  Future<List<LocalDevice>> _specAndroidEmulators() async {
    final picker = getDep<DevicePicker>();
    final scan = await picker.scanAndroidEmulators();
    _warnSkipped(scan.rejected);
    final phones = await picker.localAndroidRealDevices();
    if (phones.isNotEmpty) {
      logger.warn(
        'Skipping connected phone(s) ${phones.map((phone) => phone.label).join(', ')}: local runs use the '
        '${LocalDeviceSpec.androidAvdName} emulator. Pass --device=<id> to run on a phone.',
      );
    }
    if (scan.conforming.isNotEmpty) {
      return scan.conforming;
    }
    logger.info('No ${LocalDeviceSpec.androidAvdName} emulator is booted; starting it.');
    try {
      final serial = await getDep<LocalDeviceService>().bootAndroid();
      if (serial != null) {
        final booted = await picker.localAndroidDevices();
        return [...booted.where((device) => device.id == serial), ...booted.where((device) => device.id != serial)];
      }
    } on LocalDeviceSetupException catch (error) {
      logger.err(error.message);
      return const [];
    }
    logger.err(
      'Could not start ${LocalDeviceSpec.androidAvdName}. Create it with `${LocalDeviceSpec.setupCommand}`, boot it '
      'with `${LocalDeviceSpec.androidBootCommand}` and rerun.',
    );
    return const [];
  }

  /// The spec simulator, best-first (booted first). Other booted simulators and connected iPhones are
  /// skipped with a warning; an iPhone runs only through `--device`.
  Future<List<LocalDevice>> _specIosSimulators() async {
    final picker = getDep<DevicePicker>();
    final scan = await picker.scanIosSimulators();
    _warnSkipped(scan.rejected);
    final phones = await picker.localIosRealDevices();
    if (phones.isNotEmpty) {
      logger.warn(
        'Skipping connected iPhone(s) ${phones.map((phone) => phone.label).join(', ')}: local runs use the '
        '${LocalDeviceSpec.iosDeviceName} simulator. Pass --device=<id> to run on an iPhone.',
      );
    }
    if (scan.conforming.isEmpty) {
      logger.err('No ${LocalDeviceSpec.iosDeviceName} simulator on iOS ${LocalDeviceSpec.iosRuntimeMajor}. '
          'Create it with `${LocalDeviceSpec.setupCommand}` and rerun.');
    }
    return scan.conforming;
  }

  void _warnSkipped(List<String> skipped) {
    for (final reason in skipped) {
      logger.warn('Skipping a device that does not meet the local device spec (${LocalDeviceSpec.summary}): $reason.');
    }
  }

  /// The LambdaTest device specs to run on. An explicit `--device` replaces
  /// the configured list with its comma-separated specs.
  List<String> _resolveLtDevices(ItVariant variant) {
    final explicit = argResults['device'] as String?;
    if (explicit != null) {
      return explicit.split(',').map((device) => device.trim()).where((device) => device.isNotEmpty).toList();
    }
    final devices = variant == ItVariant.ltIos ? config.it.ltIosDevices : config.it.ltAndroidDevices;
    return devices;
  }

  /// LambdaTest env for the runners: the ambient environment (with `LT_USERNAME` and `LT_ACCESS_KEY`) plus
  /// defaults the runners need; an explicit env var still wins over a default (putIfAbsent).
  Future<Map<String, String>> _ltEnv(Map<String, String> ambientEnv) async {
    final env = <String, String>{...ambientEnv};
    final home = platformWrapper.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      env.putIfAbsent('LT_BIN', () => ltTunnelBinaryPath(home));
    }
    final tunnelName = config.it.tunnelName;
    if (tunnelName != null && tunnelName.isNotEmpty) {
      env.putIfAbsent('LT_TUNNEL_NAME', () => tunnelName);
    }
    return env;
  }

  String? _resolveTrimmedOption(String name) {
    final value = (argResults[name] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<List<ItVariant>?> _resolveVariants(Map<String, String> env) async {
    final rest = argResults.rest;
    if (rest.length == 1 && ItVariant.autoIds.contains(rest.first)) {
      return _resolveAutoVariants(rest.first, env);
    }
    if (rest.length == 1) {
      if (rest.first == ItVariant.allId) {
        return ItVariant.values;
      }
      if (rest.first == ItVariant.ltAllId) {
        return [ItVariant.ltAndroid, ItVariant.ltIos];
      }
      return [ItVariant.fromId(rest.first)!];
    }
    return null;
  }

  /// The variants `auto`, `auto-android` or `auto-ios` ([token]) resolve to:
  /// the fastest available target per platform (see [ItTargetSelector]), each
  /// logged with its reason. Null when a platform has no available target.
  Future<List<ItVariant>?> _resolveAutoVariants(String token, Map<String, String> env) async {
    final platforms = switch (token) {
      ItVariant.autoAndroidId => const [AutoPlatform.android],
      ItVariant.autoIosId => const [AutoPlatform.ios],
      _ => AutoPlatform.values,
    };
    final selector = getDep<ItTargetSelector>();
    final repo = fileSystem.getAppDirectory().path;
    final selectedTestFiles = selector.selectedTestFiles(
      repo,
      target: _resolveTrimmedOption('target'),
      targetRegex: _resolveTrimmedOption('target-regex'),
      sdk: _resolveTrimmedOption('sdk'),
    );
    if (selectedTestFiles == null) {
      logger.err('[auto] cannot count the selected Patrol tests: no Patrol test directory at '
          '${patrolTestDirectoryPath(repo)}.');
      return null;
    }
    final choices = await selector.choose(
      platforms: platforms,
      selectedTestFiles: selectedTestFiles,
      lambdaTestAvailable: (env['LT_USERNAME'] ?? '').isNotEmpty && (env['LT_ACCESS_KEY'] ?? '').isNotEmpty,
    );
    for (final choice in choices) {
      final variant = choice.variant;
      if (variant == null) {
        logger.err('[auto] ${choice.platform.name}: ${choice.reason}. Boot a simulator/emulator, connect a '
            'device, or export LambdaTest credentials (LT_USERNAME and LT_ACCESS_KEY).');
        return null;
      }
      logger.info('[auto] ${choice.platform.name} -> ${variant.id}: ${choice.reason}');
    }
    return [for (final choice in choices) choice.variant!];
  }

  /// The `--tenant` values (comma-separated), else the configured tenant.
  List<String> _resolveTenants() {
    final explicit = (argResults['tenant'] as String? ?? '')
        .split(',')
        .map((tenant) => tenant.trim())
        .where((tenant) => tenant.isNotEmpty)
        .toList();
    return explicit.isEmpty ? [config.it.tenant] : explicit;
  }

  /// `--environment`, else [e2eEnvironmentEnv] or `E2E_ENVIRONMENT`, else the configured environment.
  String _resolveEnvironment() {
    final explicit = (argResults['environment'] as String?)?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final env = platformWrapper.environment;
    for (final name in [e2eEnvironmentEnv, 'E2E_ENVIRONMENT']) {
      final value = (env[name] ?? '').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return config.it.environment;
  }
}

class _ResolvedRun {
  const _ResolvedRun.local({required this.variant, required String deviceId})
      : localDeviceId = deviceId,
        ltDevices = null;

  const _ResolvedRun.lt({required this.variant, required List<String> devices})
      : localDeviceId = null,
        ltDevices = devices;

  final ItVariant variant;
  final String? localDeviceId;
  final List<String>? ltDevices;

  bool get isLt => variant == ItVariant.ltAndroid || variant == ItVariant.ltIos;

  bool get isAndroid => variant == ItVariant.androidLocal || variant == ItVariant.ltAndroid;
}

/// The build inputs revision and report options one leg's CI results carry.
typedef _LegReport = ({String inputsRevision, ItCiReportOptions options});
