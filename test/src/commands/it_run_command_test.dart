import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_run_function.dart';
import 'package:mplatrol/src/e2e_credentials_server.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/lt_hyperexecute_runner.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

/// Every local and LambdaTest run of the command under test, with the env it got.
final _runs = <({ItVariant variant, Map<String, String> env, String? tenant})>[];

void _stubRunners({int localCode = 0, int ltCode = 0}) {
  when(() => getDep<LocalRunner>().run(
        variant: any(named: 'variant'),
        deviceId: any(named: 'deviceId'),
        target: any(named: 'target'),
        targetRegex: any(named: 'targetRegex'),
        sdk: any(named: 'sdk'),
        env: any(named: 'env'),
        reuseLast: any(named: 'reuseLast'),
        develop: any(named: 'develop'),
        coverage: any(named: 'coverage'),
        onBuildStarted: any(named: 'onBuildStarted'),
      )).thenAnswer((invocation) async {
    _runs.add((
      variant: invocation.namedArguments[#variant] as ItVariant,
      env: invocation.namedArguments[#env] as Map<String, String>,
      tenant: null,
    ));
    return localCode;
  });
  for (final ios in [false, true]) {
    Future<int> Function(Invocation) record(ItVariant variant) => (invocation) async {
          _runs.add((
            variant: variant,
            env: invocation.namedArguments[#env] as Map<String, String>,
            tenant: invocation.namedArguments[#tenantLabel] as String?,
          ));
          return ltCode;
        };
    final runner = getDep<LtHyperexecuteRunner>();
    if (ios) {
      when(() => runner.runIos(
            target: any(named: 'target'),
            devices: any(named: 'devices'),
            idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
            env: any(named: 'env'),
            targetRegex: any(named: 'targetRegex'),
            sdk: any(named: 'sdk'),
            tenantLabel: any(named: 'tenantLabel'),
            environmentLabel: any(named: 'environmentLabel'),
            reuseLast: any(named: 'reuseLast'),
          )).thenAnswer(record(ItVariant.ltIos));
    } else {
      when(() => runner.runAndroid(
            target: any(named: 'target'),
            devices: any(named: 'devices'),
            idleTimeoutSeconds: any(named: 'idleTimeoutSeconds'),
            env: any(named: 'env'),
            targetRegex: any(named: 'targetRegex'),
            sdk: any(named: 'sdk'),
            tenantLabel: any(named: 'tenantLabel'),
            environmentLabel: any(named: 'environmentLabel'),
            reuseLast: any(named: 'reuseLast'),
          )).thenAnswer(record(ItVariant.ltAndroid));
    }
  }
}

void main() {
  late List<Map<String, String>> prepared;
  late int prepareCode;

  setUp(() async {
    await scaffoldMockDependencies();
    _runs.clear();
    prepared = [];
    prepareCode = 0;
    GetIt.I.unregister<ProcessRunFunction>();
    GetIt.I.registerSingleton<ProcessRunFunction>((executable, arguments, {workingDirectory, environment}) async {
      prepared.add(environment!);
      return ProcessResult(0, prepareCode, '', '');
    });
    when(() => getDep<MplatrolConfig>().prepareCommand).thenReturn('./tool/configure_tenant.sh');
    _stubRunners();
  });

  Future<int> run(String args) => MplatrolCommandRunner().run(args.split(' '));

  group('usage', () {
    for (final (args, problem) in [
      ('run', 'Pass a variant'),
      ('run nope', 'Unknown variant "nope"'),
      ('run android ios', 'Pass at most one variant'),
      ('run all --device=emulator-5554', '--device can only target one variant'),
      ('run auto --device=x', '--device already picks the target'),
      ('run lt-ios --coverage', '--coverage works on the local android and ios variants only'),
      ('run android --develop', '--develop needs --target='),
      ('run lt-android --develop --target=patrol_test/a_test.dart', '--develop runs on one local device'),
      ('run android --target-regex=(', 'Invalid --target-regex "("'),
      ('run android --seed=abc', 'seed'),
    ]) {
      test('rejects `$args`', () async {
        expect(await run(args), ExitCode.usage.code);
        verify(() => getDep<MplatrolLogger>().err(any(that: contains(problem)))).called(1);
        expect(_runs, isEmpty);
      });
    }
  });

  test('prepares the configured tenant, then runs the local variant on the spec device', () async {
    expect(await run('run android'), ExitCode.success.code);

    expect(prepared.single['MPLATROL_TENANT'], 'default');
    expect(prepared.single['MPLATROL_PLATFORMS'], 'android');
    final local = _runs.single;
    expect(local.variant, ItVariant.androidLocal);
    expect([local.env[e2eEnvironmentEnv], local.env[e2eTenantEnv]], ['staging', 'default']);
    verify(() => getDep<ItCiReporter>().finish(any())).called(1);
  });

  test('runs every --tenant in turn against --environment, and LambdaTest legs with their labels', () async {
    when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': '/home/u'});
    expect(await run('run lt-all --tenant=acme,globex --environment=qa'), ExitCode.success.code);

    expect([for (final env in prepared) env['MPLATROL_TENANT']], ['acme', 'globex']);
    expect([for (final env in prepared) env['MPLATROL_PLATFORMS']], ['android,ios', 'android,ios']);
    expect({
      for (final run in _runs) (run.variant, run.tenant)
    }, {
      (ItVariant.ltAndroid, 'acme'),
      (ItVariant.ltIos, 'acme'),
      (ItVariant.ltAndroid, 'globex'),
      (ItVariant.ltIos, 'globex')
    });
    expect({for (final run in _runs) run.env['LT_BIN']}, {'/home/u/.mplatrol/hyperexecute/LT'});
  });

  test('takes the environment from MPLATROL_E2E_ENVIRONMENT when no --environment is given', () async {
    when(() => getDep<PlatformWrapper>().environment).thenReturn({e2eEnvironmentEnv: 'uat'});

    await run('run android');

    expect(_runs.single.env[e2eEnvironmentEnv], 'uat');
  });

  test('a failed prepare stops the tenant before any test runs', () async {
    prepareCode = 3;

    expect(await run('run android'), 3);

    expect(_runs, isEmpty);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('Prepare failed for "default"')))).called(1);
  });

  test('without logins the run continues and tells the suite to skip the sign-in journeys', () async {
    await run('run android');

    expect(_runs.single.env[e2eSkipHappyLoginTestEnv], 'true');
    verify(() => getDep<MplatrolLogger>().warn(any(that: contains('the credential provider has no login')))).called(1);
  });

  test('with logins the legs get the credential server endpoint', () async {
    final handle = _Handle();
    when(() => getDep<E2eCredentialsServer>().start(
          repo: any(named: 'repo'),
          env: any(named: 'env'),
          tenant: any(named: 'tenant'),
          environment: any(named: 'environment'),
          userType: any(named: 'userType'),
          reuseLast: any(named: 'reuseLast'),
        )).thenAnswer((_) async => handle);

    await run('run android');

    expect(_runs.single.env[e2eCredentialsUrlEnv], 'http://10.0.2.2:1/e2e-credentials?token=t');
    expect(_runs.single.env[e2eSkipHappyLoginTestEnv], isNull);
    expect(handle.closed, isTrue);
  });

  test('a failing variant fails the run with its exit code', () async {
    _stubRunners(ltCode: 7);

    expect(await run('run lt-ios'), 7);
  });
}

class _Handle extends Fake implements E2eCredentialsServerHandle {
  var closed = false;

  @override
  Map<String, String> envFor(ItVariant variant, Map<String, String> baseEnv) =>
      {...baseEnv, e2eCredentialsUrlEnv: 'http://10.0.2.2:1/e2e-credentials?token=t'};

  @override
  Future<void> close() async => closed = true;
}
