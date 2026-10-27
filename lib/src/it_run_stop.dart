import 'dart:async';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';

/// How long `mplatrol run` takes at most to stop after the first SIGTERM or SIGINT: less than the 60 s
/// `mplatrol matrix` waits before it sends SIGKILL (`matrixStopGrace`).
const itRunStopDeadline = Duration(seconds: 45);

/// The reason of a test that had not finished when `mplatrol run` was stopped by [signal].
String itRunStoppedReason(String signal) => 'stopped: the run received $signal before this test finished';

/// The signal behind an `mplatrol run` [exitCode] of 128 + its number, or null for any other exit code.
String? itRunStopSignal(int exitCode) => _signalsByExitCode[exitCode];

const _signalsByExitCode = {130: 'SIGINT', 143: 'SIGTERM'};

/// A graceful stop of `mplatrol run` on SIGTERM (what `mplatrol matrix` sends) or SIGINT.
///
/// On the first signal [requested] completes and every process the run started is stopped (builds, the
/// HyperExecute CLI, local test runs), and again every [sweep] for processes started meanwhile, so the
/// runners unwind as usual: leases and leg presence are released,
/// unfinished tests are NOT RUN with [itRunStoppedReason], and the JUnit, summary.json and `[results]` lines
/// are written by the normal reporter. The run then ends with [exitCode]. A second signal, or still running
/// after [deadline], exits at once with [exitCode].
class ItRunStop {
  /// Creates the stop; [signals], [stopChildren] and [exitNow] are injectable so tests start no processes.
  ItRunStop({
    List<Stream<ProcessSignal>> Function()? signals,
    Future<void> Function()? stopChildren,
    void Function(int code)? exitNow,
    this.deadline = itRunStopDeadline,
    this.sweep = const Duration(seconds: 2),
  })  : _signals = signals ?? _processSignals,
        // Only a real `mplatrol run` stops its own child processes; tests inject [stopChildren].
        _stopChildren = stopChildren ?? (() => terminateDescendantProcesses(pid)), // coverage:ignore-line
        _exitNow = exitNow ?? exit;

  static List<Stream<ProcessSignal>> _processSignals() => [ProcessSignal.sigterm.watch(), ProcessSignal.sigint.watch()];

  /// How long the run may take to stop before it exits anyway.
  final Duration deadline;

  /// How often, while stopping, processes the run started meanwhile are stopped too.
  final Duration sweep;
  final List<Stream<ProcessSignal>> Function() _signals;
  final Future<void> Function() _stopChildren;
  final void Function(int code) _exitNow;
  final _requested = Completer<void>();
  final _subscriptions = <StreamSubscription<ProcessSignal>>[];
  final _timers = <Timer>[];
  String? _signal;

  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Completes on the first signal.
  Future<void> get requested => _requested.future;

  /// Whether a signal asked the run to stop.
  bool get isStopping => _signal != null;

  /// 128 + the number of the signal that stopped the run (143 for SIGTERM, 130 for SIGINT); 0 before one.
  int get exitCode => switch (_signal) { 'SIGINT' => 130, null => 0, _ => 143 };

  /// Starts listening for the signals until [close].
  void watch() {
    for (final stream in _signals()) {
      _subscriptions.add(stream.listen(_onSignal));
    }
  }

  void _onSignal(ProcessSignal signal) {
    if (_signal != null) {
      _logger.err('[it-run] received $signal again: exiting now.');
      _exitNow(exitCode);
      return;
    }
    _signal = '$signal';
    _logger.warn('[it-run] received $signal: stopping the running tests, then writing the results '
        '(a second signal exits at once).');
    _timers
      ..add(Timer(deadline, () {
        _logger.err('[it-run] still stopping after ${deadline.inSeconds}s: exiting now.');
        _exitNow(exitCode);
      }))
      ..add(Timer.periodic(sweep, (_) => unawaited(_stopChildren())));
    _requested.complete();
    unawaited(_stopChildren());
  }

  /// Stops listening; the signals regain their default effect.
  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    await Future.wait([for (final subscription in _subscriptions) subscription.cancel()]);
    _subscriptions.clear();
  }
}
