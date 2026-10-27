import 'dart:io';

import 'package:path/path.dart' as p;

/// How long a session that stopped asking keeps its user: longer than one test
/// takes, so a running test never loses its user to a newer session.
const e2eUserLeaseIdle = Duration(minutes: 20);

/// Hands each parallel device session its own test user, so sessions do not
/// sign in as the same user at once (many backends bounce simultaneous sign-ins of
/// one user after the one-time code).
///
/// [users] are stable keys of the logins (index 0 is the run's primary). A
/// session (`holder`) keeps the user it got until it [release]s it, or stops
/// asking for [idle] when it died without saying so; a new session gets the
/// user with the fewest live sessions, the lowest index on a tie, so sessions
/// share a user only when there are more sessions than users.
///
/// With a [directory], sessions are leases in it (`<user>~<holder>.lease`,
/// refreshed on every request, stale after [idle]), so every run on this
/// machine counts the others' sessions: a tenant's Android and iOS legs then
/// spread over its users too. Without one, only this run's sessions count.
class E2eUserPool {
  /// Creates a pool of [users]; [clock] is injectable for tests.
  E2eUserPool(this.users, {this.directory, DateTime Function()? clock, this.idle = e2eUserLeaseIdle})
      : assert(users.isNotEmpty, 'a pool needs the primary user'),
        _clock = clock ?? DateTime.now;

  /// Stable keys of the logins the pool hands out.
  final List<String> users;

  /// Where the machine-wide session leases live; null keeps them in this run.
  final String? directory;

  /// How long a holder keeps its user without asking again.
  final Duration idle;

  final DateTime Function() _clock;
  final _leases = <String, ({int user, DateTime seen})>{};

  /// The user index [holder] signs in as: the one it already has, else the
  /// least used one.
  int assign(String holder) {
    final now = _clock();
    _leases.removeWhere((_, lease) => now.difference(lease.seen) > idle);
    final counts = List<int>.filled(users.length, 0);
    if (directory == null) {
      for (final lease in _leases.values) {
        counts[lease.user]++;
      }
    } else {
      // The shared leases include this run's own.
      for (final (user, owner) in _sharedLeases(now)) {
        if (owner != _safe(holder) && user >= 0) {
          counts[user]++;
        }
      }
    }
    final mine = _leases[holder]?.user;
    final user = mine ?? _leastUsed(counts);
    _leases[holder] = (user: user, seen: now);
    _touchShared(user, holder, now);
    return user;
  }

  /// The user index [holder] was assigned, or 0 (the primary) when it has none.
  int userOf(String holder) => _leases[holder]?.user ?? 0;

  /// Frees [holder]'s user at once, for a session that says it finished, so
  /// only live sessions count towards the next [assign]; [idle] stays the
  /// fallback for sessions that die. Returns whether [holder] had a user.
  bool release(String holder) {
    final lease = _leases.remove(holder);
    if (lease == null) {
      return false;
    }
    final dir = directory;
    if (dir != null) {
      try {
        File(_leasePath(dir, lease.user, holder)).deleteSync();
      } on PathNotFoundException {
        // Another run's stale-lease cleanup removed it first: the user is free either way.
      }
    }
    return true;
  }

  int _leastUsed(List<int> counts) {
    var best = 0;
    for (var user = 1; user < counts.length; user++) {
      if (counts[user] < counts[best]) {
        best = user;
      }
    }
    return best;
  }

  /// The live machine-wide leases as (user index, holder); stale ones are
  /// removed, and leases of users this pool does not know count as -1.
  List<(int, String)> _sharedLeases(DateTime now) {
    final dir = directory;
    if (dir == null || !Directory(dir).existsSync()) {
      return const [];
    }
    final leases = <(int, String)>[];
    for (final file in Directory(dir).listSync().whereType<File>()) {
      final name = p.basenameWithoutExtension(file.path);
      if (!file.path.endsWith('.lease') || !name.contains('~')) {
        continue;
      }
      try {
        if (now.difference(file.statSync().modified) > idle) {
          file.deleteSync();
          continue;
        }
        // Only another run removing the lease meanwhile reaches this.
        // coverage:ignore-start
      } on FileSystemException {
        continue;
      }
      // coverage:ignore-end
      final separator = name.indexOf('~');
      leases.add((users.indexOf(name.substring(0, separator)), name.substring(separator + 1)));
    }
    return leases;
  }

  String _safe(String holder) => holder.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');

  void _touchShared(int user, String holder, DateTime now) {
    final dir = directory;
    if (dir == null) {
      return;
    }
    Directory(dir).createSync(recursive: true);
    File(_leasePath(dir, user, holder))
      ..writeAsStringSync('')
      ..setLastModifiedSync(now);
  }

  String _leasePath(String dir, int user, String holder) => p.join(dir, '${users[user]}~${_safe(holder)}.lease');
}
