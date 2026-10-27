import 'dart:async';
import 'dart:io';

import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_leg_runner.dart';
import 'package:mplatrol/src/matrix/matrix_scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late MatrixRunDir run;
  late Map<String, Completer<int>> exits;
  late List<String> events;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mplatrol_matrix_sched');
    run = MatrixRunDir(p.join(root.path, 'round7'));
    exits = {};
    events = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A runner whose legs free their checkout at once and exit when the test
  /// completes `exits[<leg key>]`.
  MatrixLegRunner runner({bool release = true}) => MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) {
          final key = p.basename(environment[itLegDirEnv]!);
          events.add('${laneName(workingDirectory)} $key');
          if (release) {
            File(p.join(environment[itLegDirEnv]!, itCheckoutReleasedMarker)).writeAsStringSync('');
          }
          return (exits[key] = Completer<int>()).future;
        },
      );

  List<MatrixLeg> legs(List<String> specs) => [for (final spec in specs) MatrixLeg.parse(spec)!];

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('a lane takes the next leg as soon as its leg freed the checkout', () async {
    final released = <String>[];
    final scheduler = MatrixScheduler(
      runner: runner(),
      run: run,
      minFreeGb: 25,
      freeGb: (_) async => 100,
      afterRelease: (lane) async => released.add(laneName(lane)),
      diskWait: const Duration(milliseconds: 2),
    );
    final all =
        scheduler.runAll(legs(['a:lt-ios', 'a:lt-android', 'b:lt-ios']), ['/w/lane1/app'], environment: const {});
    await settle();
    expect(events, ['lane1 a_lt-ios', 'lane1 a_lt-android', 'lane1 b_lt-ios']);
    expect(released, ['lane1', 'lane1', 'lane1']);

    exits['a_lt-ios']!.complete(70);
    exits['a_lt-android']!.complete(0);
    exits['b_lt-ios']!.complete(1);
    expect(await all, {'a_lt-ios': 70, 'a_lt-android': 0, 'b_lt-ios': 1});
    final queue = File(run.queueLog).readAsLinesSync().map((line) => line.substring(20)).toList();
    expect(queue.first, 'start lanes=(lane1) legs=3');
    expect(queue, containsAllInOrder(['lane1 start a:lt-ios', 'lane1 released a:lt-ios', 'lane1 start a:lt-android']));
    expect(queue, containsAll(['lane1 finish a:lt-ios exit 70', 'lane1 done', 'all lanes finished']));
  });

  test('a leg that never frees its checkout keeps its lane until it exits; a running leg is not started twice',
      () async {
    final scheduler = MatrixScheduler(
        runner: runner(release: false),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        diskWait: const Duration(milliseconds: 2));
    final all = scheduler.runAll(legs(['a:lt-ios', 'a:lt-ios']), ['/w/l1/app', '/w/l2/app'], environment: const {});
    await settle();
    expect(events, hasLength(1));
    exits['a_lt-ios']!.complete(0);
    await settle();
    expect(events, hasLength(2));
    exits['a_lt-ios']!.complete(0);
    await all;
  });

  /// Waits until [condition] holds, failing after a generous timeout instead of a fixed sleep.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out; events: $events');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  test('runs one local leg per platform at a time; the other platform and LambdaTest legs run meanwhile', () async {
    final scheduler = MatrixScheduler(
        runner: runner(), run: run, minFreeGb: 0, freeGb: (_) async => null, diskWait: const Duration(milliseconds: 2));
    final all = scheduler.runAll(
        legs(['a:ios', 'a:android', 'b:android', 'a:lt-android']), ['/w/l1/app', '/w/l2/app', '/w/l3/app'],
        environment: const {});
    await until(() => events.length == 3);
    expect(events, ['l1 a_ios', 'l2 a_android', 'l3 a_lt-android']);
    exits['a_lt-android']!.complete(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events, hasLength(3), reason: 'b:android waits for a:android, which still holds the emulator');

    exits['a_android']!.complete(1);
    await until(() => events.length == 4);
    expect(events.last, endsWith(' b_android'));
    exits['a_ios']!.complete(0);
    exits['b_android']!.complete(0);
    expect(await all, {'a_ios': 0, 'a_android': 1, 'b_android': 0, 'a_lt-android': 0});
    final queue = File(run.queueLog).readAsStringSync();
    expect(queue, isNot(contains('released a:android')), reason: 'a local leg frees its lane only by exiting');
    expect(queue, contains('l3 released a:lt-android'));
  });

  test('a lane waits while the disk is short', () async {
    var free = 10.0;
    final scheduler = MatrixScheduler(
        runner: runner(),
        run: run,
        minFreeGb: 25,
        freeGb: (_) async => free,
        diskWait: const Duration(milliseconds: 2));
    final all = scheduler.runAll(legs(['a:lt-ios']), ['/w/lane1/app'], environment: const {});
    await settle();
    expect(events, isEmpty);
    expect(File(run.queueLog).readAsStringSync(), contains('lane1 waiting: only 10 GB free (needs 25)'));
    free = 50;
    await settle();
    exits['a_lt-ios']!.complete(0);
    await all;
    expect(events, ['lane1 a_lt-ios']);
  });

  group('stall cap', () {
    test('is 75 minutes until three legs of the variant finished, then at most twice their median', () {
      const policy = MatrixStallPolicy();
      List<Duration> minutes(List<int> values) => [for (final value in values) Duration(minutes: value)];

      expect(policy.capFor(minutes([10, 10])), const Duration(minutes: 75));
      expect(policy.capFor(minutes([30, 10, 20])), const Duration(minutes: 40));
      expect(policy.capFor(minutes([10, 20, 30, 40])), const Duration(minutes: 50));
      expect(policy.capFor(minutes([50, 50, 60])), const Duration(minutes: 75));
    });

    test('never drops below 30 minutes, nor above the max when the max is lower', () {
      List<Duration> minutes(List<int> values) => [for (final value in values) Duration(minutes: value)];
      expect(const MatrixStallPolicy().capFor(minutes([1, 1, 2])), const Duration(minutes: 30));
      expect(const MatrixStallPolicy(maxLeg: Duration(minutes: 10)).capFor(minutes([1, 1, 1])),
          const Duration(minutes: 10));
    });

    /// A runner whose legs run until stopped, then exit 143.
    MatrixLegRunner stoppable() => MatrixLegRunner(
          command: ['mplatrol'],
          ports: MatrixPorts(p.join(root.path, 'endpoints')),
          start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) {
            events.add(p.basename(environment[itLegDirEnv]!));
            return stop.then((_) => 143);
          },
        );

    test('a lane whose checkout disappears mid-round stops; the other lanes run the remaining legs', () async {
      final kept = Directory(p.join(root.path, 'kept', 'app'))..createSync(recursive: true);
      final removed = Directory(p.join(root.path, 'removed', 'app'))..createSync(recursive: true);
      final scheduler = MatrixScheduler(
        runner: runner(release: false),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        diskWait: const Duration(milliseconds: 2),
      );
      final all = scheduler
          .runAll(legs(['a:lt-ios', 'b:lt-ios', 'c:lt-ios']), [removed.path, kept.path], environment: const {});
      await settle();
      removed.parent.deleteSync(recursive: true);
      exits['a_lt-ios']!.complete(0);
      await settle();
      exits['b_lt-ios']!.complete(0);
      await settle();
      exits['c_lt-ios']!.complete(0);

      expect((await all).keys, containsAll(['a_lt-ios', 'b_lt-ios', 'c_lt-ios']));
      expect(
          File(run.queueLog).readAsStringSync(), contains('removed stopped: its checkout ${removed.path} is missing'));
      expect(events, ['removed a_lt-ios', 'kept b_lt-ios', 'kept c_lt-ios']);
    });

    test('stops a leg over its cap, marks it stalled and lets the round finish', () async {
      var finished = 0;
      final scheduler = MatrixScheduler(
        runner: stoppable(),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(maxLeg: Duration(milliseconds: 40)),
        stallPoll: const Duration(milliseconds: 5),
        onLegFinished: () => finished++,
      );

      final exits = await scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios']), ['/w/lane1/app'], environment: const {});

      expect(exits, {'a_lt-ios': 143, 'b_lt-ios': 143});
      expect(finished, 2);
      expect(File(run.stalledMarker(legs(['a:lt-ios']).single)).readAsStringSync(), contains('over the 0 min cap'));
      final queue = File(run.queueLog).readAsStringSync();
      expect(queue, contains('stalled a:lt-ios: ran 0 min, over the 0 min cap; stopping it (lt-failure)'));
      expect(queue, contains('all lanes finished'));
    });

    test('keeps a cap per variant, so local leg times do not set the LambdaTest cap', () async {
      final scheduler = MatrixScheduler(
        runner: MatrixLegRunner(
          command: ['mplatrol'],
          ports: MatrixPorts(p.join(root.path, 'endpoints')),
          start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) {
            final key = p.basename(environment[itLegDirEnv]!);
            events.add(key);
            return key == 'a_lt-ios' ? Future.value(0) : stop.then((_) => 143);
          },
        ),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(
            maxLeg: Duration(hours: 1), minLeg: Duration.zero, minSamples: 1, idle: Duration.zero),
        stallPoll: const Duration(milliseconds: 5),
        diskWait: const Duration(milliseconds: 2),
      );
      final all = scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios', 'b:ios']), ['/w/l1/app', '/w/l2/app', '/w/l3/app'],
          environment: const {});

      await until(() => File(run.stalledMarker(legs(['b:lt-ios']).single)).existsSync());
      expect(File(run.stalledMarker(legs(['b:ios']).single)).existsSync(), isFalse,
          reason: 'no local ios leg finished, so b:ios has the 1 h cap');
      scheduler.abort('done');
      expect(await all, {'a_lt-ios': 0, 'b_lt-ios': 143, 'b_ios': 143});
      expect(File(run.queueLog).readAsStringSync(), contains('stopping it (lt-failure)'));
    });

    test('a leg over its median cap that is still writing its log runs on until the hard cap', () async {
      final writing = legs(['b:lt-ios']).single;
      Timer? writer;
      final scheduler = MatrixScheduler(
        runner: MatrixLegRunner(
          command: ['mplatrol'],
          ports: MatrixPorts(p.join(root.path, 'endpoints')),
          start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) {
            final key = p.basename(environment[itLegDirEnv]!);
            events.add(key);
            if (key == 'a_lt-ios') {
              return Future.value(0);
            }
            writer = Timer.periodic(const Duration(milliseconds: 3), (_) {
              File(run.log(writing)).writeAsStringSync('progress\n', mode: FileMode.append);
            });
            return stop.then((_) => 143);
          },
        ),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(
            maxLeg: Duration(milliseconds: 150),
            minLeg: Duration.zero,
            minSamples: 1,
            idle: Duration(milliseconds: 40)),
        stallPoll: const Duration(milliseconds: 5),
        diskWait: const Duration(milliseconds: 2),
      );
      final all = scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios']), ['/w/l1/app', '/w/l2/app'], environment: const {});

      await until(() => events.contains('b_lt-ios'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(File(run.stalledMarker(writing)).existsSync(), isFalse,
          reason: 'b:lt-ios is over the median cap but its log keeps growing');
      await until(() => File(run.stalledMarker(writing)).existsSync());
      writer?.cancel();
      expect(await all, {'a_lt-ios': 0, 'b_lt-ios': 143});
      expect(File(run.stalledMarker(writing)).readAsStringSync(), isNot(contains('no log output')));
    });

    test('a leg over its median cap whose log went quiet is stopped and says for how long', () async {
      final scheduler = MatrixScheduler(
        runner: MatrixLegRunner(
          command: ['mplatrol'],
          ports: MatrixPorts(p.join(root.path, 'endpoints')),
          start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) {
            final key = p.basename(environment[itLegDirEnv]!);
            events.add(key);
            return key == 'a_lt-ios' ? Future.value(0) : stop.then((_) => 143);
          },
        ),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(
            maxLeg: Duration(hours: 1), minLeg: Duration.zero, minSamples: 1, idle: Duration(milliseconds: 20)),
        stallPoll: const Duration(milliseconds: 5),
        diskWait: const Duration(milliseconds: 2),
      );
      final all = scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios']), ['/w/l1/app', '/w/l2/app'], environment: const {});

      final quiet = legs(['b:lt-ios']).single;
      await until(() => File(run.stalledMarker(quiet)).existsSync());
      expect(await all, {'a_lt-ios': 0, 'b_lt-ios': 143});
      expect(File(run.stalledMarker(quiet)).readAsStringSync(), contains('no log output for'));
    });

    test('a leg that stopped on an environment check (exit 69) does not set the cap for legs that are testing',
        () async {
      final scheduler = MatrixScheduler(
        runner: MatrixLegRunner(
          command: ['mplatrol'],
          ports: MatrixPorts(p.join(root.path, 'endpoints')),
          start: (executable, arguments,
              {required workingDirectory, required environment, required onLine, required stop}) {
            final key = p.basename(environment[itLegDirEnv]!);
            events.add(key);
            return key == 'a_lt-ios' ? Future.value(69) : stop.then((_) => 143);
          },
        ),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(
            maxLeg: Duration(hours: 1), minLeg: Duration.zero, minSamples: 1, idle: Duration.zero),
        stallPoll: const Duration(milliseconds: 5),
        diskWait: const Duration(milliseconds: 2),
      );
      final all = scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios']), ['/w/l1/app', '/w/l2/app'], environment: const {});

      await until(() => events.contains('b_lt-ios'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(File(run.stalledMarker(legs(['b:lt-ios']).single)).existsSync(), isFalse,
          reason: 'a:lt-ios exited 69 without testing, so b:lt-ios keeps the 1 h cap');
      scheduler.abort('done');
      expect(await all, {'a_lt-ios': 69, 'b_lt-ios': 143});
    });

    test('does not count time a local leg waits for its device; a stalled local leg is a device-failure', () async {
      final leg = legs(['a:android']).single;
      final scheduler = MatrixScheduler(
        runner: stoppable(),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(maxLeg: Duration(milliseconds: 60)),
        stallPoll: const Duration(milliseconds: 5),
      );
      final all = scheduler.runAll([leg], ['/w/lane1/app'], environment: const {});
      await until(() => File(run.log(leg)).existsSync());
      File(run.log(leg)).writeAsStringSync(
          '[local-device] a:android: waiting for 1 free local android emulator (mplatrol_e2e_pixel9) of the '
          'machine-wide 1\n',
          mode: FileMode.append);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(File(run.stalledMarker(leg)).existsSync(), isFalse, reason: 'waiting for the emulator, not stalled');

      File(run.log(leg)).writeAsStringSync(
          '[local-device] a:android: got 1 of 1 local android emulator after waiting\n',
          mode: FileMode.append);
      expect(await all, {'a_android': 143});
      expect(File(run.stalledMarker(leg)).readAsStringSync(), contains('waiting for the local android device'));
      expect(File(run.queueLog).readAsStringSync(), contains('; stopping it (device-failure)'));
    });

    test('an empty leg log is not a wait', () async {
      final leg = legs(['a:ios']).single;
      final scheduler = MatrixScheduler(
        runner: stoppable(),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(maxLeg: Duration(milliseconds: 30)),
        stallPoll: const Duration(milliseconds: 5),
      );
      final all = scheduler.runAll([leg], ['/w/lane1/app'], environment: const {});
      await until(() => File(run.log(leg)).existsSync());
      File(run.log(leg)).writeAsStringSync('\n');
      expect(await all, {'a_ios': 143});
    });

    test('does not count time a leg spends queued for LambdaTest sessions', () async {
      final leg = legs(['a:lt-android']).single;
      final scheduler = MatrixScheduler(
        runner: stoppable(),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(maxLeg: Duration(milliseconds: 60)),
        stallPoll: const Duration(milliseconds: 5),
      );
      final all = scheduler.runAll([leg], ['/w/lane1/app'], environment: const {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      File(run.log(leg)).writeAsStringSync(
          'Uploading app APK\n[lt-slots] job: waiting for 5 free LambdaTest '
          'session(s) of the machine-wide 15 (MPLATROL_LT_MAX_CONCURRENT_SESSIONS)\n',
          mode: FileMode.append);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(File(run.stalledMarker(leg)).existsSync(), isFalse, reason: 'queued, not stalled');

      File(run.log(leg))
          .writeAsStringSync('[lt-slots] job: got 5 of 5 session(s) after waiting\n', mode: FileMode.append);
      expect(await all, {'a_lt-android': 143});
      expect(File(run.stalledMarker(leg)).readAsStringSync(), contains('queued for LambdaTest sessions'));
    });

    test("does not count time a leg waits for its test users' session cap", () async {
      final leg = legs(['a:lt-ios']).single;
      final scheduler = MatrixScheduler(
        runner: stoppable(),
        run: run,
        minFreeGb: 0,
        freeGb: (_) async => null,
        stall: const MatrixStallPolicy(maxLeg: Duration(milliseconds: 60)),
        stallPoll: const Duration(milliseconds: 5),
      );
      final all = scheduler.runAll([leg], ['/w/lane1/app'], environment: const {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      File(run.log(leg)).writeAsStringSync(
          '[lt-user-cap] ios: waiting for 4 free device session(s) signing in as this test user pool of the '
          'machine-wide 4 (4 per verified user (MPLATROL_LT_SESSIONS_PER_USER) x 1 verified user(s))\n',
          mode: FileMode.append);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(File(run.stalledMarker(leg)).existsSync(), isFalse, reason: 'queued, not stalled');

      File(run.log(leg)).writeAsStringSync('[lt-user-cap] ios: got 4 of 4 after waiting\n', mode: FileMode.append);
      expect(await all, {'a_lt-ios': 143});
    });
  });

  test('abort stops the running legs and starts no more', () async {
    final scheduler = MatrixScheduler(
      runner: MatrixLegRunner(
        command: ['mplatrol'],
        ports: MatrixPorts(p.join(root.path, 'endpoints')),
        start: (executable, arguments,
            {required workingDirectory, required environment, required onLine, required stop}) {
          events.add(p.basename(environment[itLegDirEnv]!));
          return stop.then((_) => 143);
        },
      ),
      run: run,
      minFreeGb: 0,
      freeGb: (_) async => null,
      diskWait: const Duration(milliseconds: 2),
    );
    final all =
        scheduler.runAll(legs(['a:lt-ios', 'b:lt-ios', 'c:lt-ios']), ['/w/l1/app', '/w/l2/app'], environment: const {});
    await settle();

    scheduler.abort('received SIGTERM');

    expect(await all, {'a_lt-ios': 143, 'b_lt-ios': 143});
    expect(events, ['a_lt-ios', 'b_lt-ios']);
    expect(File(run.queueLog).readAsStringSync(),
        contains('abort: received SIGTERM; stopping 2 running legs, 1 not started'));
  });

  test('names a lane by its workspace', () {
    expect(laneName('/w/matrix-lane3/app/'), 'matrix-lane3');
    expect(laneName('/w/checkout'), 'checkout');
  });
}
