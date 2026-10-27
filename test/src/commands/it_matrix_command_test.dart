import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/commands/it_matrix_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_leg_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

class _DiskSpace extends Mock implements DiskSpace {}

void main() {
  late Directory root;
  late String lane;
  late String runDir;
  late List<List<String>> started;
  late List<Map<String, String>> startedEnv;

  Future<int> start(String executable, List<String> arguments,
      {required String workingDirectory,
      required Map<String, String> environment,
      required void Function(String line) onLine,
      required Future<void> stop}) async {
    started.add([executable, ...arguments]);
    startedEnv.add(environment);
    File(p.join(environment[itLegDirEnv]!, itCheckoutReleasedMarker)).writeAsStringSync('');
    onLine('[lane-release] artifacts uploaded');
    return arguments.contains('lt-ios') ? 70 : 0;
  }

  Future<int?> matrix(List<String> args, {MatrixProcessStarter? starter, List<Stream<ProcessSignal>>? signals}) =>
      (CommandRunner<int>('mplatrol', 'test')
            ..addCommand(ItMatrixCommand(
                start: starter ?? start, mplatrolCommand: ['mplatrol'], signals: () => signals ?? const [])))
          .run(['matrix', ...args]);

  setUp(() async {
    await scaffoldMockDependencies();
    root = Directory.systemTemp.createTempSync('mplatrol_matrix_cmd');
    lane = p.join(root.path, 'lane1', 'app');
    File(p.join(lane, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: app');
    Directory(p.join(lane, 'patrol_test')).createSync();
    runDir = p.join(root.path, 'round7');
    started = [];
    startedEnv = [];
    when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': root.path});
    final disk = _DiskSpace();
    when(() => disk.freeGb(any())).thenAnswer((_) async => 100);
    await GetIt.I.unregister<DiskSpace>();
    GetIt.I.registerSingleton<DiskSpace>(disk);
    when(() => getDep<MplatrolShell>().runArgs('/bin/sh', any(), throwOnError: false, silent: any(named: 'silent')))
        .thenAnswer((invocation) async {
      final script = (invocation.positionalArguments[1] as List<String>).last;
      return ProcessResultX.from(ProcessResult(0, script.contains('fail') ? 1 : 0, '', ''));
    });
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('runs tenants × variants interleaved, writes timings and runs the hooks', () async {
    final code = await matrix([
      '--run-dir=$runDir',
      '--lane=$lane',
      '--tenant=acme',
      '--leg=globex:lt-android',
      '--after-release=prune {lane}',
      '--publish=publish {run} --lanes=a,b'
    ]);

    expect(code, ExitCode.success.code);
    expect(started.map((args) => '${args[2]} ${args[3]}'),
        ['lt-ios --tenant=acme', 'lt-android --tenant=globex', 'lt-android --tenant=acme']);
    expect(File(p.join(runDir, 'timings.md')).readAsStringSync(), contains('## round7:'));
    verify(() => getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', 'prune $lane'], throwOnError: false, silent: true))
        .called(3);
    verify(() => getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', 'publish $runDir --lanes=a,b'], throwOnError: false))
        .called(1);
    verify(() =>
            getDep<MplatrolLogger>().info(any(that: startsWith('[matrix] 3 legs ran; 2 passed every selected test.'))))
        .called(1);
  });

  test('runs legs of one tenant in their own environments and user types beside the --environment legs', () async {
    final code = await matrix([
      '--run-dir=$runDir',
      '--lane=$lane',
      '--environment=Staging',
      '--leg=initech:lt-android',
      '--leg=demo@QA:lt-android;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756)',
      '--leg=demo@QA:lt-android;user=PinnedSdk_Eligible_NoFundingAccounts;tests=PROJ-TC-16957',
      '--leg=demo@QA:lt-ios;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756)'
    ]);

    expect(code, ExitCode.success.code);
    expect([
      for (final args in started) args.sublist(2, 5).join(' ')
    ], [
      'lt-ios --tenant=demo --environment=QA',
      'lt-android --tenant=initech --environment=Staging',
      'lt-android --tenant=demo --environment=QA',
      'lt-android --tenant=demo --environment=QA',
    ]);
    expect([for (final env in startedEnv) env['MPLATROL_E2E_USER_TYPE']],
        ['PinnedSdk_Enrolled', null, 'PinnedSdk_Enrolled', 'PinnedSdk_Eligible_NoFundingAccounts']);
    expect([
      for (final args in started) args.where((arg) => arg.startsWith('--target-regex=')).join()
    ], [
      '--target-regex=PROJ-TC-(16752|17756)',
      '',
      '--target-regex=PROJ-TC-(16752|17756)',
      '--target-regex=PROJ-TC-16957',
    ]);
    expect({for (final env in startedEnv) env['MPLATROL_E2E_CREDENTIALS_PORT']}, hasLength(4));
    final queue = File(p.join(runDir, 'queue.log')).readAsStringSync();
    expect(queue, contains('finish demo@QA:lt-android;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756) exit 0'));
    expect(Directory(p.join(runDir, 'legs', 'demo@QA+PinnedSdk_Eligible_NoFundingAccounts_lt-android')).existsSync(),
        isTrue);
  });

  test('marks the round complete, records the run and publishes after each leg', () async {
    await matrix(['--run-dir=$runDir', '--lane=$lane', '--leg=globex:lt-android', '--publish=publish {run}']);

    expect(File(p.join(runDir, 'round-state')).readAsStringSync(), 'complete\n');
    final latest =
        jsonDecode(File(p.join(root.path, '.mplatrol', 'matrix-publish', 'latest-run.json')).readAsStringSync())
            as Map<String, Object?>;
    expect(latest['run'], 'round7');
    verify(() =>
            getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', 'publish $runDir'], throwOnError: false, silent: true))
        .called(1);
  });

  test('a signal stops the running legs, publishes the partial round and exits 128 + the signal', () async {
    final signals = StreamController<ProcessSignal>();
    final running = Completer<void>();
    Future<int> hang(String executable, List<String> arguments,
        {required String workingDirectory,
        required Map<String, String> environment,
        required void Function(String line) onLine,
        required Future<void> stop}) async {
      running.complete();
      await stop;
      return 143;
    }

    final done = matrix(
        [
          '--run-dir=$runDir',
          '--lane=$lane',
          '--leg=globex:lt-ios',
          '--leg=globex:lt-android',
          '--publish=publish {run}'
        ],
        starter: hang,
        signals: [signals.stream]);
    await running.future;
    signals
      ..add(ProcessSignal.sigterm)
      ..add(ProcessSignal.sigint);

    expect(await done, 128 + 15);
    expect(File(p.join(runDir, 'round-state')).readAsStringSync(), 'partial\n');
    expect(File(p.join(runDir, 'timings.md')).existsSync(), isTrue);
    verify(() => getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', 'publish $runDir'], throwOnError: false)).called(1);
    verify(() => getDep<MplatrolLogger>().warn(any(that: contains('received SIGTERM')))).called(1);
    expect(File(p.join(runDir, 'queue.log')).readAsStringSync(), contains('abort: received SIGTERM'));
    await signals.close();
  });

  test('a fatal error still publishes, marked partial, and is rethrown', () async {
    when(() => getDep<MplatrolShell>().runArgs('/bin/sh', any(that: contains('boom {lane}'.replaceAll('{lane}', lane))),
        throwOnError: false, silent: any(named: 'silent'))).thenThrow(StateError('shell gone'));

    await expectLater(
        matrix([
          '--run-dir=$runDir',
          '--lane=$lane',
          '--leg=globex:lt-ios',
          '--after-release=boom {lane}',
          '--publish=publish {run}'
        ]),
        throwsStateError);

    expect(File(p.join(runDir, 'round-state')).readAsStringSync(), 'partial\n');
    verify(() => getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', 'publish $runDir'], throwOnError: false)).called(1);
  });

  test('watches the real process signals by default', () async {
    final code = await (CommandRunner<int>('mplatrol', 'test')
          ..addCommand(ItMatrixCommand(start: start, mplatrolCommand: ['mplatrol'])))
        .run(['matrix', '--run-dir=$runDir', '--lane=$lane', '--leg=globex:lt-android']);

    expect(code, ExitCode.success.code);
  });

  test('a failed publish hook fails the command', () async {
    final code = await matrix(['--run-dir=$runDir', '--lane=$lane', '--leg=globex:lt-ios', '--publish=fail']);

    expect(code, ExitCode.software.code);
    verify(() => getDep<MplatrolLogger>().err('[matrix] --publish "fail" failed (exit 1); rerun it by hand.'))
        .called(1);
  });

  for (final (args, problem) in [
    (['--lane=LANE', '--tenant=globex'], 'Pass --run-dir, at least one --lane and at least one --leg or --tenant.'),
    (['--run-dir=RUN', '--tenant=globex'], 'Pass --run-dir, at least one --lane and at least one --leg or --tenant.'),
    (['--run-dir=RUN', '--lane=LANE', '--leg=globex'], 'Fix the --leg values above.'),
    (['--run-dir=RUN', '--lane=/nowhere', '--tenant=globex'], 'Not an app checkout: /nowhere.'),
    (
      ['--run-dir=RUN', '--lane=LANE', '--tenant=globex', '--leg=globex:lt-ios'],
      'A leg is listed twice: globex_lt-ios. Legs of one tenant and variant need their own environment '
          '(<tenant>@<environment>) or user type (;user=).'
    ),
    (
      ['--run-dir=RUN', '--lane=LANE', '--leg=demo@QA:lt-ios;tests=a', '--leg=demo@QA:lt-ios;tests=b'],
      'A leg is listed twice: demo@QA_lt-ios. Legs of one tenant and variant need their own environment '
          '(<tenant>@<environment>) or user type (;user=).'
    ),
    (
      ['--run-dir=RUN', '--lane=LANE', '--tenant=globex', '--min-free-gb=lots'],
      '--min-free-gb must be a whole number of GB.'
    ),
  ]) {
    test('refuses ${args.join(' ')}', () async {
      final code = await matrix([for (final arg in args) arg.replaceAll('RUN', runDir).replaceAll('LANE', lane)]);
      expect(code, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(problem)).called(1);
      expect(started, isEmpty);
    });
  }

  test('refuses a run directory that already holds a run', () async {
    File(p.join(runDir, 'queue.log'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    expect(await matrix(['--run-dir=$runDir', '--lane=$lane', '--tenant=globex']), ExitCode.usage.code);
    verify(() => getDep<MplatrolLogger>().err('$runDir already holds a run; use a new --run-dir.')).called(1);
  });

  test('names a malformed leg', () async {
    await matrix(['--run-dir=$runDir', '--lane=$lane', '--leg=globex:mac']);
    verify(() => getDep<MplatrolLogger>().err('--leg globex:mac: want $matrixLegSpec.')).called(1);
  });

  for (final (spec, device) in [
    ('globex:android@Pixel 8-14', 'mplatrol_e2e_pixel9 emulator'),
    ('globex:ios@iPhone 15-17', 'iPhone 17 Pro simulator')
  ]) {
    test('refuses a device on the local leg $spec', () async {
      expect(await matrix(['--run-dir=$runDir', '--lane=$lane', '--leg=$spec']), ExitCode.usage.code);
      final variant = spec.split(':').last.split('@').first;
      final pinned = spec.split('@').last;
      verify(() => getDep<MplatrolLogger>().err('--leg $spec: @device picks a LambdaTest device; a local $variant leg '
          'runs on the $device. Drop @$pinned, or use lt-$variant.')).called(1);
      expect(started, isEmpty);
    });
  }

  test('runs local legs as mplatrol run android|ios, holding the device under HOME, with the LambdaTest legs',
      () async {
    final code = await matrix([
      '--run-dir=$runDir',
      '--lane=$lane',
      '--tenant=acme',
      '--variant=android',
      '--variant=ios',
      '--variant=lt-android'
    ]);

    expect(code, ExitCode.success.code);
    expect(started.map((args) => '${args[2]} ${args[3]}'),
        unorderedEquals(['ios --tenant=acme', 'android --tenant=acme', 'lt-android --tenant=acme']));
    final leases = Directory(p.join(root.path, '.mplatrol', 'local-devices'));
    expect(File(p.join(leases.path, 'android', 'usage.log')).readAsLinesSync().map((line) => line.split(' ')[1]),
        ['grant', 'release']);
    expect(File(p.join(leases.path, 'ios', 'usage.log')).existsSync(), isTrue);
    final queue = File(p.join(runDir, 'queue.log')).readAsStringSync();
    expect(queue, contains('finish acme:android exit 0'));
    expect(File(p.join(runDir, 'timings.md')).readAsStringSync(), contains('| acme:ios |'));
  });

  test('allows the four variants and keeps the LambdaTest ones by default', () {
    final variant = ItMatrixCommand().argParser.options['variant']!;
    expect(variant.allowed, ['lt-ios', 'lt-android', 'ios', 'android']);
    expect(variant.defaultsTo, ['lt-ios', 'lt-android']);
  });

  test('is an it subcommand with the default command line', () {
    expect(ItMatrixCommand().name, 'matrix');
    expect(ItMatrixCommand().description, contains('iOS and Android in parallel'));
    expect(currentMplatrolCommand(), isNotEmpty);
  });
}
