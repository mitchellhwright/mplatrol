import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

void main() {
  late List<Map<String, String>> prepared;

  setUp(() async {
    await scaffoldMockDependencies();
    prepared = [];
    GetIt.I.unregister<ProcessRunFunction>();
    GetIt.I.registerSingleton<ProcessRunFunction>((executable, arguments, {workingDirectory, environment}) async {
      prepared.add(environment!);
      return ProcessResult(0, 0, '', '');
    });
  });

  test('builds both platforms after preparing the configured tenant', () async {
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./configure_tenant.sh');

    expect(await MplatrolCommandRunner().run(['build']), ExitCode.success.code);

    expect(prepared.single['MPLATROL_TENANT'], 'default');
    expect(prepared.single['MPLATROL_PLATFORMS'], 'android,ios');
    verify(() => getDep<LtAndroidRunner>().buildAndroid(repo: any(named: 'repo'), target: 'patrol_test/app_test.dart'))
        .called(1);
    verify(() => getDep<LtIosRunner>().buildIosForTesting(bundleId: 'com.example.app')).called(1);
  });

  test('prepares and builds each --tenant in turn', () async {
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./configure_tenant.sh');

    expect(await MplatrolCommandRunner().run(['build', '--tenant=acme,globex']), ExitCode.success.code);

    expect([for (final env in prepared) env['MPLATROL_TENANT']], ['acme', 'globex']);
  });

  test('a failed prepare stops that tenant before any build', () async {
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./configure_tenant.sh');
    GetIt.I.unregister<ProcessRunFunction>();
    GetIt.I.registerSingleton<ProcessRunFunction>(
        (executable, arguments, {workingDirectory, environment}) async => ProcessResult(0, 3, '', 'no such tenant'));

    expect(await MplatrolCommandRunner().run(['build']), 3);

    verifyNever(() => getDep<LtAndroidRunner>().buildAndroid(repo: any(named: 'repo'), target: any(named: 'target')));
  });

  test('a failed platform build fails the command', () async {
    when(() => getDep<LtAndroidRunner>().buildAndroid(repo: any(named: 'repo'), target: any(named: 'target')))
        .thenAnswer((_) async => 1);

    expect(await MplatrolCommandRunner().run(['build']), ExitCode.software.code);
  });
}
