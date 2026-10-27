import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/lt_user_session_cap.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late Directory home;
  late _MockLogger logger;
  late List<LtUserLeg> legs;

  String userDir(String key) => p.join(home.path, '.mplatrol', 'lt-user-slots', key);

  /// A cap of [perUser] sessions per user for a pool of [users] whose primary is [primary]; every instance
  /// stands for a separate `mplatrol run` process sharing the lease files.
  LtUserSessionCap cap({String primary = 'u1', int users = 1, int perUser = 4}) => LtUserSessionCap(
        directory: userDir(primary),
        users: users,
        perUser: perUser,
        logger: logger,
        pollInterval: const Duration(milliseconds: 5),
      );

  /// A leg [label] present in [cap] (left again in tearDown).
  LtUserLeg join(LtUserSessionCap cap, String label) {
    final leg = cap.join(label);
    legs.add(leg);
    return leg;
  }

  Future<LtSlotLease> unbudgeted(int wanted, int minimum) async => LtSlotLease.unbudgeted(wanted);

  Future<LtSlotLease> lease(LtUserSessionCap cap, LtUserLeg leg, int wanted, String label,
          {int minimum = 5, Future<LtSlotLease> Function(int, int)? machine}) =>
      cap.lease(wanted: wanted, label: label, minimum: minimum, leg: leg, machine: machine ?? unbudgeted);

  List<String> usage(String key) => File(p.join(userDir(key), 'usage.log'))
      .readAsLinesSync()
      .map((line) => line.split(' ').skip(1).join(' '))
      .toList();

  String shareNote(int share, int cap, int live) => 'share $share of the test user cap of $cap ($live live LT '
      'leg(s) of this user; 4 per verified user x ${cap ~/ 4} verified user(s))';

  setUp(() {
    home = Directory.systemTemp.createTempSync('mplatrol_lt_user_cap');
    logger = _MockLogger();
    legs = [];
  });
  tearDown(() async {
    for (final leg in legs) {
      await leg.leave();
    }
    home.deleteSync(recursive: true);
  });

  group('fromEnvironment', () {
    Map<String, String> ambient([Map<String, String> extra = const {}]) => {'HOME': home.path, ...extra};

    for (final (keys, limit) in [('u1', 4), ('u1,u2', 8), ('u1,u2,u3', 12)]) {
      test('gives a pool of ${keys.split(',').length} verified user(s) $limit sessions', () {
        final cap = LtUserSessionCap.fromEnvironment(ambient(), {e2eUserKeysEnv: keys}, logger)!;
        expect(cap.budget.limit, limit);
        expect(cap.users, keys.split(',').length);
        expect(cap.perUser, ltDefaultSessionsPerUser);
        expect(cap.directory, userDir('u1'));
        expect(cap.budget.tag, 'lt-user-cap');
      });
    }

    test('reads the sessions per user from the environment', () {
      final cap = LtUserSessionCap.fromEnvironment(
          ambient({ltSessionsPerUserEnv: ' 2 '}), {e2eUserKeysEnv: 'u1,u2,u3'}, logger)!;
      expect(cap.budget.limit, 6);
      expect(cap.budget.limitSource, ' (2 per verified user ($ltSessionsPerUserEnv) x 3 verified user(s))');
    });

    for (final value in ['0', '-1', 'four']) {
      test('refuses the per-user limit "$value"', () {
        expect(
            () => LtUserSessionCap.fromEnvironment(
                ambient({ltSessionsPerUserEnv: value}), {e2eUserKeysEnv: 'u1'}, logger),
            throwsA(isA<FormatException>().having(
                (e) => e.message,
                'message',
                '$ltSessionsPerUserEnv must be a positive whole number of LambdaTest sessions per test '
                    'user (got "$value").')));
      });
    }

    test('counts each user once, ignores blanks and keeps keys path-safe', () {
      final cap = LtUserSessionCap.fromEnvironment(ambient(), {e2eUserKeysEnv: ' ../x , u2,,u2 '}, logger)!;
      expect(cap.users, 2);
      expect(cap.directory, userDir('.._x'));
    });

    test('has no cap without a verified user pool', () {
      expect(LtUserSessionCap.fromEnvironment(ambient(), const {}, logger), isNull);
      expect(LtUserSessionCap.fromEnvironment(ambient(), const {e2eUserKeysEnv: ' , '}, logger), isNull);
      verify(() => logger.detail('[lt-user-cap] no verified user pool, so no per-user session cap')).called(2);
    });

    test('has no cap without a HOME', () {
      expect(LtUserSessionCap.fromEnvironment(const {}, const {e2eUserKeysEnv: 'u1'}, logger), isNull);
      verify(() => logger.detail('[lt-user-cap] no HOME, so no per-user session cap')).called(1);
    });
  });

  group('lease', () {
    test('a leg alone gets the whole cap and logs its share', () async {
      final users = cap();
      final android = await lease(users, join(users, 'tenant:lt-android'), 10, 'android');
      expect(android.slots, 4);
      verify(() => logger.info('[lt-user-cap] android: 4 of 10 device session(s), ${shareNote(4, 4, 1)}')).called(1);
      await android.release();
      expect(usage('u1'), ['grant 4 android inUse=4/4', 'release 4 android inUse=0/4']);
    });

    test('scales with the pool: three users give twelve sessions', () async {
      final users = cap(users: 3);
      final android = await lease(users, join(users, 'tenant:lt-android'), 20, 'android');
      expect(android.slots, 12);
      await android.release();
    });

    test('two live legs with work get 2 + 2 at once, neither waiting for the other', () async {
      final (androidCap, iosCap) = (cap(), cap());
      final (androidLeg, iosLeg) = (join(androidCap, 'tenant:lt-android'), join(iosCap, 'tenant:lt-ios'));
      final android = await lease(androidCap, androidLeg, 10, 'android');
      final ios = await lease(iosCap, iosLeg, 10, 'ios');
      expect([android.slots, ios.slots], [2, 2]);
      verify(() => logger.info('[lt-user-cap] ios: 2 of 10 device session(s), ${shareNote(2, 4, 2)}')).called(1);
      verifyNever(() => logger.info(any(that: contains('waiting for'))));
      await android.release();
      await ios.release();
    });

    test('a leg that is still building is counted and lends nothing', () async {
      final (androidCap, iosCap) = (cap(), cap());
      join(iosCap, 'tenant:lt-ios');
      final android = await lease(androidCap, join(androidCap, 'tenant:lt-android'), 10, 'android');
      expect(android.slots, 2);
      verifyNever(() => logger.info(any(that: contains('borrowed'))));
      await android.release();
    });

    test('the share grows to the whole cap once the other leg ends', () async {
      final (androidCap, iosCap) = (cap(), cap());
      final androidLeg = join(androidCap, 'tenant:lt-android');
      final iosLeg = join(iosCap, 'tenant:lt-ios');
      final first = await lease(androidCap, androidLeg, 4, 'android');
      expect(first.slots, 2);
      await first.release();
      await iosLeg.leave();

      final next = await lease(androidCap, androidLeg, 4, 'android_wave2');
      expect(next.slots, 4);
      verify(() => logger.info('[lt-user-cap] android_wave2: 4 of 4 device session(s), ${shareNote(4, 4, 1)}'))
          .called(1);
      await next.release();
    });

    test('the presence of a leg that died stops counting', () async {
      Directory(userDir('u1')).createSync(recursive: true);
      final dead = File(p.join(userDir('u1'), '999999-0-1.leg'))
        ..writeAsStringSync(jsonEncode({'pid': 999999, 'label': 'tenant:lt-ios'}))
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 10)));
      File(p.join(userDir('u1'), 'notes.txt')).writeAsStringSync('x');

      final users = cap();
      final android = await lease(users, join(users, 'tenant:lt-android'), 4, 'android');
      expect(android.slots, 4);
      expect(dead.existsSync(), isFalse);
      verify(() => logger.detail('[lt-user-cap] dropping stale leg 999999-0-1.leg')).called(1);
      await android.release();
    });

    test('an unreadable presence file still counts as a building leg', () async {
      Directory(userDir('u1')).createSync(recursive: true);
      File(p.join(userDir('u1'), '999999-0-1.leg')).writeAsStringSync('{');

      final users = cap();
      final android = await lease(users, join(users, 'tenant:lt-android'), 4, 'android');
      expect(android.slots, 2);
      await android.release();
    });

    test('a leg borrows the sessions another leg leaves idle and returns them to it once it waits', () async {
      final (androidCap, iosCap) = (cap(), cap());
      final androidLeg = join(androidCap, 'tenant:lt-android');
      final iosLeg = join(iosCap, 'tenant:lt-ios');
      await (await lease(iosCap, iosLeg, 2, 'ios_wave1')).release();

      final borrowed = await lease(androidCap, androidLeg, 4, 'android', minimum: 1);
      expect(borrowed.slots, 4);
      verify(() => logger.info('[lt-user-cap] android: 4 of 4 device session(s), ${shareNote(2, 4, 2)}, '
          'borrowed 2 idle session(s) from tenant:lt-ios')).called(1);

      final iosWave = lease(iosCap, iosLeg, 2, 'ios_wave2', minimum: 1);
      final androidNext = lease(androidCap, androidLeg, 4, 'android_2', minimum: 1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await borrowed.release();
      final granted = await Future.wait([iosWave, androidNext]);
      expect(granted.map((lease) => lease.slots), [2, 2], reason: 'the waiting iOS leg gets its share back');
      for (final lease in granted) {
        await lease.release();
      }
    });

    test('an uneven cap: the share is the floor, and what no share covers goes to whoever asks', () async {
      final (androidCap, iosCap) = (cap(perUser: 5), cap(perUser: 5));
      final androidLeg = join(androidCap, 'tenant:lt-android');
      final iosLeg = join(iosCap, 'tenant:lt-ios');
      final android = await lease(androidCap, androidLeg, 9, 'android');
      final ios = await lease(iosCap, iosLeg, 9, 'ios');
      expect([android.slots, ios.slots], [3, 2]);
      expect(usage('u1').last, 'grant 2 ios inUse=5/5');
      await android.release();
      await ios.release();
    });

    test('legs of other users do not share the cap', () async {
      final (a, b) = (cap(primary: 'tenant-a'), cap(primary: 'tenant-b'));
      final first = await lease(a, join(a, 'a:lt-ios'), 4, 'a');
      final second = await lease(b, join(b, 'b:lt-ios'), 4, 'b');
      expect([first.slots, second.slots], [4, 4]);
      await first.release();
      await second.release();
    });

    test('waits for the cap instead of failing, then runs on what is free', () async {
      final users = cap();
      final leg = join(users, 'tenant:lt-android');
      final held = await lease(users, leg, 4, 'android');
      final waiting = lease(users, leg, 4, 'android_2', minimum: 1);
      var granted = false;
      waiting.then((_) => granted = true).ignore();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(granted, isFalse);

      await held.release();
      final next = await waiting;
      expect(next.slots, 4);
      verify(() => logger.info(any(that: startsWith('[lt-user-cap] android_2: waiting for 1 free')))).called(1);
      await next.release();
    });

    test('a share below the minimum grant waits for the share, not more', () async {
      final users = cap();
      final leg = join(users, 'tenant:lt-android');
      final held = await lease(users, leg, 1, 'held', minimum: 1);
      final waiting = lease(users, leg, 10, 'android');
      var granted = false;
      waiting.then((_) => granted = true).ignore();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(granted, isFalse, reason: '3 free of a cap of 4 is below the floor of min(5, 4)');

      await held.release();
      final next = await waiting;
      expect(next.slots, 4);
      await next.release();
    });

    test('a lease of a process that died stops counting', () async {
      Directory(userDir('u1')).createSync(recursive: true);
      File(p.join(userDir('u1'), '999999-0-1.lease'))
        ..writeAsStringSync(jsonEncode({'slots': 4, 'label': 'dead', 'pid': 999999, 'owner': 'gone'}))
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 10)));

      final users = cap();
      final android = await lease(users, join(users, 'tenant:lt-android'), 4, 'android', minimum: 4);
      expect(android.slots, 4);
      expect(File(p.join(userDir('u1'), '999999-0-1.lease')).existsSync(), isFalse);
      await android.release();
    });

    test('a lease without an owner counts toward the cap', () async {
      final users = cap();
      final legacy = await users.budget.acquire(wanted: 3, label: 'older-cli');
      final android = await lease(users, join(users, 'tenant:lt-android'), 4, 'android', minimum: 1);
      expect(android.slots, 1);
      await legacy.release();
      await android.release();
    });

    test('asks the machine-wide budget for what the cap granted and gives back what it did not', () async {
      final machine = LtSlotBudget(directory: p.join(home.path, 'lt-slots'), limit: 3, logger: logger);
      final asked = <(int, int)>[];
      Future<LtSlotLease> fromMachine(int wanted, int minimum) {
        asked.add((wanted, minimum));
        return machine.acquire(wanted: wanted, label: 'android', minimum: minimum);
      }

      final users = cap();
      final leg = join(users, 'tenant:lt-android');
      final android = await lease(users, leg, 10, 'android', machine: fromMachine);
      expect(asked, [(4, 4)]);
      expect(android.slots, 3);
      final other = await lease(users, leg, 4, 'android_2', minimum: 1);
      expect(other.slots, 1, reason: 'the session the machine-wide budget did not grant is free again');

      await android.release();
      await other.release();
      expect(usage('u1'), [
        'grant 4 android inUse=4/4',
        'shrink 3 android inUse=3/4',
        'grant 1 android_2 inUse=4/4',
        'release 3 android inUse=1/4',
        'release 1 android_2 inUse=0/4',
      ]);
      expect(
          File(p.join(home.path, 'lt-slots', 'usage.log')).readAsStringSync(), contains('release 3 android inUse=0/3'));
    });

    test('returns the per-user sessions when the machine-wide lease fails', () async {
      Future<LtSlotLease> failing(int wanted, int minimum) => Future.error(const LtSlotWaitCancelled('android'));

      final users = cap();
      await expectLater(lease(users, join(users, 'tenant:lt-android'), 4, 'android', machine: failing),
          throwsA(isA<LtSlotWaitCancelled>()));
      expect(usage('u1'), ['grant 4 android inUse=4/4', 'release 4 android inUse=0/4']);
    });

    test('a wait that is cancelled (the run is stopping) ends without a lease', () async {
      final users = cap();
      final leg = join(users, 'tenant:lt-android');
      final held = await lease(users, leg, 4, 'android');
      final cancel = Completer<void>();
      final waiting =
          users.lease(wanted: 4, label: 'android_2', minimum: 1, leg: leg, machine: unbudgeted, cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.complete();

      await expectLater(waiting, throwsA(isA<LtSlotWaitCancelled>()));
      await held.release();
    });

    test('a leg that left removes its presence', () async {
      final users = cap();
      final leg = users.join('tenant:lt-ios');
      expect(Directory(userDir('u1')).listSync().map((f) => p.extension(f.path)), ['.leg']);
      await leg.leave();
      expect(Directory(userDir('u1')).listSync(), isEmpty);
    });

    test('a present leg keeps its presence fresh', () async {
      final users = LtUserSessionCap(
          directory: userDir('u1'), users: 1, perUser: 4, logger: logger, heartbeat: const Duration(milliseconds: 5));
      final leg = join(users, 'tenant:lt-ios');
      final file = Directory(userDir('u1')).listSync().whereType<File>().single..setLastModifiedSync(DateTime(2020));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(file.statSync().modified.isAfter(DateTime(2021)), isTrue);
      file.deleteSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      verify(() => logger.detail('[lt-user-cap] ${p.basename(file.path)} is gone; no heartbeat'))
          .called(greaterThan(0));
      expect(leg.owner, p.basenameWithoutExtension(file.path));
    });
  });
}
