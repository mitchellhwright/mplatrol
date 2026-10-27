import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/commands/it_build_command.dart';
import 'package:mplatrol/src/commands/it_clean_command.dart';
import 'package:mplatrol/src/commands/it_coverage_command.dart';
import 'package:mplatrol/src/commands/it_devices_command.dart';
import 'package:mplatrol/src/commands/it_doctor_command.dart';
import 'package:mplatrol/src/commands/it_matrix_command.dart';
import 'package:mplatrol/src/commands/it_run_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/version.dart';

/// The `mplatrol` command line: Patrol E2E runs on local devices and LambdaTest.
///
/// Register your own `CredentialProvider` or `ResultSinks` in GetIt before [run] to plug in a secret store or a
/// results system, and pass project [TestLesson]s to classify your own failures; everything else gets its
/// default.
class MplatrolCommandRunner extends CommandRunner<int> {
  /// The runner with every command. [lessons] ([TestLesson.custom]) are recognized in failure output besides the
  /// built-in lessons and those of the `lessons:` block of `mplatrol.yaml`.
  MplatrolCommandRunner({List<TestLesson> lessons = const []})
      : _lessons = lessons,
        super('mplatrol', 'Run Patrol end-to-end tests on local devices and LambdaTest real devices.') {
    argParser
      ..addFlag('version', negatable: false, help: 'Print the mplatrol version.')
      ..addFlag('verbose', negatable: false, help: 'Show every line the builds and test runs print.');
    addCommand(ItRunCommand());
    addCommand(ItBuildCommand());
    addCommand(ItMatrixCommand());
    addCommand(ItDevicesCommand());
    addCommand(ItDoctorCommand());
    addCommand(ItCleanCommand());
    addCommand(ItCoverageCommand());
  }

  final List<TestLesson> _lessons;

  /// Runs [args]; returns the exit code. Usage errors exit 64 with the usage text.
  @override
  Future<int> run(Iterable<String> args) async {
    Dependencies.registerGlobalDependencies();
    final logger = getDep<MplatrolLogger>();
    try {
      registerTestLessons([..._lessons, ...getDep<MplatrolConfig>().lessons]);
    } on FormatException catch (error) {
      logger.err('Invalid lesson: ${error.message}');
      return ExitCode.config.code;
    } on ArgumentError catch (error) {
      logger.err('Invalid lesson: ${error.name} ${error.message} (${error.invalidValue}).');
      return ExitCode.config.code;
    }
    try {
      final results = parse(args);
      if (results['verbose'] as bool) {
        logger.level = Level.verbose;
      }
      if (results['version'] as bool) {
        logger.info(mplatrolVersion);
        return ExitCode.success.code;
      }
      return await runCommand(results) ?? ExitCode.success.code;
    } on UsageException catch (error) {
      logger
        ..err(error.message)
        ..info('')
        ..info(error.usage);
      return ExitCode.usage.code;
    }
  }
}
