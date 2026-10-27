import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_device_egress.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/core/terminal_capabilities.dart';
import 'package:mplatrol/src/credentials/credential_provider.dart';
import 'package:mplatrol/src/device_picker.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:mplatrol/src/doctor/doctor_checks.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/e2e_credentials_server.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/ios_device_egress.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:mplatrol/src/it_target_selector.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_biometrics.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/local_device_service.dart';
import 'package:mplatrol/src/local_leg_artifacts.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_capacity_service.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_hyperexecute_runner.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:mplatrol/src/lt_session_artifacts.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:mplatrol/src/prepare_hook.dart';
import 'package:mplatrol/src/results/result_sink.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:path/path.dart' as p;

class MockProcessResult extends Mock implements ProcessResultX {}

class _MockMplatrolShell extends Mock implements MplatrolShell {}

class _MockLocalBiometrics extends Mock implements LocalBiometrics {}

class _MockBiometricResponder extends Mock implements BiometricResponder {}

class _MockLocalDeviceLeases extends Mock implements LocalDeviceLeases {}

class _MockLogger extends Mock implements MplatrolLogger {}

class _MockProgress extends Mock implements Progress {}

class _MockFileSystem extends Mock implements FileSystem {}

class _MockMplatrolConfig extends Mock implements MplatrolConfig {}

class _MockPlatformWrapper extends Mock implements PlatformWrapper {}

class _FakeMplatrolLogger extends Fake implements MplatrolLogger {}

class _MockMplatrolProcess extends Mock implements MplatrolProcess {}

class _MockItOptions extends Mock implements ItOptions {}

class _MockLocalRunner extends Mock implements LocalRunner {}

class _MockLtAndroidRunner extends Mock implements LtAndroidRunner {}

class _MockLtIosRunner extends Mock implements LtIosRunner {}

class _MockLtHyperexecuteRunner extends Mock implements LtHyperexecuteRunner {}

class _MockLtTunnel extends Mock implements LtTunnel {}

class _MockLtHttp extends Mock implements LtHttp {}

class _MockLtDiagnostics extends Mock implements LtDiagnostics {}

class _MockHttpClient extends Mock implements http.Client {}

class _MockIosCodesign extends Mock implements IosCodesign {}

class _MockDevicePicker extends Mock implements DevicePicker {}

class _MockLocalDeviceService extends Mock implements LocalDeviceService {}

class _MockAndroidDeviceEgress extends Mock implements AndroidDeviceEgress {}

class _MockIosDeviceEgress extends Mock implements IosDeviceEgress {}

class _MockE2eCredentialsServer extends Mock implements E2eCredentialsServer {}

class _MockItCiReporter extends Mock implements ItCiReporter {}

class _MockLtSessionArtifacts extends Mock implements LtSessionArtifacts {}

/// Registers mocks (and real logic-only services) for every dependency, so no test touches the network,
/// real devices or real processes.
Future<void> scaffoldMockDependencies() async {
  registerFallbackValue(_FakeMplatrolLogger());
  registerFallbackValue(ItVariant.androidLocal);
  registerFallbackValue(const ItRunLeg(tenant: '', environment: '', variant: ''));
  registerFallbackValue(ItCiReportOptions(repo: '', startedAt: DateTime(2026)));
  registerFallbackValue(<String>[]);
  registerFallbackValue(<String, String>{});
  registerFallbackValue(Duration.zero);
  registerFallbackValue(<String, dynamic>{});
  await GetIt.I.reset();
  _stubShell();
  _stubLogger();
  _stubFileSystem();
  _stubMplatrolConfig();
  _stubPlatformWrapper();
  _stubItComponents();
  if (!GetIt.I.isRegistered<SleepFunction>()) {
    GetIt.I.registerLazySingleton<SleepFunction>(() => (_) async {});
  }
  if (!GetIt.I.isRegistered<ProcessRunFunction>()) {
    // Tests never start real processes.
    GetIt.I.registerLazySingleton<ProcessRunFunction>(
        () => (executable, arguments, {workingDirectory, environment}) async => ProcessResult(0, 0, '', ''));
  }
}

void _stubShell() {
  final shell = _MockMplatrolShell();
  GetIt.I.registerLazySingleton<MplatrolShell>(() => shell);

  final processResult = ProcessResultX.from(ProcessResult(
    0,
    ExitCode.success.code,
    'outText',
    'errText',
  ));

  when(
    () => shell.run(
      any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
      forceVerbose: any(named: 'forceVerbose'),
      quietBuild: any(named: 'quietBuild'),
    ),
  ).thenAnswer((_) async => processResult);
  when(() => shell.whichSync(any())).thenReturn('mock_executable_path');
  when(
    () => shell.runArgs(
      any(),
      any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      silent: any(named: 'silent'),
      forceVerbose: any(named: 'forceVerbose'),
      quietBuild: any(named: 'quietBuild'),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer((_) async => processResult);

  final tunnelProcess = _MockMplatrolProcess();
  when(() => tunnelProcess.output).thenReturn('You can start testing now');
  when(tunnelProcess.kill).thenReturn(null);
  when(
    () => shell.start(any(), any(), workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => tunnelProcess);
  when(
    () => shell.startDetached(any(), any(), workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async {});
}

void _stubLogger() {
  final logger = _MockLogger();
  GetIt.I.registerLazySingleton<MplatrolLogger>(() => logger);
  GetIt.I.registerLazySingleton<TerminalCapabilities>(TerminalCapabilities.new);

  final progress = _MockProgress();
  final progressLogs = <String>[];

  when(() => progress.complete(any())).thenAnswer((invocation) {
    final message = invocation.positionalArguments.elementAt(0) as String?;
    if (message != null) {
      progressLogs.add(message);
    }
  });
  when(() => progress.fail(any())).thenReturn(null);
  when(() => logger.level).thenReturn(Level.info);
  when(() => logger.progress(any())).thenReturn(progress);
  when(() => logger.confirm(any())).thenReturn(false);
}

void _stubFileSystem() {
  final fileSystem = _MockFileSystem();
  final parentDir = Directory.systemTemp.createTempSync();
  final appDir = Directory(p.join(parentDir.path, 'app'))..createSync();
  GetIt.I.registerLazySingleton<FileSystem>(() => fileSystem);
  // Files a check only needs to exist (e.g. the LambdaTest binaries) are present by default.
  when(() => fileSystem.fileExistsSync(any())).thenReturn(true);
  when(() => fileSystem.isExecutableFileSync(any())).thenReturn(true);
  when(
    () => fileSystem.getAppDirectory(
      throwIfNotFound: any(named: 'throwIfNotFound'),
      workingDir: any(named: 'workingDir'),
    ),
  ).thenReturn(appDir);
  when(() => fileSystem.currentDir).thenReturn(Directory('mock_base_dir'));
  when(() => fileSystem.readAsStringSync('pubspec.yaml')).thenReturn('''
environment:
  flutter:
    sdk: flutter
publish_to: none
''');
}

void _stubMplatrolConfig() {
  final config = _MockMplatrolConfig();
  GetIt.I.registerLazySingleton<MplatrolConfig>(() => config);
  final itOptions = _MockItOptions();
  when(() => itOptions.tenant).thenReturn('default');
  when(() => itOptions.tenantConfigured).thenReturn(false);
  when(() => itOptions.target).thenReturn('patrol_test/app_test.dart');
  when(() => itOptions.environment).thenReturn('staging');
  when(() => itOptions.environmentConfigured).thenReturn(false);
  when(() => itOptions.tunnelName).thenReturn(null);
  when(() => itOptions.ltAndroidDevices).thenReturn(['Galaxy S23-13']);
  when(() => itOptions.ltIosDevices).thenReturn(['iPhone 16 Pro-18']);
  when(() => itOptions.idleTimeout).thenReturn(360);
  when(() => itOptions.ltIosMaxParallel).thenReturn(5);
  when(() => itOptions.ltAndroidMaxParallel).thenReturn(10);
  when(() => itOptions.ltRequiredEnv).thenReturn(const []);
  when(() => config.it).thenReturn(itOptions);
  when(() => config.prepareCommand).thenReturn(null);
  when(config.resolvedAppPath).thenReturn(null);
  when(() => config.patchPatrol).thenReturn(false);
  when(() => config.coveragePackages).thenReturn(null);
  when(() => config.lessons).thenReturn(const []);
  when(() => config.network).thenReturn(NetworkOptions({
    'proxied-domains': ['.example.test'],
    'probe-url': 'https://www.example.test/'
  }));
}

void _stubPlatformWrapper() {
  final platformWrapper = _MockPlatformWrapper();
  GetIt.I.registerLazySingleton<PlatformWrapper>(() => platformWrapper);

  when(() => platformWrapper.isMac).thenReturn(true);
  when(() => platformWrapper.isWindows).thenReturn(false);
  when(() => platformWrapper.isLinux).thenReturn(false);
  when(() => platformWrapper.environment).thenReturn({'CODESIGN_TEAM': 'TEAMID1234'});
  when(() => platformWrapper.stdinHasTerminal).thenReturn(false);
  when(() => platformWrapper.stdoutHasTerminal).thenReturn(false);
  when(() => platformWrapper.script).thenReturn(Uri.parse('mock_script'));
  when(platformWrapper.localNetworkHost).thenAnswer((_) async => '192.168.86.249');
}

void _stubItComponents() {
  final localRunner = _MockLocalRunner();
  GetIt.I.registerLazySingleton<LocalRunner>(() => localRunner);
  when(
    () => localRunner.run(
      variant: any(named: 'variant'),
      deviceId: any(named: 'deviceId'),
      target: any(named: 'target'),
      targetRegex: any(named: 'targetRegex'),
      sdk: any(named: 'sdk'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
      onBuildStarted: any(named: 'onBuildStarted'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);

  final ltAndroidRunner = _MockLtAndroidRunner();
  GetIt.I.registerLazySingleton<LtAndroidRunner>(() => ltAndroidRunner);
  when(
    () => ltAndroidRunner.run(
      target: any(named: 'target'),
      devices: any(named: 'devices'),
      idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
      env: any(named: 'env'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);
  when(
    () => ltAndroidRunner.buildAndroid(
      repo: any(named: 'repo'),
      target: any(named: 'target'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);
  when(
    () => ltAndroidRunner.buildUploadAndroid(
      repo: any(named: 'repo'),
      tenant: any(named: 'tenant'),
      target: any(named: 'target'),
      buildName: any(named: 'buildName'),
      auth: any(named: 'auth'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
      cachePath: any(named: 'cachePath'),
    ),
  ).thenAnswer((_) async => AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST'));

  final ltIosRunner = _MockLtIosRunner();
  GetIt.I.registerLazySingleton<LtIosRunner>(() => ltIosRunner);
  when(
    () => ltIosRunner.run(
      target: any(named: 'target'),
      devices: any(named: 'devices'),
      idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);
  when(() => ltIosRunner.buildIosConfigOnly(target: any(named: 'target'))).thenAnswer((_) async => 'com.example.app');
  when(
    () => ltIosRunner.buildIosForTesting(bundleId: any(named: 'bundleId')),
  ).thenAnswer((_) async => ExitCode.success.code);
  when(
    () => ltIosRunner.buildIosForHyperexecute(
      target: any(named: 'target'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
      shards: any(named: 'shards'),
      selection: any(named: 'selection'),
      selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
    ),
  ).thenAnswer(
    (_) async => IosHyperexecuteArtifacts(
      appPath: '/tmp/Runner.ipa',
      testSuitePath: '/tmp/RunnerUITests-Runner.ipa',
      appId: 'lt://APPIOS',
      testSuiteAppId: 'lt://TESTIOS',
      productsDir: '/tmp',
    ),
  );

  final ltHyperexecuteRunner = _MockLtHyperexecuteRunner();
  GetIt.I.registerLazySingleton<LtHyperexecuteRunner>(() => ltHyperexecuteRunner);
  when(
    () => ltHyperexecuteRunner.runAndroid(
      target: any(named: 'target'),
      devices: any(named: 'devices'),
      idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
      env: any(named: 'env'),
      tenantLabel: any(named: 'tenantLabel'),
      environmentLabel: any(named: 'environmentLabel'),
      reuseLast: any(named: 'reuseLast'),
      targetRegex: any(named: 'targetRegex'),
      sdk: any(named: 'sdk'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);
  when(
    () => ltHyperexecuteRunner.runIos(
      target: any(named: 'target'),
      devices: any(named: 'devices'),
      idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
      env: any(named: 'env'),
      tenantLabel: any(named: 'tenantLabel'),
      environmentLabel: any(named: 'environmentLabel'),
      reuseLast: any(named: 'reuseLast'),
      targetRegex: any(named: 'targetRegex'),
      sdk: any(named: 'sdk'),
    ),
  ).thenAnswer((_) async => ExitCode.success.code);

  // The shared tunnel helper: ready by default with an auto-assigned name and a
  // process whose kill() the runners call on every exit path. Runner tests that
  // assert on the tunnel override start() with their own process handle.
  final ltTunnel = _MockLtTunnel();
  GetIt.I.registerLazySingleton<LtTunnel>(() => ltTunnel);
  final tunnelProcess = _MockMplatrolProcess();
  when(() => tunnelProcess.output).thenReturn('You can start testing now');
  when(tunnelProcess.kill).thenReturn(null);
  when(
    () => ltTunnel.start(
      ltBin: any(named: 'ltBin'),
      ltUser: any(named: 'ltUser'),
      ltKey: any(named: 'ltKey'),
      tunnelName: any(named: 'tunnelName'),
    ),
  ).thenAnswer((_) async => (process: tunnelProcess, ready: true, name: 'lt-tunnel'));

  // The HTTP layer for the LT runners. http.Client is registered for
  // completeness; the runner tests drive LtHttp directly with canned responses.
  GetIt.I.registerLazySingleton<http.Client>(_MockHttpClient.new);
  final ltHttp = _MockLtHttp();
  GetIt.I.registerLazySingleton<LtHttp>(() => ltHttp);
  when(() => ltHttp.basicAuth(any(), any())).thenReturn(const {'Authorization': 'Basic test'});
  when(() => ltHttp.basicAuthRaw(any())).thenReturn(const {'Authorization': 'Basic test'});
  when(
    () => ltHttp.get(
      any(),
      headers: any(named: 'headers'),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer((_) async => http.Response('{}', 200));
  when(
    () => ltHttp.postJson(
      any(),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    ),
  ).thenAnswer((_) async => http.Response('{}', 200));
  when(
    () => ltHttp.postMultipart(
      any(),
      headers: any(named: 'headers'),
      fields: any(named: 'fields'),
      filePath: any(named: 'filePath'),
      onAnswered: any(named: 'onAnswered'),
    ),
  ).thenAnswer((_) async => http.Response('{}', 200));
  when(
    () => ltHttp.putFile(
      any(),
      headers: any(named: 'headers'),
      filePath: any(named: 'filePath'),
    ),
  ).thenAnswer((_) async => http.Response('', 201));

  // Failure diagnostics: a no-op by default so runner tests don't fire the real
  // LT-session fetch; the LtDiagnostics unit test exercises the real reporter.
  final ltDiagnostics = _MockLtDiagnostics();
  GetIt.I.registerLazySingleton<LtDiagnostics>(() => ltDiagnostics);
  when(
    () => ltDiagnostics.report(
      buildId: any(named: 'buildId'),
      platform: any(named: 'platform'),
      env: any(named: 'env'),
    ),
  ).thenAnswer((_) async {});

  // iOS signing inputs auto-derive to non-null by default so the resign + the
  // doctor signing check pass; tests override to exercise the missing paths.
  final iosCodesign = _MockIosCodesign();
  GetIt.I.registerLazySingleton<IosCodesign>(() => iosCodesign);
  when(iosCodesign.developerIdentity).thenAnswer((_) async => 'MOCKDEVELOPERIDENTITYSHA');
  when(() => iosCodesign.provisioningProfile(any())).thenAnswer((_) async => '/mock/runner.mobileprovision');
  when(
    () => iosCodesign.canSignHeadless(any(), sampleBinary: any(named: 'sampleBinary')),
  ).thenAnswer((_) async => true);

  final e2eCredentialsServer = _MockE2eCredentialsServer();
  GetIt.I.registerLazySingleton<E2eCredentialsServer>(() => e2eCredentialsServer);
  when(
    () => e2eCredentialsServer.start(
      repo: any(named: 'repo'),
      env: any(named: 'env'),
      tenant: any(named: 'tenant'),
      environment: any(named: 'environment'),
      userType: any(named: 'userType'),
      reuseLast: any(named: 'reuseLast'),
    ),
  ).thenAnswer((_) async => null);

  // Routing a USB phone through the Mac is adb + network I/O; by default the
  // run body executes with no egress env, as if routing were unavailable.
  final egress = _MockAndroidDeviceEgress();
  GetIt.I.registerLazySingleton<AndroidDeviceEgress>(() => egress);
  when(() => egress.around<int>(any(), any())).thenAnswer((invocation) {
    final run = invocation.positionalArguments[1] as Future<int> Function(Map<String, String>);
    return run(const {});
  });
  final iosEgress = _MockIosDeviceEgress();
  GetIt.I.registerLazySingleton<IosDeviceEgress>(() => iosEgress);
  when(() => iosEgress.around<int>(any(), any())).thenAnswer((invocation) {
    final run = invocation.positionalArguments[1] as Future<int> Function(Map<String, String>);
    return run(const {});
  });
  final devicePicker = _MockDevicePicker();
  GetIt.I.registerLazySingleton<DevicePicker>(() => devicePicker);
  // Real: without MPLATROL_IT_LEG_DIR and an expected upload it never releases.
  GetIt.I.registerLazySingleton<ItLegDir>(ItLegDir.new);
  // Leases are files under HOME shared by every mplatrol process; command tests hold nothing.
  final leases = _MockLocalDeviceLeases();
  GetIt.I.registerLazySingleton<LocalDeviceLeases>(() => leases);
  when(() => leases.hold(any(), label: any(named: 'label'), device: any(named: 'device'))).thenAnswer((_) async {});
  when(leases.childEnvironment).thenReturn(const {});
  when(leases.releaseAll).thenAnswer((_) async {});
  when(() => leases.heldElsewhere(any())).thenReturn(null);
  // Real: writes the build log and copies results under the (temporary) repo or leg directory.
  GetIt.I.registerLazySingleton<LocalLegArtifacts>(LocalLegArtifacts.new);
  // Enrollment and match responders drive adb/simctl and stream device logs; runner tests enroll nothing.
  final biometrics = _MockLocalBiometrics();
  GetIt.I.registerLazySingleton<LocalBiometrics>(() => biometrics);
  final responder = _MockBiometricResponder();
  when(responder.stop).thenAnswer((_) async {});
  when(() => biometrics.enrollAndroidEmulator(any())).thenAnswer((_) async => true);
  when(() => biometrics.enrollIosSimulator(any())).thenAnswer((_) async => true);
  when(() => biometrics.respondOnAndroidEmulator(any())).thenAnswer((_) async => responder);
  when(() => biometrics.respondOnIosSimulator(any())).thenAnswer((_) async => responder);
  // Result collection is in-memory logic; publishing writes files and prints
  // service messages, so the command tests verify it through this mock.
  GetIt.I.registerLazySingleton<ItRunResults>(ItRunResults.new);
  // Real: collects in memory and writes under the repo it is given.
  GetIt.I.registerLazySingleton<E2eCoverageReports>(E2eCoverageReports.new);
  // Real: a run-scoped value; declared until a test or `mplatrol run` sets an order.
  GetIt.I.registerLazySingleton<ItTestOrder>(ItTestOrder.new);
  // Real, but never signalled and starting no processes; the stop tests pass their own signals.
  GetIt.I.registerLazySingleton<ItRunStop>(
      () => ItRunStop(signals: () => const [], stopChildren: () async {}, exitNow: (_) {}));
  GetIt.I.registerLazySingleton<LtCapacityService>(LtCapacityService.new);
  final ciReporter = _MockItCiReporter();
  GetIt.I.registerLazySingleton<ItCiReporter>(() => ciReporter);
  when(() => ciReporter.finish(any())).thenAnswer((_) async {});
  GetIt.I.registerLazySingleton<LtSessionArtifacts>(_MockLtSessionArtifacts.new);
  // Target selection is logic over DevicePicker, so tests use the real selector.
  GetIt.I.registerLazySingleton<ItTargetSelector>(ItTargetSelector.new);
  // Doctor's checks are logic over FileSystem and MplatrolShell, both mocked here.
  GetIt.I.registerLazySingleton<DoctorChecks>(DoctorChecks.new);
  // Prepare runs the configured command through the stubbed ProcessRunFunction.
  GetIt.I.registerLazySingleton<PrepareHook>(PrepareHook.new);
  // No logins by default; credential tests register their own provider.
  GetIt.I.registerLazySingleton<CredentialProvider>(() => const EnvCredentialProvider());
  GetIt.I.registerLazySingleton<ResultSinks>(ResultSinks.new);
  // Disk checks and pruning are logic over MplatrolShell (df, du, trash) and real temp dirs.
  GetIt.I.registerLazySingleton<DiskSpace>(DiskSpace.new);
  GetIt.I.registerLazySingleton<TrashMover>(TrashMover.new);
  GetIt.I.registerLazySingleton<DiskJanitor>(DiskJanitor.new);
  // One device/simulator by default so `mplatrol run` uses it without prompting; the
  // interactive-selection tests override these with multiple entries.
  when(devicePicker.localAndroidRealDevices).thenAnswer((_) async => const []);
  when(devicePicker.localIosRealDevices).thenAnswer((_) async => const []);
  when(
    devicePicker.localAndroidDevices,
  ).thenAnswer((_) async => [LocalDevice(id: 'emulator-5554', label: 'Pixel (emulator-5554)')]);
  when(
    devicePicker.localIosSimulators,
  ).thenAnswer((_) async => [LocalDevice(id: 'SIM-UDID-26', label: 'iPhone 17 Pro')]);
  when(devicePicker.scanAndroidEmulators)
      .thenAnswer((_) async => DeviceScan(conforming: await devicePicker.localAndroidDevices(), rejected: const []));
  when(devicePicker.scanIosSimulators)
      .thenAnswer((_) async => DeviceScan(conforming: await devicePicker.localIosSimulators(), rejected: const []));
  final localDeviceService = _MockLocalDeviceService();
  GetIt.I.registerLazySingleton<LocalDeviceService>(() => localDeviceService);
  when(() => localDeviceService.isSpecEmulator(any())).thenAnswer((_) async => true);
  when(localDeviceService.bootAndroid).thenAnswer((_) async => null);
  when(() => localDeviceService.doctorFindings(any())).thenAnswer((_) async => const []);
}
