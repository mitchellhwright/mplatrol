import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/patrol_package_patcher.dart';
import 'package:mplatrol/src/prepare_hook.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _Patcher extends Mock implements PatrolPackagePatcher {}

void main() {
  late List<({String executable, List<String> arguments, String? cwd, Map<String, String>? env})> runs;
  late int exitCode;
  late _Patcher patcher;

  setUp(() async {
    await scaffoldMockDependencies();
    runs = [];
    exitCode = 0;
    GetIt.I.unregister<ProcessRunFunction>();
    GetIt.I.registerSingleton<ProcessRunFunction>((executable, arguments, {workingDirectory, environment}) async {
      runs.add((executable: executable, arguments: arguments, cwd: workingDirectory, env: environment));
      return ProcessResult(1, exitCode, 'prepared', exitCode == 0 ? '' : 'no such tenant');
    });
    patcher = _Patcher();
    when(() => patcher.patch(any())).thenAnswer((_) async {});
    GetIt.I.registerSingleton<PatrolPackagePatcher>(patcher);
  });

  Future<int> prepare() =>
      PrepareHook().run(repo: '/app', tenant: 'acme', environment: 'qa', platforms: const {'ios', 'android'});

  test('runs the configured command in the app with the tenant, environment and platforms', () async {
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./tool/configure_tenant.sh');

    expect(await prepare(), ExitCode.success.code);

    final run = runs.single;
    expect([run.executable, ...run.arguments], ['/bin/sh', '-c', './tool/configure_tenant.sh']);
    expect(run.cwd, '/app');
    expect([run.env!['MPLATROL_TENANT'], run.env!['MPLATROL_ENVIRONMENT'], run.env!['MPLATROL_PLATFORMS']],
        ['acme', 'qa', 'android,ios']);
  });

  test('without a command nothing runs', () async {
    expect(await prepare(), ExitCode.success.code);
    expect(runs, isEmpty);
  });

  test('a failing command returns its exit code with its output, and skips the Patrol patch', () async {
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./tool/configure_tenant.sh');
    when(() => getDep<MplatrolConfig>().patchPatrol).thenReturn(true);
    exitCode = 3;

    expect(await prepare(), 3);

    verify(() => getDep<MplatrolLogger>().err(any(that: contains('failed (exit 3) for tenant acme')))).called(1);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('no such tenant')))).called(1);
    verifyNever(() => patcher.patch(any()));
  });

  test('patches Patrol after the command unless prepare.patch-patrol is false', () async {
    when(() => getDep<MplatrolConfig>().patchPatrol).thenReturn(true);
    await prepare();
    verify(() => patcher.patch('/app')).called(1);

    when(() => getDep<MplatrolConfig>().patchPatrol).thenReturn(false);
    await prepare();
    verifyNever(() => patcher.patch(any()));
  });
}
