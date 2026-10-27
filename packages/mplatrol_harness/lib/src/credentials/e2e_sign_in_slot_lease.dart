import 'dart:async';

/// Starts a periodic timer; injectable so tests control renewals.
typedef PeriodicTimer = Timer Function(Duration every, void Function(Timer timer) tick);

/// A held sign-in slot, or a lease that holds nothing ([E2eSignInSlotLease.none]).
///
/// While held, the slot is renewed every [renewEvery] so a sign-in that takes
/// longer than the server's hold keeps it; [release] stops the renewals and frees it.
class E2eSignInSlotLease {
  /// Creates a held lease that renews with [renew] and frees the slot with [release].
  ///
  /// Args:
  ///   holder: The session id the slot is held for, for log lines.
  ///   renew: Asks for the slot again; must not throw.
  ///   release: Frees the slot; may throw, which [E2eSignInSlotLease.release] logs.
  ///   renewEvery: Time between renewals, well inside the server's hold.
  ///   periodic: Starts the renewal timer.
  ///   log: Receives one line per release or skipped renewal.
  E2eSignInSlotLease.held({
    required String holder,
    required Future<void> Function() renew,
    required Future<void> Function() release,
    required this.renewEvery,
    PeriodicTimer periodic = Timer.periodic,
    void Function(String line) log = print,
  })  : _holder = holder,
        _release = release,
        _log = log {
    _renewal = periodic(renewEvery, (_) => _renewOnce(renew));
  }

  /// A lease that holds nothing: no server, a server without the slot route, or a timed-out wait.
  E2eSignInSlotLease.none()
      : _holder = '',
        _release = null,
        _log = print,
        renewEvery = Duration.zero;

  /// Time between renewals; zero for [E2eSignInSlotLease.none].
  final Duration renewEvery;

  final String _holder;
  final Future<void> Function()? _release;
  final void Function(String line) _log;
  Timer? _renewal;
  Future<void>? _renewing;
  var _released = false;

  /// Whether this lease holds the slot (and has not released it).
  bool get isHeld => _release != null && !_released;

  /// Starts a renewal unless one is still in flight, so at most one renewal
  /// runs at a time and [release] can wait for it.
  void _renewOnce(Future<void> Function() renew) {
    if (_renewing != null) {
      _log('E2E_SIGN_IN_SLOT renew_skipped holder=$_holder: the previous renewal is still in flight');
      return;
    }
    _renewing = renew().whenComplete(() => _renewing = null);
  }

  /// Stops renewing and frees the slot; later calls do nothing. Never throws.
  ///
  /// A renewal still in flight finishes first: arriving after the release, it
  /// would hand the free slot back to this finished session for a full hold.
  Future<void> release() async {
    _renewal?.cancel();
    final release = _release;
    if (_released || release == null) {
      return;
    }
    _released = true;
    await _renewing;
    try {
      await release();
      _log('E2E_SIGN_IN_SLOT released holder=$_holder');
    } on Object catch (error) {
      _log('E2E_SIGN_IN_SLOT release_failed holder=$_holder error=$error; the server frees it after its hold');
    }
  }
}
