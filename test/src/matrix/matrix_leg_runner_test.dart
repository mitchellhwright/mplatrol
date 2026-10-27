import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_leg_runner.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('mplatrol_matrix_runner'));
  tearDown(() => root.deleteSync(recursive: true));

  test('gives each leg a fixed pair of ports across runs', () {
    final dir = p.join(root.path, 'endpoints');
    final ports = MatrixPorts(dir);
    expect([ports.portFor('acme_lt-ios'), ports.portFor('acme_lt-android'), ports.portFor('acme_lt-ios')],
        [47200, 47202, 47200]);
    File(p.join(dir, 'ports')).writeAsStringSync('junk\ninitech_lt-ios 47300\n', mode: FileMode.append);
    expect(MatrixPorts(dir).portFor('cyberdyne_lt-ios'), 47302);
    expect(ports.endpointFile('globex_lt-ios'), p.join(dir, 'globex_lt-ios.json'));
  });

  test('runs the leg with its directory, endpoints, run id and JUnit, and logs its output', () async {
    final run = MatrixRunDir(p.join(root.path, 'round7'));
    final leg = MatrixLeg.parse('initech:lt-ios@iPhone 15-17')!;
    late List<String> started;
    late Map<String, String> env;
    late String cwd;
    final runner = MatrixLegRunner(
      command: ['dart', 'bin/mplatrol.dart'],
      ports: MatrixPorts(p.join(root.path, 'endpoints')),
      clock: () => DateTime(2026, 10, 3, 15, 4, 5),
      start: (executable, arguments,
          {required workingDirectory, required environment, required onLine, required stop}) async {
        started = [executable, ...arguments];
        env = environment;
        cwd = workingDirectory;
        onLine('[lane-release] artifacts uploaded');
        File(p.join(environment[itLegDirEnv]!, itCheckoutReleasedMarker)).writeAsStringSync('now');
        return 70;
      },
    );

    final handle = runner.start(leg, lane: '/w/lane1/app', run: run, base: {'HOME': '/home', 'PATH': '/bin'});

    expect(await handle.exitCode, 70);
    expect(await handle.released, isTrue);
    expect(cwd, '/w/lane1/app');
    expect(started, [
      'dart',
      'bin/mplatrol.dart',
      'run',
      'lt-ios',
      '--tenant=initech',
      '--environment=staging',
      '--device=iPhone 15-17',
      '--junit=${run.junit(leg, DateTime(2026, 10, 3, 15, 4, 5))}'
    ]);
    expect(env, {
      'HOME': '/home',
      'PATH': '/bin',
      'MPLATROL_IT_LEG_DIR': run.legDir(leg),
      'MPLATROL_E2E_CREDENTIALS_PORT': '47200',
      'MPLATROL_E2E_CREDENTIALS_ENDPOINT_FILE': p.join(root.path, 'endpoints', 'initech_lt-ios.json'),
      'MPLATROL_IOS_SHARD_COORDINATOR_PORT': '47201',
      'MPLATROL_IT_AUTO_CLEAN': 'off',
      'MPLATROL_RUN_ID': 'round7',
    });
    expect(File(run.log(leg)).readAsLinesSync(), [
      '2026-10-03 15:04:05.000 lane=/w/lane1/app leg=initech:lt-ios@iPhone 15-17 port=47200',
      '[lane-release] artifacts uploaded',
      'EXIT 70 2026-10-03 15:04:05.000',
    ]);
    expect(File(run.times(leg)).readAsStringSync(), '15:04:05 [lane-release] artifacts uploaded\n');
  });

  test("runs a leg in its own environment, with its tests and user type, on the leg's own endpoints", () async {
    final run = MatrixRunDir(p.join(root.path, 'round8'));
    final leg = MatrixLeg.parse('demo@QA:lt-android;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756)')!;
    final plain = MatrixLeg.parse('demo:lt-android')!;
    final started = <List<String>>[];
    final envs = <Map<String, String>>[];
    final runner = MatrixLegRunner(
      command: ['mplatrol'],
      ports: MatrixPorts(p.join(root.path, 'endpoints')),
      clock: () => DateTime(2026, 10, 15, 11),
      start: (executable, arguments,
          {required workingDirectory, required environment, required onLine, required stop}) async {
        started.add(arguments);
        envs.add(environment);
        return 0;
      },
    );
    final base = {'HOME': '/home', 'MPLATROL_E2E_USER_TYPE': 'Inherited'};

    await runner.start(leg, lane: '/w/lane1/app', run: run, base: base).exitCode;
    await runner.start(plain, lane: '/w/lane2/app', run: run, base: base).exitCode;

    expect(started.first, [
      'run',
      'lt-android',
      '--tenant=demo',
      '--environment=QA',
      '--target-regex=PROJ-TC-(16752|17756)',
      '--junit=${run.junit(leg, DateTime(2026, 10, 15, 11))}'
    ]);
    expect(started.last, [
      'run',
      'lt-android',
      '--tenant=demo',
      '--environment=staging',
      '--junit=${run.junit(plain, DateTime(2026, 10, 15, 11))}'
    ]);
    expect(envs.first['MPLATROL_E2E_USER_TYPE'], 'PinnedSdk_Enrolled');
    expect(envs.last['MPLATROL_E2E_USER_TYPE'], 'Inherited', reason: "a leg without user= keeps the round's");
    expect(
        [envs.first['MPLATROL_E2E_CREDENTIALS_PORT'], envs.last['MPLATROL_E2E_CREDENTIALS_PORT']], ['47200', '47202']);
    expect(envs.first['MPLATROL_E2E_CREDENTIALS_ENDPOINT_FILE'],
        p.join(root.path, 'endpoints', 'demo@QA+PinnedSdk_Enrolled_lt-android.json'));
    expect(envs.first['MPLATROL_IT_LEG_DIR'], p.join(run.path, 'legs', 'demo@QA+PinnedSdk_Enrolled_lt-android'));
    expect(
        run.junit(leg, DateTime.utc(2026, 10, 15, 11)),
        p.join(run.path, 'legs', 'demo@QA+PinnedSdk_Enrolled_lt-android', 'reports',
            'junit-demo-lt-android-20261015T110000Z.xml'));
  });

  test('a leg that exits without freeing its checkout is not released', () async {
    final exit = Completer<int>();
    final runner = MatrixLegRunner(
      command: ['mplatrol'],
      ports: MatrixPorts(p.join(root.path, 'endpoints')),
      start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) =>
          exit.future,
    );
    final handle = runner.start(MatrixLeg.parse('globex:lt-android')!,
        lane: root.path, run: MatrixRunDir(p.join(root.path, 'run')), base: const {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    exit.complete(1);
    expect(await handle.released, isFalse);
  });

  test('a leg whose process cannot start fails with its reason logged instead of crashing the round', () async {
    final runner = MatrixLegRunner(
      command: ['mplatrol'],
      ports: MatrixPorts(p.join(root.path, 'endpoints')),
      start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) =>
          throw ProcessException(executable, arguments, 'No such file or directory'),
    );
    final run = MatrixRunDir(p.join(root.path, 'run'));
    final leg = MatrixLeg.parse('globex:lt-ios')!;
    final handle = runner.start(leg, lane: p.join(root.path, 'gone'), run: run, base: const {});

    expect(await handle.exitCode, matrixStartFailedExitCode);
    expect(await handle.released, isFalse);
    expect(File(run.log(leg)).readAsStringSync(),
        contains('[matrix] could not start globex:lt-ios in ${p.join(root.path, 'gone')}: No such file or directory'));
  });

  test('stop completes the stop future the starter received', () async {
    late Future<void> stopped;
    final exit = Completer<int>();
    final runner = MatrixLegRunner(
      command: ['mplatrol'],
      ports: MatrixPorts(p.join(root.path, 'endpoints')),
      start: (executable, arguments,
          {required workingDirectory, required environment, required onLine, required stop}) {
        stopped = stop.then((_) => exit.complete(143));
        return exit.future;
      },
    );
    final handle = runner.start(MatrixLeg.parse('globex:lt-ios')!,
        lane: root.path, run: MatrixRunDir(p.join(root.path, 'run')), base: const {});

    handle
      ..stop()
      ..stop();

    await stopped;
    expect(await handle.exitCode, 143);
  });

  group('a local leg', () {
    late MatrixLocalDevices devices;
    late MatrixRunDir run;
    setUp(() {
      devices = MatrixLocalDevices(
          directory: p.join(root.path, 'local-devices'),
          logger: _MockLogger(),
          pollInterval: const Duration(milliseconds: 5));
      run = MatrixRunDir(p.join(root.path, 'round7'));
    });

    List<File> leases(String platform) => Directory(p.join(devices.directory, platform))
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.lease'))
        .toList();

    Future<void> logged(MatrixLeg leg, String text) async {
      while (!File(run.log(leg)).readAsStringSync().contains(text)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('runs mplatrol run <platform> holding its device, and keeps its lane until it exits', () async {
      final exit = Completer<int>();
      late List<String> started;
      late Map<String, String> env;
      final runner = MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        localDevices: devices,
        clock: () => DateTime(2026, 10, 5, 9),
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) {
          started = arguments;
          env = environment;
          File(p.join(environment[itLegDirEnv]!, itCheckoutReleasedMarker)).writeAsStringSync('');
          return exit.future;
        },
      );
      final leg = MatrixLeg.parse('initech:android')!;

      final handle = runner.start(leg, lane: '/w/lane1/app', run: run, base: const {});
      var released = false;
      handle.released.then((_) => released = true).ignore();
      while (leases('android').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(released, isFalse, reason: 'a local leg holds its lane until it exits');
      expect(started, [
        'run',
        'android',
        '--tenant=initech',
        '--environment=staging',
        '--junit=${run.junit(leg, DateTime(2026, 10, 5, 9))}'
      ]);
      expect(
          env,
          containsPair(
              'MPLATROL_E2E_CREDENTIALS_ENDPOINT_FILE', p.join(root.path, 'endpoints', 'initech_android.json')));
      expect(env, containsPair('MPLATROL_IT_LEG_DIR', run.legDir(leg)));
      expect(env, containsPair('MPLATROL_LOCAL_DEVICE_LEASE', 'android=${leases('android').single.path}'),
          reason: "the leg's mplatrol run uses the device the matrix leased instead of waiting for it");
      exit.complete(0);
      expect(await handle.exitCode, 0);
      expect(await handle.released, isFalse);
      expect(leases('android'), isEmpty);
    });

    test('waits for a device another process holds, logging the wait the stall cap skips', () async {
      final other =
          await devices.acquire(MatrixLeg.parse('globex:ios')!, report: (_) {}, cancel: Completer<void>().future);
      var starts = 0;
      final runner = MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        localDevices: devices,
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) async {
          starts++;
          return 0;
        },
      );
      final leg = MatrixLeg.parse('initech:ios')!;

      final handle = runner.start(leg, lane: root.path, run: run, base: const {});
      await logged(leg, '[local-device] initech:ios: waiting for 1 free local ios simulator');
      expect(starts, 0);
      await other.release();

      expect(await handle.exitCode, 0);
      expect(starts, 1);
      expect(File(run.log(leg)).readAsStringSync(),
          contains('[local-device] initech:ios: got 1 of 1 local ios simulator'));
      expect(File(run.times(leg)).readAsStringSync(), contains('waiting for 1 free local ios simulator'));
    });

    test('stopped while it waits for its device, it never starts and exits 143', () async {
      final other =
          await devices.acquire(MatrixLeg.parse('globex:android')!, report: (_) {}, cancel: Completer<void>().future);
      var starts = 0;
      final runner = MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        localDevices: devices,
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) async {
          starts++;
          return 0;
        },
      );
      final leg = MatrixLeg.parse('initech:android')!;
      final handle = runner.start(leg, lane: root.path, run: run, base: const {});
      await logged(leg, 'waiting for 1 free local android emulator');

      handle.stop();

      expect(await handle.exitCode, matrixStoppedExitCode);
      expect(await handle.released, isFalse);
      expect(starts, 0);
      expect(File(run.log(leg)).readAsStringSync(),
          contains('[local-device] initech:android: stopped while waiting for the local android device\nEXIT 143'));
      await other.release();
    });

    test('runs without a lease when there are no local device leases', () async {
      late Map<String, String> env;
      final runner = MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) async {
          env = environment;
          return 3;
        },
      );
      final handle = runner.start(MatrixLeg.parse('initech:ios')!, lane: root.path, run: run, base: const {});
      expect(await handle.exitCode, 3);
      expect(env, isNot(contains('MPLATROL_LOCAL_DEVICE_LEASE')));
      expect(Directory(devices.directory).existsSync(), isFalse);
    });
  });

  test('terminates a real process once stop completes', () async {
    final stop = Completer<void>();
    final lines = <String>[];
    final code = startMatrixProcess('/bin/sh', ['-c', 'echo up; sleep 3'],
        workingDirectory: root.path, environment: const {}, onLine: lines.add, stop: stop.future);
    while (lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stop.complete();
    expect(await code, isNegative);
  });

  test('starts real processes and streams both outputs', () async {
    final lines = <String>[];
    final code = await startMatrixProcess('/bin/sh', ['-c', r'echo "out $MATRIX_TEST"; echo err >&2; exit 3'],
        workingDirectory: root.path,
        environment: {'MATRIX_TEST': 'ok'},
        onLine: lines.add,
        stop: Completer<void>().future);
    expect(code, 3);
    expect(lines, unorderedEquals(['out ok', 'err']));
  });

  test('names the command that started this mplatrol', () {
    expect(currentMplatrolCommand(script: Uri.file('/cli/bin/mplatrol.dart'), executable: '/sdk/dart'),
        ['/sdk/dart', '/cli/bin/mplatrol.dart']);
    expect(
        currentMplatrolCommand(
            script: Uri.file('/cli/.dart_tool/pub/bin/mplatrol/mplatrol.dart-3.11.snapshot'), executable: '/sdk/dart'),
        ['/sdk/dart', '/cli/.dart_tool/pub/bin/mplatrol/mplatrol.dart-3.11.snapshot']);
    expect(currentMplatrolCommand(script: Uri.file('/cli/mplatrol.dill'), executable: '/sdk/dart').length, 2);
    expect(currentMplatrolCommand(script: Uri.file('/usr/local/bin/mplatrol'), executable: '/usr/local/bin/mplatrol'),
        ['/usr/local/bin/mplatrol']);
    expect(currentMplatrolCommand(), isNotEmpty);
  });
}
