import 'dart:async';

/// Periodically runs a native permission-dialog probe on a timer.
///
/// An OS permission dialog pauses the Flutter activity, so `tester.pump()`
/// stops completing and a poll loop that probes between pumps never reaches
/// its own probe. Timers still fire while frames are paused, and native
/// automator calls do not need frames, so this watchdog keeps dismissing the
/// dialog the loop cannot see. While [isActive], the watchdog is the only
/// caller of the probe; overlapping ticks are skipped, never queued.
class NativeDialogWatchdog {
  /// Creates a watchdog that calls [probe] every [interval] once started.
  ///
  /// [probe] returns true when it dismissed a dialog. [log] receives one line
  /// per dismissal or probe failure.
  NativeDialogWatchdog({
    required Future<bool> Function() probe,
    void Function(String line) log = print,
    this.interval = const Duration(seconds: 3),
  })  : _probe = probe,
        _log = log;

  /// Time between probe attempts.
  final Duration interval;

  final Future<bool> Function() _probe;
  final void Function(String line) _log;
  Timer? _timer;
  bool _probing = false;
  int _dismissed = 0;
  int _failures = 0;
  Object? _lastFailure;

  /// Whether the watchdog currently owns permission-dialog probing.
  bool get isActive => _timer?.isActive ?? false;

  /// Starts probing; calling it again while active has no effect.
  void start() {
    if (isActive) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  /// Stops probing. A probe already in flight finishes but is not repeated.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One-line summary for failure messages.
  String describe() => 'watchdog(dismissed=$_dismissed failures=$_failures'
      '${_lastFailure == null ? '' : ' lastFailure=$_lastFailure'})';

  Future<void> _tick() async {
    if (_probing) {
      return;
    }
    _probing = true;
    try {
      if (await _probe()) {
        _dismissed++;
        _log('E2E_NATIVE_DIALOG_WATCHDOG_DISMISSED count=$_dismissed');
      }
    } on Object catch (error) {
      // A failed tick must not escape the timer zone as an unrelated async
      // error; it is counted, logged, and reported through describe().
      _failures++;
      _lastFailure = error;
      _log('E2E_NATIVE_DIALOG_WATCHDOG_PROBE_FAILED count=$_failures error=$error');
    } finally {
      _probing = false;
    }
  }
}
