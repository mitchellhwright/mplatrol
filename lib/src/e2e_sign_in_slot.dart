import 'dart:convert';
import 'dart:io';

/// Path the credential server serves the sign-in slot on, beside `/e2e-credentials`.
const e2eSignInSlotRoute = '/mplatrol-sign-in-slot';

/// How long a granted slot stays held unless its holder releases it first:
/// longer than a password + one-time-code sign-in takes, short enough that a
/// device that died holding it does not stall the others for long.
const e2eSignInSlotHold = Duration(seconds: 60);

/// The longest holder id the server accepts.
const e2eSignInSlotMaxHolderLength = 128;

/// One sign-in at a time for one test user.
///
/// Many backends reject sign-ins submitted at the same moment for the same user
/// (the app returns to `/authentication` after the one-time code), so parallel
/// devices take turns: a device asks for the slot before it submits the
/// password and releases it once sign-in finished or failed.
///
/// With a [file], the slot lives in that file instead of this process, so the
/// runs on this machine that sign in as the same user (e.g. a tenant's Android
/// and iOS legs at once) share it. File updates happen under an exclusive
/// `<file>.lock`, which a process that died holding it leaves for at most a
/// few seconds.
class E2eSignInSlot {
  /// Creates a free slot; [clock] is injectable for tests.
  E2eSignInSlot({DateTime Function()? clock, this.hold = e2eSignInSlotHold, this.file})
      : _clock = clock ?? DateTime.now;

  /// How long a grant lasts without a release.
  final Duration hold;

  /// Where the slot is kept for every process on the machine; null keeps it in
  /// this process.
  final String? file;

  final DateTime Function() _clock;
  String? _holder;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _lockStaleAfter = Duration(seconds: 5);

  /// Grants the slot to [holder] when it is free, expired, or already
  /// [holder]'s (renewing the hold); otherwise returns how long until the
  /// current grant expires.
  ({bool granted, Duration wait}) acquire(String holder) => _update(() {
        final now = _clock();
        if (_holder == null || _holder == holder || !now.isBefore(_expiresAt)) {
          _holder = holder;
          _expiresAt = now.add(hold);
          return (granted: true, wait: Duration.zero);
        }
        return (granted: false, wait: _expiresAt.difference(now));
      });

  /// Frees the slot if [holder] holds it; returns whether it did.
  bool release(String holder) => _update(() {
        if (_holder != holder) {
          return false;
        }
        _holder = null;
        return true;
      });

  /// Runs [change] on the current state; with a [file], reads the state first
  /// and writes it back, under the lock.
  T _update<T>(T Function() change) {
    final path = file;
    if (path == null) {
      return change();
    }
    final lock = _lock(path);
    try {
      _read(File(path));
      final result = change();
      File(path)
          .writeAsStringSync(jsonEncode({'holder': _holder, 'expiresAt': _expiresAt.toUtc().microsecondsSinceEpoch}));
      return result;
    } finally {
      lock.deleteSync();
    }
  }

  void _read(File state) {
    final decoded = state.existsSync() ? _decode(state.readAsStringSync()) : null;
    _holder = decoded?['holder'] as String?;
    final expiresAt = decoded?['expiresAt'];
    _expiresAt = expiresAt is int
        ? DateTime.fromMicrosecondsSinceEpoch(expiresAt, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic>? _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Takes the exclusive `<path>.lock`, breaking one older than
  /// [_lockStaleAfter]. Lock holders only read and write one small file, so
  /// waiting spins briefly.
  File _lock(String path) {
    final lock = File('$path.lock');
    lock.parent.createSync(recursive: true);
    while (true) {
      try {
        lock.createSync(exclusive: true);
        return lock;
      } on FileSystemException {
        try {
          if (DateTime.now().difference(lock.statSync().modified) > _lockStaleAfter) {
            lock.deleteSync();
          }
          // Only another process deleting the lock between the two calls reaches this.
          // coverage:ignore-start
        } on FileSystemException {
          continue;
        }
        // coverage:ignore-end
        sleep(const Duration(milliseconds: 20));
      }
    }
  }
}
