import 'dart:async';

import 'package:mplatrol/src/matrix/matrix_leg.dart';

/// How far a round got when the publish hooks ran; written to the run's `round-state` file.
enum MatrixRoundState {
  /// Legs are still running; results are interim.
  running,

  /// The round was interrupted or failed before every leg finished.
  partial,

  /// Every leg finished.
  complete,
}

/// Runs a shell command (`{run}` already replaced); completes with its exit code.
typedef MatrixHookRunner = Future<int> Function(String command, {required bool silent});

/// Runs the `--publish` hooks while a round runs and when it ends.
///
/// [legFinished] publishes at once when [interval] has passed since the last publish, otherwise
/// once the interval is up, so hooks run at most every [interval] while legs run. [finish] runs
/// them a last time with the round's final state, whatever ended the round.
class MatrixPublisher {
  /// Creates a publisher for [run]; [report] receives every hook failure.
  MatrixPublisher({
    required this.commands,
    required this.run,
    required MatrixHookRunner runHook,
    required void Function(String message, {required bool fatal}) report,
    this.interval = const Duration(minutes: 10),
    DateTime Function()? clock,
  })  : _runHook = runHook,
        _report = report,
        _clock = clock ?? DateTime.now;

  /// The `--publish` shell commands.
  final List<String> commands;

  /// The run directory the hooks publish.
  final MatrixRunDir run;

  /// The shortest time between two interim publishes.
  final Duration interval;

  final MatrixHookRunner _runHook;
  final void Function(String message, {required bool fatal}) _report;
  final DateTime Function() _clock;
  DateTime? _lastPublish;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _dirty = false;
  bool _finished = false;

  /// Notes that a leg finished, so the results changed.
  void legFinished() {
    if (commands.isEmpty || _finished) {
      return;
    }
    _dirty = true;
    _schedule();
  }

  /// Runs the hooks one last time as [state]; returns how many failed.
  Future<int> finish(MatrixRoundState state) async {
    _finished = true;
    _timer?.cancel();
    await _inFlight;
    return _runHooks(state, silent: false);
  }

  void _schedule() {
    if (_inFlight != null || _timer != null) {
      return;
    }
    final last = _lastPublish;
    final wait = last == null ? Duration.zero : interval - _clock().difference(last);
    if (wait <= Duration.zero) {
      _inFlight = _publishInterim();
    } else {
      _timer = Timer(wait, () {
        _timer = null;
        _inFlight = _publishInterim();
      });
    }
  }

  Future<void> _publishInterim() async {
    _dirty = false;
    await _runHooks(MatrixRoundState.running, silent: true);
    _lastPublish = _clock();
    _inFlight = null;
    if (_dirty && !_finished) {
      _schedule();
    }
  }

  Future<int> _runHooks(MatrixRoundState state, {required bool silent}) async {
    run.writeRoundState(state.name);
    var failed = 0;
    for (final command in commands) {
      final shell = command.replaceAll('{run}', run.path);
      try {
        final exitCode = await _runHook(shell, silent: silent);
        if (exitCode != 0) {
          failed++;
          _reportFailure(command, 'exit $exitCode', silent: silent);
        }
      } on Object catch (error) {
        failed++;
        _reportFailure(command, '${error.runtimeType}: $error', silent: silent);
      }
    }
    return failed;
  }

  void _reportFailure(String command, String cause, {required bool silent}) => silent
      ? _report('[matrix] interim --publish "$command" failed ($cause); the next publish retries.', fatal: false)
      : _report('[matrix] --publish "$command" failed ($cause); rerun it by hand.', fatal: true);
}
