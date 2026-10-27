import 'dart:async';
import 'dart:io';

import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;

/// Runs `adb -s <device> <arguments>` through the injected shell, stopped after [timeout] or once
/// [cancelOn] completes.
typedef AndroidAdbCall = Future<ProcessResultX> Function(List<String> arguments,
    {required Duration timeout, Future<void>? cancelOn});

/// What one leg's [AndroidScreenRecorder] left: the saved video [segments] in recording order, and
/// the [contention] warnings it logged about screenrecord processes it did not start.
typedef AndroidRecording = ({List<String> segments, List<String> contention});

/// Records a local Android leg as a chain of on-device `screenrecord` segments and watches the device
/// for screenrecord processes the leg did not start.
///
/// `screenrecord` stops at its `--time-limit` (at most 180 s), so a single recording misses every
/// failure after the first minutes. The recorder starts the next segment as soon as one ends, one
/// process at a time, for the whole leg; each finished segment is pulled to [outputDir] (numbered
/// `-seg01.mp4`, `-seg02.mp4`, …) and removed from the device while the next one records.
///
/// A segment whose adb call fails (a hung `screenrecord` can outlive the host timeout) is
/// stopped on the device too, so it never keeps running as an orphan; a segment that timed out is
/// followed by the next one, once.
///
/// At start and every [pollInterval] it lists the device's `screenrecord` command lines (`ps -A -o ARGS`).
/// Recorders writing `/sdcard/mplatrol-e2e-*` are mplatrol's own: any but the current segment is a leftover
/// and is stopped (and its file removed when an earlier leg left it), never counted as contention. Every
/// other recorder belongs to another adb client, and dozens of them crash the emulator's system server
/// (2026-10-06 regression r8). Each new high is logged once with [localDeviceContentionMarker], which the
/// `localDeviceContention` lesson recognizes.
class AndroidScreenRecorder {
  /// Creates a recorder for [deviceId]; with [record] false it only watches for other recorders.
  AndroidScreenRecorder({
    required this.deviceId,
    required this.outputDir,
    required AndroidAdbCall adb,
    required MplatrolLogger logger,
    this.record = true,
    this.segmentLimit = const Duration(seconds: 180),
    this.minimumSegment = const Duration(seconds: 5),
    this.pollInterval = const Duration(seconds: 15),
    this.stopGrace = const Duration(seconds: 15),
    DateTime Function()? clock,
  })  : _adb = adb,
        _logger = logger,
        _clock = clock ?? DateTime.now;

  /// The adb serial of the device.
  final String deviceId;

  /// Where the pulled segments are saved.
  final String outputDir;

  /// Whether to record video; the contention watch runs either way.
  final bool record;

  /// The `screenrecord --time-limit` of each segment (Android caps it at 180 s).
  final Duration segmentLimit;

  /// A segment that ends sooner than this without being stopped failed to record; the chain stops.
  final Duration minimumSegment;

  /// How often the device is checked for screenrecord processes the leg did not start.
  final Duration pollInterval;

  /// How long [stop] waits for the device to finish the current segment before it cancels adb.
  final Duration stopGrace;

  final AndroidAdbCall _adb;
  final MplatrolLogger _logger;
  final DateTime Function() _clock;
  final _stopRequested = Completer<void>();
  final _cancelAdb = Completer<void>();
  final _pulls = <Future<String?>>[];
  final _contention = <String>[];
  var _maxForeign = 0;
  String? _activeSegment;
  Future<void>? _chain;
  Future<void>? _watch;
  late final String _stamp = _clock().toIso8601String().replaceAll(RegExp('[:.]'), '-');

  bool get _stopped => _stopRequested.isCompleted;

  /// Checks the device for other recorders, then starts the segment chain and the contention watch.
  Future<void> start() async {
    await _checkForeign('at leg start');
    if (record) {
      Directory(outputDir).createSync(recursive: true);
      _logger.info('[android-video] recording $deviceId in ${segmentLimit.inSeconds}s segments to $outputDir');
      _chain = _recordSegments();
    }
    _watch = _watchForeign();
  }

  /// Stops the current segment (SIGINT, so it is finalized), waits for every pull, logs the saved
  /// segments and returns them with the contention warnings.
  Future<AndroidRecording> stop() async {
    if (!_stopped) {
      _stopRequested.complete();
    }
    final active = _activeSegment;
    if (active != null) {
      await _adb(['shell', 'pkill', '-2', '-f', _recorderOf(active)], timeout: const Duration(seconds: 5));
    }
    final cancel = Timer(stopGrace, () => _cancelAdb.isCompleted ? null : _cancelAdb.complete());
    await _chain;
    cancel.cancel();
    await _watch;
    final segments = (await Future.wait(_pulls)).whereType<String>().toList();
    if (record) {
      _logSegments(segments);
    }
    return (segments: segments, contention: List<String>.unmodifiable(_contention));
  }

  void _logSegments(List<String> segments) {
    if (segments.isEmpty) {
      _logger.warn('[android-video] no video segment was saved for $deviceId');
      return;
    }
    _logger.info('[android-video] saved ${segments.length} segment(s) covering the leg, in order:');
    for (final segment in segments) {
      _logger.info('[android-video]   $segment');
    }
  }

  Future<void> _recordSegments() async {
    var timedOutBefore = false;
    for (var index = 1; !_stopped; index++) {
      final remote = '$_remotePrefix$_stamp-seg${index.toString().padLeft(2, '0')}.mp4';
      _activeSegment = remote;
      final startedAt = _clock();
      final result = await _adb(['shell', 'screenrecord', '--time-limit', '${segmentLimit.inSeconds}', remote],
          timeout: segmentLimit + const Duration(seconds: 30), cancelOn: _cancelAdb.future);
      final stopped = _stopped;
      if (result.exitCode != 0) {
        await _endOnDevice(remote);
      }
      _activeSegment = null;
      _pulls.add(_pull(remote, index));
      if (stopped) {
        return;
      }
      final lasted = _clock().difference(startedAt);
      final timedOut = result.exitCode != 0 && lasted >= segmentLimit;
      if (timedOut && !timedOutBefore) {
        timedOutBefore = true;
        _logger.warn('[android-video] segment $index did not end after ${lasted.inSeconds}s; stopped it on '
                '$deviceId and started the next. ${result.errText.trim()}'
            .trim());
        continue;
      }
      if (result.exitCode != 0 || lasted < minimumSegment) {
        _logger.warn('[android-video] segment $index ended after ${lasted.inSeconds}s (exit ${result.exitCode}); '
                'recording stops here. ${result.errText.trim()}'
            .trim());
        return;
      }
      timedOutBefore = false;
    }
  }

  /// Stops the device-side recorder writing [remote]: SIGINT so the file is finalized, then SIGKILL after
  /// [stopGrace] in case it hangs. Killing the host adb leaves it running on the device. The exit codes
  /// are ignored: `adb shell pkill -2` returns 130 on the Android 16 emulator whether or not it matched.
  Future<void> _endOnDevice(String remote) async {
    await _adb(['shell', 'pkill', '-2', '-f', _recorderOf(remote)], timeout: const Duration(seconds: 5));
    await Future<void>.delayed(stopGrace);
    await _adb(['shell', 'pkill', '-9', '-f', _recorderOf(remote)], timeout: const Duration(seconds: 5));
  }

  /// Pulls segment [index] from [remote] and removes it from the device; the local path, or null when
  /// nothing was saved.
  Future<String?> _pull(String remote, int index) async {
    final device = deviceId.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');
    final local = p.join(outputDir, 'android-$device-$_stamp-seg${index.toString().padLeft(2, '0')}.mp4');
    final pull = await _adb(['pull', remote, local], timeout: const Duration(minutes: 2));
    await _adb(['shell', 'rm', '-f', remote], timeout: const Duration(seconds: 10));
    final file = File(local);
    if (pull.exitCode == 0 && file.existsSync() && file.lengthSync() > 0) {
      return local;
    }
    _logger.warn('[android-video] could not pull segment $index ($remote): ${pull.errText.trim()}');
    return null;
  }

  Future<void> _watchForeign() async {
    while (!_stopped) {
      final wake = Completer<void>();
      final timer = Timer(pollInterval, wake.complete);
      await Future.any([wake.future, _stopRequested.future]);
      timer.cancel();
      if (_stopped) {
        return;
      }
      await _checkForeign('during the leg');
    }
  }

  /// Stops mplatrol's own leftover recorders and logs a contention warning when more screenrecord processes
  /// of other adb clients run on the device than the last warning counted.
  Future<void> _checkForeign(String when) async {
    final ps = await _adb(['shell', 'ps', '-A', '-o', 'ARGS'], timeout: const Duration(seconds: 5));
    final recorders = ps.exitCode == 0 ? screenrecordCommandLines(ps.outText) : const <String>[];
    final active = _activeSegment;
    final leftovers = {
      for (final line in recorders)
        if (_ownFile.firstMatch(line)?[0] case final file? when file != active) file,
    };
    for (final file in leftovers) {
      await _stopLeftover(file);
    }
    final foreign = recorders.where((line) => !_ownFile.hasMatch(line)).length;
    if (foreign <= _maxForeign) {
      return;
    }
    _maxForeign = foreign;
    final line = '[local-device] $localDeviceContentionMarker: $foreign screenrecord process(es) on $deviceId '
        '$when that this leg did not start: another adb client is using the leased device. Stop it; dozens of '
        "recorders exhaust the emulator's binder buffers and crash its system server.";
    _logger.warn(line);
    _contention.add(line);
  }

  /// Kills mplatrol's leftover recorder writing [file]; a file of an earlier leg is removed as well (this
  /// leg's own files are pulled and removed by their segment).
  Future<void> _stopLeftover(String file) async {
    await _adb(['shell', 'pkill', '-9', '-f', _recorderOf(file)], timeout: const Duration(seconds: 5));
    final earlierLeg = !file.startsWith('$_remotePrefix$_stamp-');
    if (earlierLeg) {
      await _adb(['shell', 'rm', '-f', file], timeout: const Duration(seconds: 10));
    }
    _logger.info('[android-video] stopped a leftover mplatrol screenrecord on $deviceId writing $file'
        '${earlierLeg ? ' (from an earlier leg; file removed)' : ''}; not another adb client');
  }
}

const _remotePrefix = '/sdcard/mplatrol-e2e-';

/// The quoted `pkill -f`/`pgrep -f` pattern of the screenrecord writing [file]. The bracket keeps it from
/// matching the device shell that runs the command, whose own command line contains the pattern.
String _recorderOf(String file) => "'[s]creenrecord.*$file'";
final _ownFile = RegExp(r'/sdcard/mplatrol-e2e-\S+\.mp4');

/// The command lines of the `screenrecord` processes in `ps -A -o ARGS` [output].
List<String> screenrecordCommandLines(String output) => [
      for (final line in output.split('\n'))
        if (line.trim().split(RegExp(r'\s+')).first.split('/').last == 'screenrecord') line.trim(),
    ];
