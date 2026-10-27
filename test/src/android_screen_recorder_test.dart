import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_screen_recorder.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

ProcessResultX _result({int exitCode = 0, String stdout = '', String stderr = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: stderr);

/// A fake device: each `screenrecord` segment lasts until [endSegment] or the recorder's SIGINT pkill
/// (unless [hangs]), a `pull` writes [pulledBytes] to the local path, and `ps` lists [processes].
class _FakeAdb {
  final calls = <List<String>>[];
  DateTime now = DateTime(2026, 10, 6, 3, 25);
  Duration segmentLength = const Duration(seconds: 180);
  List<String> processes = [];
  bool hangs = false;
  int pulledBytes = 3;
  int screenrecordExit = 0;
  Completer<void>? _segment;
  final segmentStarted = StreamController<int>.broadcast();
  var _segments = 0;

  DateTime clock() => now;

  void endSegment() {
    final segment = _segment;
    if (segment != null && !segment.isCompleted) {
      segment.complete();
    }
  }

  Future<ProcessResultX> call(List<String> arguments, {required Duration timeout, Future<void>? cancelOn}) async {
    calls.add(arguments);
    if (arguments[1] == 'screenrecord') {
      final segment = _segment = Completer<void>();
      segmentStarted.add(++_segments);
      final cancelled =
          await Future.any([segment.future.then((_) => false), if (cancelOn != null) cancelOn.then((_) => true)]);
      now = now.add(segmentLength);
      if (cancelled) {
        return _result(exitCode: 75, stderr: 'Stopped by caller');
      }
      return _result(exitCode: screenrecordExit, stderr: screenrecordExit == 0 ? '' : 'screenrecord failed');
    }
    if (arguments.contains('pkill')) {
      if (!hangs && arguments.contains('-2')) {
        endSegment();
      }
      return _result(exitCode: 130);
    }
    if (arguments.first == 'pull') {
      if (pulledBytes > 0) {
        File(arguments[2]).writeAsBytesSync(List.filled(pulledBytes, 1));
        return _result();
      }
      return _result(exitCode: 1, stderr: 'remote object does not exist');
    }
    if (arguments.contains('ps')) {
      return _result(stdout: ['ARGS', 'init second_stage', '[kthreadd]', ...processes].join('\n'));
    }
    return _result();
  }
}

void main() {
  late Directory output;
  late _MockLogger logger;
  late _FakeAdb adb;

  setUp(() {
    output = Directory.systemTemp.createTempSync('recorder');
    logger = _MockLogger();
    adb = _FakeAdb();
  });

  tearDown(() => output.deleteSync(recursive: true));

  AndroidScreenRecorder recorder({bool record = true, Duration poll = const Duration(hours: 1)}) =>
      AndroidScreenRecorder(
        deviceId: 'emulator-5554',
        outputDir: p.join(output.path, 'video'),
        adb: adb.call,
        logger: logger,
        record: record,
        pollInterval: poll,
        stopGrace: const Duration(milliseconds: 50),
        clock: adb.clock,
      );

  test('chains segments for the whole leg, pulls each and lists them in order', () async {
    final started = adb.segmentStarted.stream.take(3).toList();
    final subject = recorder();
    await subject.start();
    await pumpEventQueue();
    adb.endSegment();
    await pumpEventQueue();
    adb.endSegment();
    await pumpEventQueue();
    expect(await started, [1, 2, 3]);

    final recording = await subject.stop();

    expect(recording.segments.map(p.basename), [
      'android-emulator-5554-2026-10-06T03-25-00-000-seg01.mp4',
      'android-emulator-5554-2026-10-06T03-25-00-000-seg02.mp4',
      'android-emulator-5554-2026-10-06T03-25-00-000-seg03.mp4',
    ]);
    expect(recording.contention, isEmpty);
    expect(adb.calls.where((call) => call[1] == 'screenrecord').first,
        ['shell', 'screenrecord', '--time-limit', '180', '/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg01.mp4']);
    const last = '/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg03.mp4';
    expect(adb.calls, contains(equals(['shell', 'pkill', '-2', '-f', "'[s]creenrecord.*$last'"])));
    expect(
        adb.calls, contains(equals(['shell', 'rm', '-f', '/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg01.mp4'])));
    verify(() => logger.info(any(that: contains('saved 3 segment(s) covering the leg')))).called(1);
  });

  test('stops the chain when a segment ends early and says so', () async {
    adb
      ..segmentLength = const Duration(seconds: 1)
      ..screenrecordExit = 1;
    final subject = recorder();
    await subject.start();
    await pumpEventQueue();
    adb.endSegment();
    await pumpEventQueue();

    final recording = await subject.stop();

    expect(adb.calls.where((call) => call[1] == 'screenrecord'), hasLength(1));
    expect(recording.segments, hasLength(1));
    verify(() => logger.warn('[android-video] segment 1 ended after 1s (exit 1); recording stops here. '
        'screenrecord failed')).called(1);
  });

  test('warns when nothing could be pulled', () async {
    adb.pulledBytes = 0;
    final subject = recorder();
    await subject.start();
    await pumpEventQueue();

    final recording = await subject.stop();

    expect(recording.segments, isEmpty);
    verify(() => logger.warn(any(that: contains('could not pull segment 1')))).called(1);
    verify(() => logger.warn('[android-video] no video segment was saved for emulator-5554')).called(1);
  });

  test('cancels adb when the device does not end the segment after the stop', () async {
    adb.hangs = true;
    final subject = recorder();
    await subject.start();
    await pumpEventQueue();
    adb.calls.clear();

    await subject.stop().timeout(const Duration(seconds: 5));

    const segment = "'[s]creenrecord.*/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg01.mp4'";
    expect(adb.calls.first, ['shell', 'pkill', '-2', '-f', segment]);
    expect(adb.calls, contains(equals(['shell', 'pkill', '-9', '-f', segment])),
        reason: 'a segment adb gave up on is killed on the device, so it cannot outlive the leg');
  });

  test('without recording it only watches for other recorders, and warns once per new high', () async {
    adb.processes = ['screenrecord /sdcard/a.mp4', 'screenrecord /sdcard/b.mp4', '/system/bin/screenrecord c.mp4'];
    final subject = recorder(record: false, poll: const Duration(milliseconds: 10));
    await subject.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    adb.processes = [...adb.processes, 'screenrecord --bugreport /sdcard/d.mp4'];
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final recording = await subject.stop();

    expect(adb.calls.where((call) => call[1] == 'screenrecord'), isEmpty);
    const first = '[local-device] LOCAL_DEVICE_CONTENTION: 3 screenrecord process(es) on emulator-5554 at leg start '
        'that this leg did not start: another adb client is using the leased device. Stop it; dozens of recorders '
        "exhaust the emulator's binder buffers and crash its system server.";
    expect(recording.contention, [
      first,
      contains('4 screenrecord process(es) on emulator-5554 during the leg'),
    ]);
    verify(() => logger.warn(any(that: contains('LOCAL_DEVICE_CONTENTION')))).called(2);
    verifyNever(() => logger.info(any(that: contains('[android-video]'))));
  });

  test('does not count its own segment as another recorder', () async {
    final subject = recorder(poll: const Duration(milliseconds: 10));
    await subject.start();
    adb.processes = ['screenrecord --time-limit 180 /sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg01.mp4'];
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final recording = await subject.stop();

    expect(recording.contention, isEmpty);
    expect(adb.calls.where((call) => call.contains('-9')), isEmpty);
  });

  test('stops a segment adb timed out on, on the device too, then records the next once', () async {
    adb
      ..segmentLength = const Duration(seconds: 210)
      ..screenrecordExit = 75;
    final started = adb.segmentStarted.stream.take(2).toList();
    final subject = recorder();
    await subject.start();
    await pumpEventQueue();
    adb.endSegment();
    expect(await started, [1, 2]);
    adb.endSegment();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final recording = await subject.stop();

    const seg01 = "'[s]creenrecord.*/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg01.mp4'";
    const seg02 = "'[s]creenrecord.*/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg02.mp4'";
    final kills = adb.calls.where((call) => call.contains('pkill')).toList();
    expect(kills.take(2), [
      ['shell', 'pkill', '-2', '-f', seg01],
      ['shell', 'pkill', '-9', '-f', seg01],
    ]);
    expect(kills, contains(equals(['shell', 'pkill', '-9', '-f', seg02])));
    expect(adb.calls.where((call) => call[1] == 'screenrecord'), hasLength(2),
        reason: 'a second timeout in a row stops the chain');
    expect(recording.segments, hasLength(2));
    verify(() => logger.warn('[android-video] segment 1 did not end after 210s; stopped it on emulator-5554 and '
        'started the next. screenrecord failed')).called(1);
    verify(() => logger.warn(any(that: contains('segment 2 ended after 210s (exit 75); recording stops here'))))
        .called(1);
  });

  test("stops mplatrol's own leftover recorders instead of reporting them as another adb client", () async {
    const earlier = '/sdcard/mplatrol-e2e-2026-10-05T01-00-00-000-seg04.mp4';
    const ownOrphan = '/sdcard/mplatrol-e2e-2026-10-06T03-25-00-000-seg00.mp4';
    adb.processes = [
      'screenrecord --time-limit 180 $earlier',
      'screenrecord --time-limit 180 $ownOrphan',
      'screenrecord /sdcard/someone-else.mp4',
    ];
    final subject = recorder(record: false);
    await subject.start();

    final recording = await subject.stop();

    expect(adb.calls, contains(equals(['shell', 'pkill', '-9', '-f', "'[s]creenrecord.*$earlier'"])));
    expect(adb.calls, contains(equals(['shell', 'rm', '-f', earlier])));
    expect(adb.calls, contains(equals(['shell', 'pkill', '-9', '-f', "'[s]creenrecord.*$ownOrphan'"])));
    expect(adb.calls, isNot(contains(equals(['shell', 'rm', '-f', ownOrphan]))));
    expect(recording.contention, [contains('1 screenrecord process(es) on emulator-5554 at leg start')]);
    verify(() => logger.info('[android-video] stopped a leftover mplatrol screenrecord on emulator-5554 writing '
        '$earlier (from an earlier leg; file removed); not another adb client')).called(1);
    verify(() => logger.info(any(that: contains('writing $ownOrphan; not another adb client')))).called(1);
  });

  test('reads screenrecord command lines from ps, not shells or other tools that name it', () {
    expect(
        screenrecordCommandLines('ARGS\n[kthreadd]\n  screenrecord --time-limit 180 /sdcard/x.mp4\n'
            '/system/bin/screenrecord y.mp4\nsh -c screenrecord z.mp4\npkill -f screenrecord\n'),
        ['screenrecord --time-limit 180 /sdcard/x.mp4', '/system/bin/screenrecord y.mp4']);
    expect(screenrecordCommandLines(''), isEmpty);
  });
}
