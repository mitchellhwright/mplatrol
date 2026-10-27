import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mplatrol_harness/mplatrol_harness.dart';

void main() {
  group('NativeDialogWatchdog', () {
    test('logs dismissals and failures and stops on request', () async {
      final log = <String>[];
      final thirdProbe = Completer<void>();
      var calls = 0;
      final watchdog = NativeDialogWatchdog(
        interval: const Duration(milliseconds: 1),
        log: log.add,
        probe: () async {
          calls++;
          if (calls == 3) {
            thirdProbe.complete();
          }
          if (calls == 2) {
            throw StateError('boom');
          }
          return calls == 1;
        },
      );
      watchdog.start();
      watchdog.start();
      expect(watchdog.isActive, isTrue);
      await thirdProbe.future;
      watchdog.stop();
      expect(watchdog.isActive, isFalse);
      expect(log, contains('E2E_NATIVE_DIALOG_WATCHDOG_DISMISSED count=1'));
      expect(log, contains(startsWith('E2E_NATIVE_DIALOG_WATCHDOG_PROBE_FAILED count=1')));
      expect(watchdog.describe(), contains('dismissed=1 failures=1'));
    });
  });

  group('native deadlines', () {
    test('remainingNativeBudget rejects an expired deadline', () {
      expect(
        () => remainingNativeBudget(DateTime.now().subtract(const Duration(seconds: 1)), operation: 'probe'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('ceilToWholeMilliseconds rounds up partial milliseconds', () {
      expect(ceilToWholeMilliseconds(const Duration(microseconds: 1001)), const Duration(milliseconds: 2));
      expect(ceilToWholeMilliseconds(const Duration(milliseconds: 3)), const Duration(milliseconds: 3));
    });

    test('pollWithinDeadline returns null when the loop deadline expired', () async {
      final expired = DateTime.now().subtract(const Duration(seconds: 1));
      expect(await pollWithinDeadline<int>(() => throw TimeoutException('late'), expired), isNull);
    });

    test('pollWithinDeadline rethrows a timeout while budget remains', () {
      final later = DateTime.now().add(const Duration(minutes: 1));
      expect(pollWithinDeadline<int>(() => throw TimeoutException('early'), later), throwsA(isA<TimeoutException>()));
    });

    test('nativeWithinDeadline returns the result and leaves the transport usable', () async {
      final result = await nativeWithinDeadline(
        () async => 7,
        deadline: DateTime.now().add(const Duration(seconds: 5)),
        operation: 'probe',
      );
      expect(result, 7);
      expect(nativeOperationsUsable, isTrue);
      await awaitNativeCleanupReadiness(deadline: DateTime.now().add(const Duration(seconds: 1)));
    });
  });
}
