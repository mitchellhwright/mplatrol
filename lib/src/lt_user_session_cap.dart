import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:path/path.dart' as p;

/// Env var: the most LambdaTest device sessions that sign in as one test user at once,
/// across every `mplatrol run` on this machine (see [LtUserSessionCap]).
const ltSessionsPerUserEnv = 'MPLATROL_LT_SESSIONS_PER_USER';

/// Default [ltSessionsPerUserEnv]. Many backends drop overlapping sign-ins of one user, so devices take turns
/// through its sign-in slot (about 20-30 s each) and give up after 90 s: one user serves about 3-4 devices.
const ltDefaultSessionsPerUser = 4;

/// Env var the credential server sets for the legs it serves: the secret-free keys of the verified users
/// its device sessions sign in as, comma-separated, the run's own user first.
const e2eUserKeysEnv = 'MPLATROL_E2E_USER_KEYS';

/// One LambdaTest leg present in an [LtUserSessionCap] from [LtUserSessionCap.join] until [leave].
class LtUserLeg {
  LtUserLeg._(this.owner, this.label, this._file, this._heartbeat);

  static String _content(String label, {required bool leasing}) =>
      jsonEncode({'pid': pid, 'label': label, if (leasing) 'leasing': true});

  /// The leg's id in the lease files.
  final String owner;

  /// The leg as other legs' log lines name it, e.g. `umbrella:lt-ios`.
  final String label;
  final File _file;
  final Timer _heartbeat;
  var _leasing = false;

  /// Records that the leg leases sessions from now on (it finished building), so its unused share may be lent.
  void _startLeasing() {
    if (!_leasing) {
      _leasing = true;
      _file.writeAsStringSync(_content(label, leasing: true));
    }
  }

  /// Ends the leg's presence, so the other legs' shares grow again; later calls do nothing.
  Future<void> leave() async {
    _heartbeat.cancel();
    try {
      _file.deleteSync();
      // Only a second leave, or stale reclaim by another process, reaches this.
      // coverage:ignore-start
    } on FileSystemException {
      return;
    }
    // coverage:ignore-end
  }
}

/// Caps the LambdaTest device sessions that sign in as one tenant's test user pool: [perUser] sessions per
/// verified user, so the tenant gets `perUser × users` sessions and more as more users are verified.
///
/// The cap is an [LtSlotBudget] in [directory], keyed by the pool's primary user, so a tenant's iOS and Android
/// legs (separate processes, or one `lt-all` run, signing in as the same users) share it and other tenants do not.
/// A leg leases from it before the machine-wide budget (see [lease]); a leg that gets fewer sessions than it
/// wants runs its tests on fewer devices, and one that gets none waits.
///
/// HyperExecute fixes a job's sessions when it starts, so every lease (each Android job, iOS wave and retry)
/// is decided by this rule, from the legs present right then ([join], from before the build until the leg
/// ends; a leg that died stops counting after [staleAfter]):
///
/// * share = `max(1, cap ~/ live legs)`; a leg alone has the whole cap, and a leg's share grows as soon as
///   the other leg ends or dies.
/// * A leg that waits, or still builds, is owed its share: the sessions it is short of it are kept free.
/// * Otherwise a leg may take every free session, also those a leg that already leases leaves unused (between
///   waves, or done with its jobs); the log line names them as borrowed. A building leg lends nothing: an
///   Android job holds its sessions until it ends, so a share lent while iOS builds would make iOS wait for
///   the whole job instead of both platforms running at the same time.
/// * A job waits for at most its share (`min(5, share, wanted)`), and the cap is the hard ceiling.
class LtUserSessionCap {
  /// Creates a cap of [perUser] sessions for each of [users] verified users, leased in [directory].
  LtUserSessionCap({
    required this.directory,
    required this.users,
    required this.perUser,
    required MplatrolLogger logger,
    this.heartbeat = const Duration(seconds: 30),
    this.staleAfter = const Duration(minutes: 3),
    Duration pollInterval = const Duration(seconds: 15),
  })  : _logger = logger,
        _pollInterval = pollInterval;

  /// The cap for the pool [run] names in [e2eUserKeysEnv]: [ltSessionsPerUserEnv] of [ambient] (default
  /// [ltDefaultSessionsPerUser]) per user, leased under `$HOME/.mplatrol/lt-user-slots/<user>`.
  /// Null without a pool (no credential server, so no sign-ins) or without a `HOME`.
  ///
  /// Throws a [FormatException] when the per-user limit is not a positive whole number.
  static LtUserSessionCap? fromEnvironment(
      Map<String, String> ambient, Map<String, String> run, MplatrolLogger logger) {
    final raw = (ambient[ltSessionsPerUserEnv] ?? '').trim();
    final perUser = raw.isEmpty ? ltDefaultSessionsPerUser : int.tryParse(raw);
    if (perUser == null || perUser < 1) {
      throw FormatException('$ltSessionsPerUserEnv must be a positive whole number of LambdaTest sessions per '
          'test user (got "$raw").');
    }
    final keys = {
      for (final key in (run[e2eUserKeysEnv] ?? '').split(','))
        if (key.trim().isNotEmpty) key.trim().replaceAll(RegExp('[^A-Za-z0-9._-]'), '_'),
    };
    final home = (ambient['HOME'] ?? '').trim();
    if (keys.isEmpty || home.isEmpty) {
      logger.detail('[lt-user-cap] ${keys.isEmpty ? 'no verified user pool' : 'no HOME'}, so no per-user session cap');
      return null;
    }
    return LtUserSessionCap(
      directory: p.join(home, '.mplatrol', 'lt-user-slots', keys.first),
      users: keys.length,
      perUser: perUser,
      logger: logger,
    );
  }

  /// Where the leases, wait tickets and `.leg` presence files of this pool live.
  final String directory;

  /// Verified users in the pool.
  final int users;

  /// Sessions each verified user may serve at once.
  final int perUser;

  /// How often a present leg refreshes its presence file.
  final Duration heartbeat;

  /// How long a presence file outlives the leg that stopped refreshing it.
  final Duration staleAfter;
  final MplatrolLogger _logger;
  final Duration _pollInterval;
  static var _sequence = 0;

  /// The leases of this pool's sessions, limited by [_rule].
  late final budget = LtSlotBudget(
    directory: directory,
    limit: perUser * users,
    logger: _logger,
    tag: 'lt-user-cap',
    unit: 'device session(s) signing in as this test user pool',
    limitSource: ' ($perUser per verified user ($ltSessionsPerUserEnv) x $users verified user(s))',
    heartbeat: heartbeat,
    staleAfter: staleAfter,
    pollInterval: _pollInterval,
    rule: _rule,
  );

  /// Makes the leg [label] present until [LtUserLeg.leave]: it counts for every share from now on.
  LtUserLeg join(String label) {
    Directory(directory).createSync(recursive: true);
    final owner = '$pid-${_sequence++}-${DateTime.now().microsecondsSinceEpoch}';
    final file = File(p.join(directory, '$owner.leg'))..writeAsStringSync(LtUserLeg._content(label, leasing: false));
    return LtUserLeg._(owner, label, file, Timer.periodic(heartbeat, (_) => _touch(file)));
  }

  void _touch(File file) {
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      _logger.detail('[lt-user-cap] ${p.basename(file.path)} is gone; no heartbeat');
    }
  }

  /// The present legs by owner, with their labels and whether they lease yet; presence files not refreshed
  /// for [staleAfter] are deleted.
  Map<String, ({String label, bool leasing})> _liveLegs() {
    final dir = Directory(directory);
    final legs = <String, ({String label, bool leasing})>{};
    for (final file in dir.existsSync() ? dir.listSync().whereType<File>() : const <File>[]) {
      if (!file.path.endsWith('.leg')) {
        continue;
      }
      final owner = p.basenameWithoutExtension(file.path);
      try {
        if (DateTime.now().difference(file.statSync().modified) > staleAfter) {
          _logger.detail('[lt-user-cap] dropping stale leg ${p.basename(file.path)}');
          file.deleteSync();
          continue;
        }
        final decoded = jsonDecode(file.readAsStringSync());
        final fields = decoded is Map ? decoded : const {};
        legs[owner] =
            (label: fields['label'] is String ? fields['label'] as String : owner, leasing: fields['leasing'] == true);
      } on FormatException {
        legs[owner] = (label: owner, leasing: false);
        // Only another process removing the file between the listing and here reaches this.
        // coverage:ignore-start
      } on FileSystemException {
        continue;
      }
      // coverage:ignore-end
    }
    return legs;
  }

  /// The grant rule of the class comment, for [owner]'s request given the live leases and waiters.
  LtGrantLimit _rule(LtSlotView view, String owner) {
    final legs = _liveLegs()..putIfAbsent(owner, () => (label: owner, leasing: true));
    final cap = budget.limit;
    final share = max(1, cap ~/ legs.length);
    final held = <String, int>{};
    var used = 0;
    for (final lease in view.leases) {
      used += lease.slots;
      if (lease.owner != null) {
        held.update(lease.owner!, (slots) => slots + lease.slots, ifAbsent: () => lease.slots);
      }
    }
    var owed = 0;
    final idle = <String>[];
    for (final MapEntry(key: leg, value: (:label, :leasing)) in legs.entries) {
      final short = max(0, share - (held[leg] ?? 0));
      if (leg == owner || short == 0) {
        continue;
      }
      if (!leasing || view.waiting.contains(leg)) {
        owed += short;
      } else {
        idle.add(label);
      }
    }
    final own = max(0, share - (held[owner] ?? 0));
    String note(int slots) {
      final borrowed = slots > own && idle.isNotEmpty
          ? ', borrowed ${slots - own} idle session(s) from '
              '${idle.join(', ')}'
          : '';
      return 'share $share of the test user cap of $cap (${legs.length} live LT leg(s) of this user; $perUser '
          'per verified user x $users verified user(s))$borrowed';
    }

    return (most: cap - used - owed, share: share, note: note);
  }

  /// Leases up to [wanted] sessions for the job [label] of [leg]: first from this cap by the rule of the
  /// class comment, waiting for at least `min(minimum, share)` of them, then from [machine] for as many as
  /// the cap granted. The returned lease holds what both granted. [machine] gets the count and the least it
  /// should wait for. When [cancel] completes while it waits, [LtSlotWaitCancelled] is thrown.
  Future<LtSlotLease> lease(
      {required int wanted,
      required String label,
      required int minimum,
      required LtUserLeg leg,
      required Future<LtSlotLease> Function(int wanted, int minimum) machine,
      Future<void>? cancel}) async {
    leg._startLeasing();
    final share = max(1, budget.limit ~/ max(1, _liveLegs().length));
    final user = await budget.acquire(
        wanted: wanted, label: label, minimum: min(minimum, share), owner: leg.owner, cancel: cancel);
    _logger.info('[lt-user-cap] $label: ${user.slots} of $wanted device session(s), ${user.note}');
    final LtSlotLease granted;
    try {
      granted = await machine(user.slots, min(minimum, user.slots));
    } on Object {
      await user.release();
      rethrow;
    }
    return LtSlotLease.nested(user, granted);
  }
}
