import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_leg_runner.dart';
import 'package:path/path.dart' as p;

/// Free disk space in GB at a path, or null when it cannot be read.
typedef MatrixFreeGb = Future<double?> Function(String path);

/// Runs after a lane's leg freed the checkout, before the lane builds the next
/// leg (e.g. pruning that lane's stale build output).
typedef MatrixLaneHook = Future<void> Function(String lane);

/// When the scheduler stops a leg that runs too long (a hung LambdaTest session or tunnel, or a wedged local
/// emulator or simulator).
///
/// A leg may run up to [medianFactor] times the median of the finished legs of its variant that ran tests, but
/// never less than [minLeg] nor more than [maxLeg]; with fewer than [minSamples] such legs only [maxLeg] applies.
/// (Legs that stop on an environment check after a minute would otherwise make the median a minute, and a cap
/// that small would kill every leg that is really testing.)
class MatrixStallPolicy {
  /// Creates a policy.
  const MatrixStallPolicy({
    this.maxLeg = const Duration(minutes: 75),
    this.minLeg = const Duration(minutes: 30),
    this.medianFactor = 2,
    this.minSamples = 3,
    this.idle = const Duration(minutes: 15),
  });

  /// The longest any leg may run.
  final Duration maxLeg;

  /// The cap never goes below this, however short the finished legs were.
  final Duration minLeg;

  /// The multiple of the variant's median leg time a leg may run.
  final int medianFactor;

  /// Finished legs needed before the median counts.
  final int minSamples;

  /// A leg over its median cap is only stopped once its log has not grown for this long; a leg that is still
  /// writing (tests finishing, an infra retry) runs on until [maxLeg], so a median cap never stops a leg in the
  /// middle of its infra retry.
  final Duration idle;

  /// The time cap of a leg whose variant's finished legs took [finished].
  Duration capFor(List<Duration> finished) {
    if (finished.length < minSamples) {
      return maxLeg;
    }
    final sorted = [...finished]..sort();
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) ~/ 2;
    final scaled = median * medianFactor;
    final floor = minLeg < maxLeg ? minLeg : maxLeg;
    if (scaled < floor) {
      return floor;
    }
    return scaled < maxLeg ? scaled : maxLeg;
  }
}

/// Runs a matrix's legs on a pool of lane checkouts.
///
/// Each lane takes the next queued leg whose `<tenant>_<variant>` is not already
/// running, starts it ([MatrixLegRunner]) and is free again as soon as that
/// leg freed its checkout (artifacts uploaded) or exited; the leg's devices,
/// verdicts and reports finish in the background. A local leg never frees its
/// checkout early, and a lane does not start one while another local leg of
/// its platform runs (the machine has one emulator and one simulator). A lane
/// does not start a leg while free disk is below [minFreeGb]. Every start,
/// release and finish is a line in the run's `queue.log`. A leg that exceeds
/// [stall]'s cap for its variant is stopped and marked (`stalled` in its leg
/// directory) so the publishers report it as `lt-failure` (`device-failure`
/// for a local leg); the round carries on. Time a leg waits for LambdaTest
/// sessions or its local device does not count. [abort] stops every running
/// leg and starts no more.
class MatrixScheduler {
  /// Creates a scheduler.
  MatrixScheduler({
    required this.runner,
    required this.run,
    required this.minFreeGb,
    required MatrixFreeGb freeGb,
    this.afterRelease,
    this.onLegFinished,
    this.stall = const MatrixStallPolicy(),
    this.stallPoll = const Duration(seconds: 30),
    this.diskWait = const Duration(minutes: 1),
    DateTime Function()? clock,
  })  : _freeGb = freeGb,
        _clock = clock ?? DateTime.now;

  /// Starts each leg.
  final MatrixLegRunner runner;

  /// The run directory.
  final MatrixRunDir run;

  /// The free disk a lane needs before it starts a leg.
  final int minFreeGb;

  /// Runs for a lane after its leg freed the checkout.
  final MatrixLaneHook? afterRelease;

  /// Called after every leg's exit is recorded in `queue.log`.
  final void Function()? onLegFinished;

  /// When a running leg is stopped for taking too long.
  final MatrixStallPolicy stall;

  /// How often running legs are checked against their cap.
  final Duration stallPoll;

  /// How long a lane waits before checking the disk again.
  final Duration diskWait;

  final MatrixFreeGb _freeGb;
  final DateTime Function() _clock;
  final _pending = <MatrixLeg>[];
  final _running = <String, ({MatrixLeg leg, DateTime start, MatrixLegHandle handle})>{};
  final _stalled = <String>{};
  final _logGrowth = <String, ({int length, DateTime at})>{};
  final _queued = <String, Duration>{};
  final _durations = <String, List<Duration>>{};
  final _finished = <Future<void>>[];
  final _exits = <String, int>{};

  /// Runs every leg of [queue] on [lanes] (app checkouts) with [environment]
  /// as each leg's base process environment, and returns each leg's exit code
  /// by [MatrixLeg.key] once all have finished.
  Future<Map<String, int>> runAll(List<MatrixLeg> queue, List<String> lanes,
      {required Map<String, String> environment}) async {
    _pending
      ..clear()
      ..addAll(queue);
    _log('start lanes=(${lanes.map(laneName).join(' ')}) legs=${queue.length}');
    final watchdog = Timer.periodic(stallPoll, (_) => _stopStalledLegs());
    try {
      await Future.wait([for (final lane in lanes) _lane(lane, environment)]);
      await Future.wait(_finished);
    } finally {
      watchdog.cancel();
    }
    _log('all lanes finished');
    return Map.unmodifiable(_exits);
  }

  /// Stops every running leg and starts no more; [runAll] then returns once the legs have exited.
  void abort(String reason) {
    _log('abort: $reason; stopping ${_running.length} running legs, ${_pending.length} not started');
    _pending.clear();
    for (final running in _running.values) {
      running.handle.stop();
    }
  }

  void _stopStalledLegs() {
    final now = _clock();
    for (final (:leg, :start, :handle) in _running.values.toList()) {
      if (_isWaitingForDevices(leg)) {
        _queued.update(leg.key, (queued) => queued + stallPoll, ifAbsent: () => stallPoll);
        continue;
      }
      final cap = stall.capFor(_durations[leg.variant] ?? const []);
      final elapsed = now.difference(start) - (_queued[leg.key] ?? Duration.zero);
      final quietFor = now.difference(_lastLogGrowth(leg, start, now));
      final overCap = elapsed > stall.maxLeg || (elapsed > cap && quietFor >= stall.idle);
      if (overCap && _stalled.add(leg.key)) {
        final queued = _queued[leg.key];
        final waitedFor =
            leg.isLocal ? 'waiting for the local ${leg.platform} device' : 'queued for LambdaTest sessions';
        final waitNote = queued == null ? '' : ' (not counting ${queued.inMinutes} min $waitedFor)';
        final quietNote = elapsed > stall.maxLeg ? '' : ', no log output for ${quietFor.inMinutes} min';
        final reason = 'ran ${elapsed.inMinutes} min$waitNote, over the ${cap.inMinutes} min cap$quietNote';
        File(run.stalledMarker(leg)).writeAsStringSync('$reason\n');
        _log('stalled $leg: $reason; stopping it (${leg.isLocal ? 'device-failure' : 'lt-failure'})');
        handle.stop();
      }
    }
  }

  /// When [leg]'s log last grew, as seen by the watchdog polls ([start] until it first grows).
  DateTime _lastLogGrowth(MatrixLeg leg, DateTime start, DateTime now) {
    final log = File(run.log(leg));
    final length = log.existsSync() ? log.lengthSync() : 0;
    final seen = _logGrowth[leg.key];
    if (seen == null || length > seen.length) {
      _logGrowth[leg.key] = (length: length, at: seen == null && length == 0 ? start : now);
    }
    return _logGrowth[leg.key]!.at;
  }

  /// Whether [leg] is queued for LambdaTest sessions or its local device: the last line of its log is the
  /// `[lt-slots] … waiting for`, `[lt-user-cap] … waiting for` (its test users' session cap) or
  /// `[local-device] … waiting for` line. A queued leg is waiting its turn, not stalled.
  bool _isWaitingForDevices(MatrixLeg leg) {
    final log = File(run.log(leg));
    if (!log.existsSync()) {
      return false;
    }
    final length = log.lengthSync();
    final handle = log.openSync();
    try {
      final tailStart = length > _logTailBytes ? length - _logTailBytes : 0;
      handle.setPositionSync(tailStart);
      final tail = utf8.decode(handle.readSync(length - tailStart), allowMalformed: true);
      final lines = tail.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty);
      if (lines.isEmpty) {
        return false;
      }
      final last = lines.last;
      return _waitTags.any(last.startsWith) && last.contains('waiting for');
    } finally {
      handle.closeSync();
    }
  }

  static const _logTailBytes = 4096;

  /// Log tags whose `waiting for` line means the leg is queued (see [_isWaitingForDevices]).
  static const _waitTags = ['[lt-slots]', '[lt-user-cap]', '[local-device]'];

  Future<void> _lane(String lane, Map<String, String> environment) async {
    final name = laneName(lane);
    final checkoutExisted = Directory(lane).existsSync();
    while (_pending.isNotEmpty) {
      if (checkoutExisted && !Directory(lane).existsSync()) {
        // Another process removed the checkout (e.g. a finished round's lane teardown); its legs go to the other lanes.
        _log('$name stopped: its checkout $lane is missing');
        return;
      }
      final free = await _freeGb(lane);
      if (free != null && free < minFreeGb) {
        _log('$name waiting: only ${free.toStringAsFixed(0)} GB free (needs $minFreeGb)');
        await Future<void>.delayed(diskWait);
        continue;
      }
      final index = _pending.indexWhere((leg) => !_running.containsKey(leg.key) && !_localDeviceBusy(leg));
      if (index < 0) {
        await Future<void>.delayed(diskWait);
        continue;
      }
      final leg = _pending.removeAt(index);
      await _runLeg(lane, name, leg, environment);
    }
    _log('$name done');
  }

  /// Whether [leg] is local and a local leg of its platform already runs: starting it would only hold a
  /// lane while it waits for the one device.
  bool _localDeviceBusy(MatrixLeg leg) =>
      leg.isLocal && _running.values.any((running) => running.leg.isLocal && running.leg.platform == leg.platform);

  /// Starts [leg] on [lane] and returns once the lane is free again.
  Future<void> _runLeg(String lane, String name, MatrixLeg leg, Map<String, String> environment) async {
    _log('$name start $leg');
    final start = _clock();
    final handle = runner.start(leg, lane: lane, run: run, base: environment);
    _running[leg.key] = (leg: leg, start: start, handle: handle);
    _finished.add(handle.exitCode.then((code) {
      _exits[leg.key] = code;
      _running.remove(leg.key);
      // Only legs that ran tests (exit 0: all passed, 70: tests failed) set the variant's normal leg time; a leg
      // that stopped early on an environment or config check (69, 78, …) says nothing about how long tests take.
      if (!_stalled.contains(leg.key) && (code == 0 || code == 70)) {
        final queued = _queued[leg.key] ?? Duration.zero;
        _durations.putIfAbsent(leg.variant, () => []).add(_clock().difference(start) - queued);
      }
      _log('$name finish $leg exit $code');
      onLegFinished?.call();
    }));
    if (await handle.released) {
      _log('$name released $leg');
      await afterRelease?.call(lane);
    }
  }

  void _log(String line) => run.append(line, _clock());
}

/// The name of the lane whose app checkout is [lane]: its workspace directory
/// for `<workspace>/app`, else the checkout's own name.
String laneName(String lane) {
  final normalized = p.normalize(lane);
  return p.basename(normalized) == 'app' ? p.basename(p.dirname(normalized)) : p.basename(normalized);
}
