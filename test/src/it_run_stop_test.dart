import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late _MockLogger logger;
  late StreamController<ProcessSignal> signals;
  late List<int> exits;
  late int stops;

  ItRunStop stopper({Duration deadline = const Duration(seconds: 45), Duration sweep = const Duration(seconds: 2)}) =>
      ItRunStop(
        signals: () => [signals.stream],
        stopChildren: () async => stops++,
        exitNow: exits.add,
        deadline: deadline,
        sweep: sweep,
      )..watch();

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  setUp(() {
    logger = _MockLogger();
    GetIt.I.registerSingleton<MplatrolLogger>(logger);
    signals = StreamController<ProcessSignal>.broadcast();
    exits = [];
    stops = 0;
  });
  tearDown(() async {
    await signals.close();
    await GetIt.I.reset();
  });

  test('is not stopping before a signal', () async {
    final stop = stopper();
    expect([stop.isStopping, stop.exitCode], [false, 0]);
    await stop.close();
  });

  for (final (signal, code) in [(ProcessSignal.sigterm, 143), (ProcessSignal.sigint, 130)]) {
    test('$signal asks the run to stop, stops its processes and ends it with $code', () async {
      final stop = stopper();
      signals.add(signal);
      await stop.requested;
      await settle();

      expect([stop.isStopping, stop.exitCode, stops], [true, code, 1]);
      expect(exits, isEmpty, reason: 'the run unwinds and reports before it exits');
      verify(() => logger.warn('[it-run] received $signal: stopping the running tests, then writing the results '
          '(a second signal exits at once).')).called(1);
      await stop.close();
    });
  }

  test('a second signal exits at once', () async {
    final stop = stopper();
    signals
      ..add(ProcessSignal.sigterm)
      ..add(ProcessSignal.sigint);
    await settle();

    expect(exits, [143]);
    verify(() => logger.err('[it-run] received SIGINT again: exiting now.')).called(1);
    await stop.close();
  });

  test('stops processes started meanwhile, and exits when stopping takes longer than the deadline', () async {
    final stop = stopper(deadline: const Duration(milliseconds: 60), sweep: const Duration(milliseconds: 20));
    signals.add(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(stops, greaterThan(1));
    expect(exits, [143]);
    verify(() => logger.err('[it-run] still stopping after 0s: exiting now.')).called(1);
    await stop.close();
  });

  test('close stops listening and cancels the deadline', () async {
    final stop = stopper(deadline: const Duration(milliseconds: 30), sweep: const Duration(milliseconds: 10));
    signals.add(ProcessSignal.sigterm);
    await settle();
    await stop.close();
    final swept = stops;
    signals.add(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(exits, isEmpty);
    expect(stops, swept);
  });

  test("names the signal behind a stopped run's exit code", () {
    expect([itRunStopSignal(143), itRunStopSignal(130), itRunStopSignal(1)], ['SIGTERM', 'SIGINT', null]);
    expect(itRunStoppedReason('SIGTERM'), 'stopped: the run received SIGTERM before this test finished');
  });

  test('the default stop listens to the process signals and stops nothing until one arrives', () async {
    final stop = ItRunStop()..watch();
    expect(stop.isStopping, isFalse);
    await stop.close();
  });
}
