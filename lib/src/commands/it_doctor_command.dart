import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/terminal_capabilities.dart';
import 'package:mplatrol/src/core/terminal_text.dart';
import 'package:mplatrol/src/doctor/doctor_checks.dart';
import 'package:mplatrol/src/local_device_service.dart';

/// `mplatrol doctor` checks this machine for what the variants need and prints the fix of every failed check.
class ItDoctorCommand extends BaseCommand {
  @override
  String get name => 'doctor';

  @override
  String get description => 'Check the tools, devices and LambdaTest setup the variants need.';

  @override
  void validateInput() {}

  @override
  Future<int> runCommand() async {
    final checks = getDep<DoctorChecks>();
    final env = platformWrapper.environment;
    final adb = shell.whichSync('adb') == null
        ? const <String>[]
        : (await shell.runArgs('adb', ['devices'], throwOnError: false, silent: true)).outLines.toList();
    final findings = [
      ...checks.tools(mac: platformWrapper.isMac),
      ...checks.lambdaTestCredentials(env),
      ...checks.lambdaTestBinaries(env),
      if (platformWrapper.isMac) checks.utf8Locale(env),
      ...await checks.emulatorMemory(adb),
      ...await getDep<LocalDeviceService>().doctorFindings(adb),
    ];
    final text = TerminalText(getDep<TerminalCapabilities>());
    for (final finding in findings) {
      if (finding.ok) {
        logger.info('${text.ok} ${finding.label}');
      } else {
        logger
          ..info('${text.fail} ${finding.label}')
          ..info('    ${finding.fix}');
      }
    }
    final failed = findings.where((finding) => !finding.ok).length;
    logger.info(failed == 0 ? 'Everything checked is ready.' : '$failed check(s) need attention.');
    return failed == 0 ? ExitCode.success.code : ExitCode.unavailable.code;
  }
}
