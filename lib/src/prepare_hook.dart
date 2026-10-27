import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/patrol_package_patcher.dart';

/// Prepares the app before a tenant's builds: runs the project's own `prepare.command` from `mplatrol.yaml`
/// (e.g. a white-label setup script), then points `patrol` at the patched copy [PatrolPackagePatcher] keeps,
/// unless `prepare.patch-patrol` is false.
///
/// The command runs through `/bin/sh -c` in the app folder with `MPLATROL_TENANT`, `MPLATROL_ENVIRONMENT` and
/// `MPLATROL_PLATFORMS` (`android`, `ios` or `android,ios`) set.
class PrepareHook {
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Prepares [repo] for [tenant] on [environment] and the given [platforms]; returns the first non-zero exit
  /// code (0 when every step passed).
  Future<int> run({
    required String repo,
    required String tenant,
    required String environment,
    required Set<String> platforms,
  }) async {
    final config = getDep<MplatrolConfig>();
    final code = await _runCommand(config.prepareCommand,
        repo: repo, tenant: tenant, environment: environment, platforms: platforms);
    if (code != ExitCode.success.code || !config.patchPatrol) {
      return code;
    }
    await getDep<PatrolPackagePatcher>().patch(repo);
    return ExitCode.success.code;
  }

  Future<int> _runCommand(
    String? command, {
    required String repo,
    required String tenant,
    required String environment,
    required Set<String> platforms,
  }) async {
    if (command == null || command.trim().isEmpty) {
      return ExitCode.success.code;
    }
    _logger.info('[prepare] $command (tenant: $tenant, environment: $environment)');
    final result = await getDep<ProcessRunFunction>()(
      '/bin/sh',
      ['-c', command],
      workingDirectory: repo,
      environment: {
        ...getDep<PlatformWrapper>().environment,
        'MPLATROL_TENANT': tenant,
        'MPLATROL_ENVIRONMENT': environment,
        'MPLATROL_PLATFORMS': (platforms.toList()..sort()).join(','),
      },
    );
    final output = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != ExitCode.success.code) {
      _logger.err('[prepare] `$command` failed (exit ${result.exitCode}) for tenant $tenant.');
      if (output.isNotEmpty) {
        _logger.err(output);
      }
    } else if (output.isNotEmpty) {
      _logger.detail(output);
    }
    return result.exitCode;
  }
}
