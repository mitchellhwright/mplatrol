import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:path/path.dart' as p;

/// Env var: the most LambdaTest device sessions all `mplatrol run` processes of
/// this user on this machine hold at once (see [LtSlotBudget]).
const ltMaxConcurrentSessionsEnv = 'MPLATROL_LT_MAX_CONCURRENT_SESSIONS';

/// Default [ltMaxConcurrentSessionsEnv]; set the variable to fit your LambdaTest plan and leave headroom for
/// other suites sharing the account.
const ltDefaultMaxConcurrentSessions = 30;

/// Thrown by [LtSlotBudget.acquire] when its `cancel` future completes while it waits; its wait
/// ticket is gone and nothing was leased.
class LtSlotWaitCancelled implements Exception {
  /// Creates the exception for the job [label].
  const LtSlotWaitCancelled(this.label);

  /// The job that stopped waiting.
  final String label;

  @override
  String toString() => 'LtSlotWaitCancelled: $label stopped waiting';
}

/// The sessions this user's processes may hold now, given the [held] sessions they hold: the fair
/// share of the LambdaTest org (see `ltFairShare`).
typedef LtFairShareCheck = Future<int> Function(int held);

/// What an [LtGrantRule] sees under the budget's lock: every live lease with its owner and sessions, and
/// the owners with a live wait ticket other than the asking request's own.
typedef LtSlotView = ({List<({String? owner, int slots})> leases, Set<String> waiting});

/// The most sessions an owner's request may take now, the share it never waits for more than, and the
/// note its granted lease carries for the log line (see [LtSlotLease.note]).
typedef LtGrantLimit = ({int most, int share, String Function(int slots) note});

/// Decides, under the budget's lock, how much the request of `owner` may take (see [LtSlotBudget.rule]).
typedef LtGrantRule = LtGrantLimit Function(LtSlotView view, String owner);

typedef _Request = ({int want, int floor, String label, String? owner, int cap});

/// A grant of [slots] device sessions from an [LtSlotBudget]. Hold it while the
/// sessions run and [release] it once their job ended.
class LtSlotLease {
  LtSlotLease._(this._slots, this._release, {this.file, this.note = '', Future<void> Function(int slots)? shrink})
      : _shrink = shrink;

  /// A lease of [slots] outside any budget, for runs without one.
  LtSlotLease.unbudgeted(this._slots)
      : _release = _nothing,
        _shrink = null,
        note = '',
        file = null;

  /// One lease holding [outer] and [inner] together, as many sessions as both allow: [inner] was leased
  /// while [outer] was held, and [release] returns [inner] first. [outer] gives back what [inner] did not
  /// grant at once, so neither budget counts sessions nobody runs.
  static Future<LtSlotLease> nested(LtSlotLease outer, LtSlotLease inner) async {
    final slots = min(outer.slots, inner.slots);
    await outer.shrinkTo(slots);
    await inner.shrinkTo(slots);
    return LtSlotLease._(slots, () async {
      await inner.release();
      await outer.release();
    });
  }

  static Future<void> _nothing() async {}

  /// Device sessions this lease allows.
  int get slots => _slots;
  int _slots;

  /// The lease file while the lease is held; null for an [LtSlotLease.unbudgeted] lease.
  final String? file;

  /// What the budget's [LtSlotBudget.rule] said about this grant (e.g. its share); empty without one.
  final String note;
  final Future<void> Function() _release;
  final Future<void> Function(int slots)? _shrink;
  var _released = false;

  /// Gives back the sessions beyond [slots] while keeping the rest; does nothing when the lease
  /// holds no more than [slots] or was released.
  Future<void> shrinkTo(int slots) async {
    if (_released || slots >= _slots) {
      return;
    }
    _slots = max(slots, 0);
    await _shrink?.call(_slots);
  }

  /// Returns the slots to the budget; later calls do nothing.
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    await _release();
  }
}

/// Machine-wide budget of LambdaTest device sessions, shared through lease
/// files in [directory] by every concurrent `mplatrol run`, so parallel matrix
/// legs never ask LambdaTest for more devices than [limit] together.
///
/// Each lease is a file a running process refreshes every [heartbeat]; a lease
/// not refreshed for [staleAfter] belongs to a process that died and no longer
/// counts. Lease bookkeeping happens under an exclusive lock file, which a process
/// that died holding it leaves behind for at most [staleAfter]. Every grant and
/// release is appended to `usage.log` with the sessions then in use.
///
/// Waiters are served first come, first served: a caller that has to wait
/// leaves a `.wait` ticket (refreshed while it waits, stale like a lease), and
/// no caller is granted sessions while an older live ticket is queued. Without
/// this, a job that releases sessions and immediately asks again (an iOS wave)
/// takes them back before a waiter that needs several at once ever gets them.
///
/// [tag], [unit] and [limitSource] word the log lines, so the same budget can share other machine-wide
/// devices: `mplatrol matrix` leases the local emulator and simulator through it with a limit of 1.
///
/// With a [rule], requests that name an `owner` are limited by it instead: the rule's reservations decide
/// who is served first, so a ticket only queues behind older tickets of its own owner.
class LtSlotBudget {
  LtSlotBudget({
    required this.directory,
    required this.limit,
    required MplatrolLogger logger,
    this.tag = 'lt-slots',
    this.unit = 'LambdaTest session(s)',
    this.limitSource = ' ($ltMaxConcurrentSessionsEnv)',
    this.heartbeat = const Duration(seconds: 30),
    this.staleAfter = const Duration(minutes: 3),
    this.pollInterval = const Duration(seconds: 15),
    this.onLeaseEnded,
    this.fairShare,
    this.shareRecheck = const Duration(minutes: 1),
    this.rule,
    DateTime Function()? clock,
  })  : _logger = logger,
        _clock = clock ?? DateTime.now;

  /// The budget for [environment]: [ltMaxConcurrentSessionsEnv] sessions (default
  /// [ltDefaultMaxConcurrentSessions]) under `$HOME/.mplatrol/lt-slots`. Null without a
  /// `HOME`, where there is no per-user place to share leases. [onLeaseEnded] hears of every lease's
  /// sessions and how long it was held; [fairShare] caps the sessions held by the org's usage.
  ///
  /// Throws a [FormatException] when the limit is not a positive whole number.
  static LtSlotBudget? fromEnvironment(Map<String, String> environment, MplatrolLogger logger,
      {void Function(int slots, Duration held)? onLeaseEnded, LtFairShareCheck? fairShare}) {
    final raw = (environment[ltMaxConcurrentSessionsEnv] ?? '').trim();
    final limit = raw.isEmpty ? ltDefaultMaxConcurrentSessions : int.tryParse(raw);
    if (limit == null || limit < 1) {
      throw FormatException('$ltMaxConcurrentSessionsEnv must be a positive whole number of LambdaTest '
          'sessions (got "$raw").');
    }
    final home = environment['HOME'] ?? '';
    if (home.isEmpty) {
      logger.detail('[lt-slots] no HOME, so no machine-wide session budget');
      return null;
    }
    return LtSlotBudget(
      directory: p.join(home, '.mplatrol', 'lt-slots'),
      limit: limit,
      logger: logger,
      onLeaseEnded: onLeaseEnded,
      fairShare: fairShare,
    );
  }

  final String directory;
  final int limit;

  /// The prefix of every log line, e.g. `lt-slots` for `[lt-slots] …`.
  final String tag;

  /// What is leased, as the log lines name it.
  final String unit;

  /// Where [limit] comes from, appended to the waiting line (empty for a fixed limit).
  final String limitSource;
  final Duration heartbeat;
  final Duration staleAfter;
  final Duration pollInterval;

  /// Hears of every released lease: its sessions and how long it was held (device-minutes).
  final void Function(int slots, Duration held)? onLeaseEnded;

  /// Caps the sessions held below [limit] while the LambdaTest org is busy; null for no cap.
  final LtFairShareCheck? fairShare;

  /// How often [fairShare] is asked again, at most: on an acquire at least this long after the last.
  final Duration shareRecheck;

  /// Limits the requests that name an owner (see [acquire]); null for first come, first served only.
  final LtGrantRule? rule;
  int? _share;
  DateTime? _shareAt;
  final MplatrolLogger _logger;
  final DateTime Function() _clock;
  static var _sequence = 0;

  /// A lock is held only for a few file operations; one older than this was
  /// left by a process that died holding it.
  static const _lockStaleAfter = Duration(minutes: 2);

  /// Waits until at least `min(wanted, minimum)` sessions are free, then leases
  /// as many of [wanted] as are free. [label] names the job in `usage.log`.
  ///
  /// The waiting and granted-after-waiting lines go to [report] (default: the logger). When [cancel]
  /// completes while the caller waits, its ticket is removed and [LtSlotWaitCancelled] is thrown. [owner]
  /// names who holds the lease for the [rule].
  Future<LtSlotLease> acquire(
      {required int wanted,
      required String label,
      int minimum = 1,
      void Function(String line)? report,
      Future<void>? cancel,
      String? owner}) async {
    final say = report ?? _logger.info;
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    File? ticket;
    while (true) {
      final check = fairShare;
      final cap = check == null ? limit : await _cap(check);
      final want = min(max(wanted, 1), cap);
      final floor = min(max(minimum, 1), want);
      final request = (want: want, floor: floor, label: label, owner: owner, cap: cap);
      final granted = await _locked(() => _tryGrant(request, ticket));
      if (granted != null) {
        if (ticket != null) {
          say('[$tag] $label: got ${granted.slots} of $want $unit after waiting');
        }
        return granted;
      }
      final queued = ticket ?? await _locked<File>(() => _enqueue(label, owner));
      if (ticket == null) {
        final share = cap < limit ? ' (the LambdaTest org fair share of the $limit)' : '';
        say('[$tag] $label: waiting for $floor free $unit of the machine-wide $cap$limitSource$share');
      }
      ticket = queued;
      await Future.any([Future<void>.delayed(pollInterval), if (cancel != null) cancel]);
      if (cancelled) {
        await _locked(() => _deleteIfPresent(queued));
        throw LtSlotWaitCancelled(label);
      }
      _touch(queued);
    }
  }

  /// The most sessions to hold now: [limit], or less when [check] (asked at most every [shareRecheck])
  /// says the org is busy. Running sessions are never taken back.
  Future<int> _cap(LtFairShareCheck check) async {
    final last = _shareAt;
    if (last == null || _clock().difference(last) >= shareRecheck) {
      final held = await _locked(_activeSlots);
      _share = min(limit, max(1, await check(held)));
      _shareAt = _clock();
    }
    return _share!;
  }

  /// Queues a waiter ticket; [_tryGrant] serves the oldest live ticket first.
  File _enqueue(String label, String? owner) {
    final file = File(p.join(directory, '$pid-${_sequence++}-${_clock().microsecondsSinceEpoch}.wait'))
      ..writeAsStringSync(jsonEncode({'label': label, 'pid': pid, if (owner != null) 'owner': owner}));
    _touch(file);
    return file;
  }

  LtSlotLease? _tryGrant(_Request request, File? ticket) {
    final (:want, :label, :owner, :cap, floor: _) = request;
    final ruled = rule != null && owner != null;
    if (_hasOlderWaiter(ticket, ruled ? owner : null)) {
      return null;
    }
    final used = _activeSlots();
    var free = cap - used;
    var floor = request.floor;
    String Function(int slots)? note;
    if (ruled) {
      final limit = rule!(_view(ticket), owner);
      free = min(free, limit.most);
      floor = min(floor, max(1, limit.share));
      note = limit.note;
    }
    if (free < floor) {
      return null;
    }
    if (ticket != null) {
      _deleteIfPresent(ticket);
    }
    var slots = min(want, free);
    final file = File(p.join(directory, '$pid-${_sequence++}-${_clock().microsecondsSinceEpoch}.lease'));
    void write() => file
        .writeAsStringSync(jsonEncode({'slots': slots, 'label': label, 'pid': pid, if (owner != null) 'owner': owner}));
    write();
    _touch(file);
    _log('grant', label, slots, used + slots);
    final grantedAt = _clock();
    final timer = Timer.periodic(heartbeat, (_) => _touch(file));
    return LtSlotLease._(slots, () async {
      timer.cancel();
      onLeaseEnded?.call(slots, _clock().difference(grantedAt));
      await _locked(() {
        _deleteIfPresent(file);
        _log('release', label, slots, _activeSlots());
      });
    },
        file: file.path,
        note: note?.call(slots) ?? '',
        shrink: (to) => _locked(() {
              slots = to;
              write();
              _touch(file);
              _log('shrink', label, slots, _activeSlots());
            }));
  }

  /// The label and process id of every live lease (stale ones are ignored, not deleted), so a caller
  /// that must not disturb the leased devices can say who holds them.
  List<({String label, int? pid, String file})> liveLeases() {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return const [];
    }
    final leases = <({String label, int? pid, String file})>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.lease') || _isStale(entity)) {
        continue;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(entity.readAsStringSync());
      } on FormatException {
        continue;
        // Only a lease released between the listing and the read reaches this.
        // coverage:ignore-start
      } on FileSystemException {
        continue;
      }
      // coverage:ignore-end
      final fields = decoded is Map ? decoded : const {};
      final label = fields['label'];
      final owner = fields['pid'];
      leases.add((
        label: label is String ? label : p.basename(entity.path),
        pid: owner is int ? owner : null,
        file: entity.path
      ));
    }
    return leases;
  }

  /// Refreshes [file]'s heartbeat; it may have been released (deleted)
  /// between the timer firing and here.
  void _touch(File file) {
    try {
      file.setLastModifiedSync(_clock());
    } on FileSystemException {
      _logger.detail('[$tag] ${p.basename(file.path)} is gone; no heartbeat');
    }
  }

  /// Sessions held by live leases; stale leases are deleted.
  int _activeSlots() {
    var total = 0;
    for (final file in _liveFiles('.lease', 'lease')) {
      total += _leaseSlots(file);
    }
    return total;
  }

  /// Whether a live waiter queued before [ticket] (any live waiter when
  /// [ticket] is null) must be served first; stale tickets are deleted. With an [owner], only that
  /// owner's tickets count.
  bool _hasOlderWaiter(File? ticket, String? owner) {
    final ours = ticket == null ? null : _ticketOrder(ticket.path);
    for (final entity in _liveFiles('.wait', 'wait ticket')) {
      if (entity.path == ticket?.path || (owner != null && _owner(entity) != owner)) {
        continue;
      }
      if (ours == null || _compareOrder(_ticketOrder(entity.path), ours) < 0) {
        return true;
      }
    }
    return false;
  }

  /// The live leases with their owners, and the owners of the live tickets other than [ticket].
  LtSlotView _view(File? ticket) {
    final leases = [
      for (final file in _liveFiles('.lease', 'lease')) (owner: _owner(file), slots: _leaseSlots(file)),
    ];
    final waiting = {
      for (final file in _liveFiles('.wait', 'wait ticket'))
        if (file.path != ticket?.path) _owner(file),
    }.whereType<String>().toSet();
    return (leases: leases, waiting: waiting);
  }

  /// The files of [directory] ending in [extension] that are not stale; stale ones are deleted.
  List<File> _liveFiles(String extension, String what) {
    final live = <File>[];
    for (final entity in Directory(directory).listSync()) {
      if (entity is! File || !entity.path.endsWith(extension)) {
        continue;
      }
      if (_isStale(entity)) {
        _logger.detail('[$tag] dropping stale $what ${p.basename(entity.path)}');
        _deleteIfPresent(entity);
        continue;
      }
      live.add(entity);
    }
    return live;
  }

  static String? _owner(File file) => switch (_field(file, 'owner')) { final String owner => owner, _ => null };

  /// The JSON field [name] of a lease or ticket file; null when unreadable.
  static Object? _field(File file, String name) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? decoded[name] : null;
    } on FormatException {
      return null;
    }
  }

  /// A ticket's queue position from its name `<pid>-<sequence>-<microseconds>.wait`: queued time, then
  /// pid and sequence as numbers, so tickets queued in the same microsecond still have one fixed order.
  /// A name in another form sorts first (and goes stale like any ticket).
  static List<int> _ticketOrder(String path) {
    final parts = p.basenameWithoutExtension(path).split('-').map(int.tryParse).toList();
    if (parts.length != 3 || parts.contains(null)) {
      return const [0, 0, 0];
    }
    return [parts[2]!, parts[0]!, parts[1]!];
  }

  static int _compareOrder(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return a[i].compareTo(b[i]);
      }
    }
    return 0;
  }

  int _leaseSlots(File file) {
    final slots = _field(file, 'slots');
    return slots is int && slots > 0 ? slots : 0;
  }

  /// Deletes [entity]; another process may have deleted it first.
  void _deleteIfPresent(FileSystemEntity entity) {
    try {
      entity.deleteSync();
      // Only a concurrent process deleting it between the listing and here
      // reaches this.
      // coverage:ignore-start
    } on FileSystemException {
      _logger.detail('[$tag] ${p.basename(entity.path)} was already removed');
    }
    // coverage:ignore-end
  }

  bool _isStale(FileSystemEntity entity) => _clock().difference(entity.statSync().modified) > staleAfter;

  void _log(String event, String label, int slots, int inUse) {
    File(p.join(directory, 'usage.log')).writeAsStringSync(
        '${_clock().toIso8601String()} $event $slots $label inUse=$inUse/$limit\n',
        mode: FileMode.append);
  }

  /// Runs [body] while holding the exclusive lock file, breaking a lock left
  /// stale by a process that died holding it.
  Future<T> _locked<T>(T Function() body) async {
    Directory(directory).createSync(recursive: true);
    final lock = File(p.join(directory, '.lock'));
    while (true) {
      try {
        lock.createSync(exclusive: true);
        break;
      } on FileSystemException {
        if (_clock().difference(lock.statSync().modified) > _lockStaleAfter) {
          _logger.detail('[$tag] breaking a stale lock');
          _deleteIfPresent(lock);
          continue;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    try {
      return body();
    } finally {
      // Another process may have broken this lock as stale (a host under heavy load can stall a holder past the
      // stale limit); its removal must not crash the leg with a PathNotFoundException.
      _deleteIfPresent(lock);
    }
  }
}
