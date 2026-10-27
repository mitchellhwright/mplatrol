import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/lt_app_upload.dart';

extension TestHelper on MplatrolShell {
  Future<ProcessResultX> stubbedRun(
    String script, {
    Logger? logger,
    String? workingDirectory,
    bool? throwOnError,
    bool? forceVerbose,
    bool? silent,
    bool? quietBuild,
  }) =>
      run(
        script,
        workingDirectory: workingDirectory ?? any(named: 'workingDirectory'),
        throwOnError: throwOnError ?? any(named: 'throwOnError'),
        forceVerbose: forceVerbose ?? any(named: 'forceVerbose'),
        silent: silent ?? any(named: 'silent'),
        quietBuild: quietBuild ?? any(named: 'quietBuild'),
      );
}

/// An [LtUploadPolicy] with the production attempt count and no waits, so upload retries run instantly.
final instantLtUploadPolicy = LtUploadPolicy(
  attemptDelays: List.filled(LtUploadPolicy.defaultAttemptDelays.length, Duration.zero),
  retryDelay: Duration.zero,
  capPollInterval: Duration.zero,
);
