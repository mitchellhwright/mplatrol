import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:mplatrol/src/android_device_egress.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
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
import 'package:mplatrol/src/patrol_package_patcher.dart';
import 'package:mplatrol/src/prepare_hook.dart';
import 'package:mplatrol/src/results/result_sink.dart';
import 'package:mplatrol/src/test_order.dart';

/// The registered instance of [T].
T getDep<T extends Object>() => GetIt.I.get<T>();

/// Registers the CLI's services in [GetIt]. Anything a test registered first is kept, so tests can swap in fakes.
abstract final class Dependencies {
  /// Registers every service that is not registered yet.
  static void registerGlobalDependencies() {
    void lazy<T extends Object>(T Function() create) {
      if (!GetIt.I.isRegistered<T>()) {
        GetIt.I.registerLazySingleton<T>(create);
      }
    }

    lazy<MplatrolShell>(MplatrolShell.constructGlobalInstance);
    lazy<TerminalCapabilities>(detectTerminalCapabilities);
    lazy<MplatrolLogger>(MplatrolLogger.constructGlobalInstance);
    lazy<FileSystem>(FileSystem.constructGlobalInstance);
    lazy<PlatformWrapper>(PlatformWrapper.constructGlobalInstance);
    lazy<MplatrolConfig>(MplatrolConfig.load);
    lazy<SleepFunction>(() => Future.delayed);
    lazy<ProcessRunFunction>(() => Process.run);
    lazy<http.Client>(http.Client.new);
    lazy<CredentialProvider>(() => CredentialProvider.fromConfig(getDep<MplatrolConfig>().credentials));
    lazy<ResultSinks>(() => ResultSinks.fromConfig(getDep<MplatrolConfig>().reporting));
    lazy<AndroidDeviceEgress>(AndroidDeviceEgress.new);
    lazy<IosDeviceEgress>(IosDeviceEgress.new);
    lazy<DiskSpace>(DiskSpace.new);
    lazy<TrashMover>(TrashMover.new);
    lazy<DiskJanitor>(DiskJanitor.new);
    lazy<DevicePicker>(DevicePicker.new);
    lazy<LocalDeviceService>(LocalDeviceService.new);
    lazy<ItTargetSelector>(ItTargetSelector.new);
    lazy<E2eCredentialsServer>(E2eCredentialsServer.new);
    lazy<IosCodesign>(IosCodesign.new);
    lazy<LocalRunner>(LocalRunner.new);
    lazy<LtAndroidRunner>(LtAndroidRunner.new);
    lazy<LtHttp>(LtHttp.new);
    lazy<LtDiagnostics>(LtDiagnostics.new);
    lazy<LtIosRunner>(LtIosRunner.new);
    lazy<LtHyperexecuteRunner>(LtHyperexecuteRunner.new);
    lazy<LtTunnel>(LtTunnel.new);
    lazy<LtSessionArtifacts>(LtSessionArtifacts.new);
    lazy<LtCapacityService>(LtCapacityService.new);
    lazy<ItLegDir>(ItLegDir.new);
    lazy<LocalDeviceLeases>(LocalDeviceLeases.new);
    lazy<LocalLegArtifacts>(LocalLegArtifacts.new);
    lazy<LocalBiometrics>(LocalBiometrics.new);
    lazy<ItRunResults>(ItRunResults.new);
    lazy<ItCiReporter>(ItCiReporter.new);
    lazy<E2eCoverageReports>(E2eCoverageReports.new);
    lazy<ItTestOrder>(ItTestOrder.new);
    lazy<ItRunStop>(ItRunStop.new);
    lazy<PrepareHook>(PrepareHook.new);
    lazy<PatrolPackagePatcher>(PatrolPackagePatcher.new);
    lazy<DoctorChecks>(DoctorChecks.new);
  }
}
