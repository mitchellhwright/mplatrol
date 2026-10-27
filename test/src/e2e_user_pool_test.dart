import 'dart:io';

import 'package:mplatrol/src/e2e_user_pool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  var now = DateTime(2026, 10, 3, 9);
  E2eUserPool pool(List<String> users, {String? directory}) =>
      E2eUserPool(users, directory: directory, clock: () => now);

  setUp(() => now = DateTime(2026, 10, 3, 9));

  test('spreads sessions over the users and keeps each on its user', () {
    final users = pool(['u0', 'u1', 'u2']);
    expect([
      for (final holder in ['a', 'b', 'c', 'd', 'e']) users.assign(holder)
    ], [
      0,
      1,
      2,
      0,
      1
    ]);
    expect(users.assign('c'), 2);
    expect(users.userOf('e'), 1);
    expect(users.userOf('unknown'), 0);
  });

  test('a session that stopped asking gives its user back', () {
    final users = pool(['u0', 'u1']);
    expect(users.assign('a'), 0);
    expect(users.assign('b'), 1);
    now = now.add(const Duration(minutes: 15));
    users.assign('a');
    now = now.add(const Duration(minutes: 10));
    expect(users.assign('c'), 1);
    expect(users.userOf('b'), 0);
  });

  test('a session that ended gives its user back at once, so only live sessions count', () {
    final users = pool(['u0', 'u1']);
    expect([users.assign('a'), users.assign('b'), users.assign('c')], [0, 1, 0]);
    expect(users.release('a'), isTrue);
    expect(users.release('a'), isFalse);
    expect(users.userOf('a'), 0);
    expect(users.assign('d'), 0, reason: 'u0 has one live session (c), as many as u1');
    expect(users.release('b'), isTrue);
    expect(users.assign('e'), 1);
  });

  test('an unknown session ends without freeing anyone', () {
    final users = pool(['u0', 'u1']);
    expect(users.assign('a'), 0);
    expect(users.release('never-seen'), isFalse);
    expect(users.assign('b'), 1);
  });

  test('a session that never says it ended still gives its user back after the idle time', () {
    final users = pool(['u0', 'u1']);
    expect([users.assign('a'), users.assign('b')], [0, 1]);
    users.release('b');
    now = now.add(e2eUserLeaseIdle + const Duration(seconds: 1));
    expect([users.assign('c'), users.assign('d')], [0, 1]);
  });

  group('shared by the runs on the machine', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mplatrol_users'));
    tearDown(() => dir.deleteSync(recursive: true));

    test("another run's sessions count, so the two runs use different users", () {
      final ios = pool(['primary', 'second'], directory: dir.path);
      final android = pool(['primary', 'second'], directory: dir.path);

      expect(ios.assign('ios-1'), 0);
      expect(android.assign('android-1'), 1);
      expect(ios.assign('ios-2'), 0);
      expect(android.assign('android-1'), 1);
      expect(Directory(dir.path).listSync().map((f) => p.basename(f.path)).toSet(),
          {'primary~ios-1.lease', 'second~android-1.lease', 'primary~ios-2.lease'});
    });

    test('stale leases and other files no longer count; unknown users are ignored', () {
      File(p.join(dir.path, 'other~x.lease')).writeAsStringSync('');
      File(p.join(dir.path, 'notes.txt')).writeAsStringSync('');
      File(p.join(dir.path, 'primary~gone.lease'))
        ..writeAsStringSync('')
        ..setLastModifiedSync(now.subtract(const Duration(hours: 1)));

      expect(pool(['primary', 'second'], directory: dir.path).assign('weird holder/1'), 0);
      expect(File(p.join(dir.path, 'primary~gone.lease')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'primary~weird_holder_1.lease')).existsSync(), isTrue);
    });

    test("an ended session's lease is removed, so the other runs stop counting it", () {
      final ios = pool(['primary', 'second'], directory: dir.path);
      final android = pool(['primary', 'second'], directory: dir.path);
      expect(ios.assign('ios-1'), 0);
      expect(android.assign('android-1'), 1);

      expect(android.release('android-1'), isTrue);

      expect(File(p.join(dir.path, 'second~android-1.lease')).existsSync(), isFalse);
      expect(ios.assign('ios-2'), 1);
    });

    test('a lease another run already removed still ends the session', () {
      final users = pool(['primary', 'second'], directory: dir.path);
      expect(users.assign('a/1'), 0);
      File(p.join(dir.path, 'primary~a_1.lease')).deleteSync();
      expect(users.release('a/1'), isTrue);
      expect(users.assign('b'), 0);
    });

    test('a missing directory is created on first use', () {
      final nested = p.join(dir.path, 'e2e-users');
      expect(pool(['primary'], directory: nested).assign('a'), 0);
      expect(Directory(nested).existsSync(), isTrue);
    });
  });
}
