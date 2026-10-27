import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late Directory home;
  late String slots;
  late _MockLogger logger;
  var now = DateTime(2026, 10, 3, 9);

  LtSlotBudget budget({int limit = 10, Duration heartbeat = const Duration(minutes: 1)}) => LtSlotBudget(
        directory: slots,
        limit: limit,
        logger: logger,
        heartbeat: heartbeat,
        pollInterval: const Duration(milliseconds: 5),
        clock: () => now,
      );

  List<File> leases() => Directory(slots).listSync().whereType<File>().where((f) => f.path.endsWith('.lease')).toList();

  setUp(() {
    home = Directory.systemTemp.createTempSync('mplatrol_lt_slots');
    slots = p.join(home.path, '.mplatrol', 'lt-slots');
    logger = _MockLogger();
    now = DateTime(2026, 10, 3, 9);
  });
  tearDown(() => home.deleteSync(recursive: true));

  group('fromEnvironment', () {
    test('defaults to 30 sessions under HOME/.mplatrol/lt-slots', () {
      final budget = LtSlotBudget.fromEnvironment({'HOME': home.path}, logger)!;
      expect(budget.limit, ltDefaultMaxConcurrentSessions);
      expect(budget.directory, slots);
    });

    test('reads the limit from the environment', () {
      expect(LtSlotBudget.fromEnvironment({'HOME': home.path, ltMaxConcurrentSessionsEnv: ' 12 '}, logger)!.limit, 12);
    });

    for (final value in ['0', '-3', 'many']) {
      test('refuses the limit "$value"', () {
        expect(
            () => LtSlotBudget.fromEnvironment({'HOME': home.path, ltMaxConcurrentSessionsEnv: value}, logger),
            throwsA(isA<FormatException>().having((e) => e.message, 'message',
                '$ltMaxConcurrentSessionsEnv must be a positive whole number of LambdaTest sessions (got "$value").')));
      });
    }

    test('passes the fair-share check to the budget', () {
      Future<int> check(int held) async => 3;
      expect(LtSlotBudget.fromEnvironment({'HOME': home.path}, logger, fairShare: check)!.fairShare, check);
    });

    test('has no budget without HOME', () {
      expect(LtSlotBudget.fromEnvironment(const {}, logger), isNull);
      verify(() => logger.detail(any(that: contains('no machine-wide session budget')))).called(1);
    });
  });

  test('grants what is free, records usage and frees the slots on release', () async {
    final first = await budget().acquire(wanted: 6, label: 'acme lt-ios wave 1');
    final second = await budget().acquire(wanted: 6, label: 'globex lt-android', minimum: 3);
    expect([first.slots, second.slots], [6, 4]);
    expect(leases(), hasLength(2));

    await second.release();
    await second.release();
    final third = await budget().acquire(wanted: 20, label: 'initech lt-ios');
    expect(third.slots, 4);
    await first.release();
    await third.release();

    expect(leases(), isEmpty);
    expect(File(p.join(slots, 'usage.log')).readAsLinesSync(), [
      '${now.toIso8601String()} grant 6 acme lt-ios wave 1 inUse=6/10',
      '${now.toIso8601String()} grant 4 globex lt-android inUse=10/10',
      '${now.toIso8601String()} release 4 globex lt-android inUse=6/10',
      '${now.toIso8601String()} grant 4 initech lt-ios inUse=10/10',
      '${now.toIso8601String()} release 6 acme lt-ios wave 1 inUse=4/10',
      '${now.toIso8601String()} release 4 initech lt-ios inUse=0/10',
    ]);
  });

  group('fair share', () {
    test('caps the grant at the share, re-checked at most once per minute, counting what we hold', () async {
      final asked = <int>[];
      var share = 4;
      final budget = LtSlotBudget(
          directory: slots,
          limit: 10,
          logger: logger,
          clock: () => now,
          pollInterval: const Duration(milliseconds: 5),
          fairShare: (held) async {
            asked.add(held);
            return share;
          });

      final first = await budget.acquire(wanted: 2, label: 'globex lt-ios');
      share = 9;
      final second = await budget.acquire(wanted: 6, label: 'globex lt-android');
      expect(second.slots, 2, reason: 'the share of 4 is not re-read within a minute');
      await second.release();
      now = now.add(const Duration(minutes: 1));
      final third = await budget.acquire(wanted: 8, label: 'acme lt-ios');
      expect(third.slots, 7);
      expect(asked, [0, 2]);
      await first.release();
      await third.release();
    });

    test('stops taking new sessions while the org is busy and waits, never taking back running ones', () async {
      var share = 2;
      final lines = <String>[];
      final budget = LtSlotBudget(
          directory: slots,
          limit: 10,
          logger: logger,
          clock: () => now,
          pollInterval: const Duration(milliseconds: 5),
          shareRecheck: Duration.zero,
          fairShare: (held) async => share);
      final held = await budget.acquire(wanted: 2, label: 'a');

      final waiting = budget.acquire(wanted: 1, label: 'b', report: lines.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      share = 0;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(held.slots, 2);
      share = 3;
      final granted = await waiting;

      expect(granted.slots, 1);
      expect(
          lines.first,
          '[lt-slots] b: waiting for 1 free LambdaTest session(s) of the machine-wide 2 '
          '($ltMaxConcurrentSessionsEnv) (the LambdaTest org fair share of the 10)');
      await held.release();
      await granted.release();
    });
  });

  test("reports each released lease's sessions and how long they were held", () async {
    final ended = <(int, Duration)>[];
    final budget = LtSlotBudget(
        directory: slots,
        limit: 10,
        logger: logger,
        clock: () => now,
        onLeaseEnded: (slots, held) => ended.add((slots, held)));
    final lease = await budget.acquire(wanted: 3, label: 'globex lt-ios');
    now = now.add(const Duration(minutes: 12));

    await lease.release();
    await lease.release();

    expect(ended, [(3, const Duration(minutes: 12))]);
  });

  test('an unbudgeted lease grants its slots and releases nothing', () async {
    final lease = LtSlotLease.unbudgeted(7);
    expect(lease.slots, 7);
    await lease.release();
    expect(Directory(slots).existsSync(), isFalse);
  });

  test('asks for at least one and at most the limit', () async {
    final none = await budget(limit: 4).acquire(wanted: 0, label: 'a');
    expect(none.slots, 1);
    await none.release();
    expect((await budget(limit: 4).acquire(wanted: 9, label: 'b', minimum: 9)).slots, 4);
  });

  test('waits until the minimum is free', () async {
    final held = await budget().acquire(wanted: 8, label: 'held');
    final waiting = budget().acquire(wanted: 5, label: 'waiter', minimum: 4);
    var granted = false;
    waiting.then((_) => granted = true).ignore();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(granted, isFalse);

    await held.release();
    expect((await waiting).slots, 5);
    verify(() => logger.info(any(that: contains('waiter: waiting for 4 free LambdaTest session(s)')))).called(1);
    verify(() => logger.info('[lt-slots] waiter: got 5 of 5 LambdaTest session(s) after waiting')).called(1);
  });

  test('words its lines as configured and reports waiting to the caller', () async {
    LtSlotBudget device() => LtSlotBudget(
        directory: slots,
        limit: 1,
        logger: logger,
        tag: 'local-device',
        unit: 'local android emulator',
        limitSource: '',
        pollInterval: const Duration(milliseconds: 5));
    final held = await device().acquire(wanted: 1, label: 'a:android');
    final lines = <String>[];
    final waiting = device().acquire(wanted: 1, label: 'b:android', report: lines.add);
    while (lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await held.release();
    await (await waiting).release();

    expect(lines, [
      '[local-device] b:android: waiting for 1 free local android emulator of the machine-wide 1',
      '[local-device] b:android: got 1 of 1 local android emulator after waiting',
    ]);
    verifyNever(() => logger.info(any()));
  });

  test('a waiter whose cancel completes leaves the queue without a lease', () async {
    final held = await budget(limit: 1).acquire(wanted: 1, label: 'held');
    final cancel = Completer<void>();
    final lines = <String>[];
    final waiting = budget(limit: 1).acquire(wanted: 1, label: 'waiter', report: lines.add, cancel: cancel.future);
    while (lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    cancel.complete();

    await expectLater(waiting,
        throwsA(isA<LtSlotWaitCancelled>().having((e) => '$e', 'text', 'LtSlotWaitCancelled: waiter stopped waiting')));
    expect(Directory(slots).listSync().where((f) => f.path.endsWith('.wait')), isEmpty);
    expect(leases(), hasLength(1));
    await held.release();
  });

  test('serves waiters first come, first served so a job asking again cannot jump the queue', () async {
    final held = await budget().acquire(wanted: 10, label: 'ios wave 1');
    final android = budget().acquire(wanted: 8, label: 'android', minimum: 8);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await held.release();
    final nextWave = budget().acquire(wanted: 4, label: 'ios wave 2', minimum: 4);
    var waveGranted = false;
    nextWave.then((_) => waveGranted = true).ignore();

    final androidLease = await android;
    expect(androidLease.slots, 8);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(waveGranted, isFalse, reason: 'only 2 sessions are free and the wave asked for 4');

    await androidLease.release();
    expect((await nextWave).slots, 4);
    expect(Directory(slots).listSync().where((f) => f.path.endsWith('.wait')), isEmpty);
  });

  test('orders tickets queued in the same microsecond by pid and sequence as numbers, not text', () async {
    // A larger pid whose text sorts first (e.g. 100000 before 40967) queued in the same microsecond is younger.
    final youngerPid = int.parse('1${'0' * '$pid'.length}');
    Directory(slots).createSync(recursive: true);
    File(p.join(slots, '$youngerPid-0-${now.microsecondsSinceEpoch}.wait'))
      ..writeAsStringSync('{"label":"younger","pid":$youngerPid}')
      ..setLastModifiedSync(now);

    final lease = await budget().acquire(wanted: 3, label: 'older').timeout(const Duration(seconds: 5));
    expect(lease.slots, 3);
  });

  test('a wait ticket whose process stopped refreshing it no longer blocks the queue', () async {
    Directory(slots).createSync(recursive: true);
    File(p.join(slots, '999-0-1.wait'))
      ..writeAsStringSync('{"label":"crashed","pid":999}')
      ..setLastModifiedSync(now);
    now = now.add(const Duration(minutes: 4));

    expect((await budget().acquire(wanted: 3, label: 'next')).slots, 3);
    expect(File(p.join(slots, '999-0-1.wait')).existsSync(), isFalse);
    verify(() => logger.detail(any(that: contains('dropping stale wait ticket')))).called(1);
  });

  test('a lease whose process stopped refreshing it no longer counts', () async {
    await budget().acquire(wanted: 10, label: 'crashed');
    now = now.add(const Duration(minutes: 4));

    expect((await budget().acquire(wanted: 10, label: 'next')).slots, 10);
    expect(leases(), hasLength(1));
    verify(() => logger.detail(any(that: contains('dropping stale lease')))).called(1);
  });

  test('a running lease refreshes itself so it never goes stale', () async {
    final lease = await budget(heartbeat: const Duration(milliseconds: 5)).acquire(wanted: 10, label: 'long job');
    now = now.add(const Duration(minutes: 4));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final waiter = budget().acquire(wanted: 1, label: 'other');
    var granted = false;
    waiter.then((_) => granted = true).ignore();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(granted, isFalse);
    await lease.release();
    expect((await waiter).slots, 1);
  });

  test('a lease removed under a running job only stops its heartbeat', () async {
    final lease = await budget(heartbeat: const Duration(milliseconds: 5)).acquire(wanted: 2, label: 'job');
    leases().single.deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await lease.release();
    verify(() => logger.detail(any(that: endsWith('is gone; no heartbeat')))).called(greaterThan(0));
  });

  test('breaks a lock left by a process that died holding it', () async {
    Directory(slots).createSync(recursive: true);
    File(p.join(slots, '.lock'))
      ..createSync()
      ..setLastModifiedSync(now.subtract(const Duration(minutes: 3)));

    expect((await budget().acquire(wanted: 2, label: 'a')).slots, 2);
    verify(() => logger.detail('[lt-slots] breaking a stale lock')).called(1);
  });

  test('a lock held for a minute by a stalled process is not broken', () async {
    Directory(slots).createSync(recursive: true);
    final lock = File(p.join(slots, '.lock'))..createSync();
    lock.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));
    final waiting = budget().acquire(wanted: 2, label: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    verifyNever(() => logger.detail('[lt-slots] breaking a stale lock'));
    lock.deleteSync();

    expect((await waiting).slots, 2);
  });

  test('waits for a lock another process holds', () async {
    Directory(slots).createSync(recursive: true);
    final lock = File(p.join(slots, '.lock'))..createSync();
    lock.setLastModifiedSync(now);
    final waiting = budget().acquire(wanted: 2, label: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    lock.deleteSync();

    expect((await waiting).slots, 2);
  });

  test('ignores unreadable leases and other files', () async {
    Directory(slots).createSync(recursive: true);
    File(p.join(slots, 'broken.lease'))
      ..writeAsStringSync('not json')
      ..setLastModifiedSync(now);
    File(p.join(slots, 'odd.lease'))
      ..writeAsStringSync('{"slots": "many"}')
      ..setLastModifiedSync(now);
    File(p.join(slots, 'notes.txt')).writeAsStringSync('x');

    expect((await budget(limit: 3).acquire(wanted: 3, label: 'a')).slots, 3);
  });

  group('shrinkTo', () {
    test('gives back the sessions beyond the new size', () async {
      final lease = await budget(limit: 6).acquire(wanted: 6, label: 'a');
      await lease.shrinkTo(2);
      expect(lease.slots, 2);
      final other = await budget(limit: 6).acquire(wanted: 6, label: 'b');
      expect(other.slots, 4);
      expect(File(p.join(slots, 'usage.log')).readAsStringSync(), contains('shrink 2 a inUse=2/6'));
      await lease.release();
      await other.release();
      expect(File(p.join(slots, 'usage.log')).readAsLinesSync().last, contains('release 4 b inUse=0/6'));
    });

    test('never grows a lease, and does nothing once released', () async {
      final lease = await budget().acquire(wanted: 3, label: 'a');
      await lease.shrinkTo(5);
      expect(lease.slots, 3);
      await lease.release();
      await lease.shrinkTo(1);
      expect(lease.slots, 3);
      expect(File(p.join(slots, 'usage.log')).readAsStringSync(), isNot(contains('shrink')));
    });

    test('shrinks an unbudgeted lease without any files', () async {
      final lease = LtSlotLease.unbudgeted(4);
      await lease.shrinkTo(-1);
      expect(lease.slots, 0);
      expect(Directory(slots).existsSync(), isFalse);
    });
  });

  test('a nested lease holds what both leases allow and releases both', () async {
    final outer = await budget(limit: 8).acquire(wanted: 8, label: 'outer');
    final nested = await LtSlotLease.nested(outer, LtSlotLease.unbudgeted(5));
    expect([nested.slots, outer.slots], [5, 5]);
    expect(nested.file, isNull);

    await nested.release();
    expect(leases(), isEmpty);
    expect(File(p.join(slots, 'usage.log')).readAsLinesSync().last, contains('release 5 outer inUse=0/8'));
  });
}
