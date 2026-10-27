/// Patrol end-to-end test orchestration: local devices and LambdaTest real devices, device matrices, retries,
/// failure classification and reporting.
///
/// Embed the CLI to plug in your own credentials or result sinks:
///
/// ```dart
/// import 'package:get_it/get_it.dart';
/// import 'package:mplatrol/mplatrol.dart';
///
/// Future<void> main(List<String> args) async {
///   GetIt.I.registerSingleton<CredentialProvider>(MyVaultProvider());
///   GetIt.I.registerSingleton(ResultSinks([MyDashboardSink()]));
///   exitCode = await MplatrolCommandRunner().run(args);
/// }
/// ```
library;

export 'package:mplatrol/src/ci_report/it_result_category.dart' show ItResultCategory;
export 'package:mplatrol/src/ci_report/it_test_result.dart' show ItRunLeg, ItTestOutcome, ItTestResult;
export 'package:mplatrol/src/commands/mplatrol_command_runner.dart' show MplatrolCommandRunner;
export 'package:mplatrol/src/core/mplatrol_config.dart'
    show CredentialsOptions, ItOptions, MplatrolConfig, ReportingOptions, mplatrolConfigEnv, mplatrolConfigFileName;
export 'package:mplatrol/src/credentials/credential_provider.dart';
export 'package:mplatrol/src/results/result_sink.dart';
export 'package:mplatrol/src/test_lessons.dart' show TestLesson, recognizeTestLessons, registerTestLessons;
export 'package:mplatrol/src/version.dart';
