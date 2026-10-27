import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:test/test.dart';

void main() {
  group('PatrolSkipSummary.countLabel', () {
    test('returns "one or more" when count is null', () {
      const summary = PatrolSkipSummary(hasSkippedTests: true, count: null);
      expect(summary.countLabel, 'one or more');
    });

    test('returns the count as a string when count is set', () {
      const summary = PatrolSkipSummary(hasSkippedTests: true, count: 3);
      expect(summary.countLabel, '3');
    });
  });

  group('patrolSkipSummary', () {
    test('detects a "Skipped: N" summary line and returns its count', () {
      const output = 'Tests run: 5, Failures: 0, Errors: 0, Skipped: 2';

      final result = patrolSkipSummary(output);

      expect(result.hasSkippedTests, isTrue);
      expect(result.count, 2);
    });

    test('detects an explicit MPLATROL_TEST_SKIPPED marker', () {
      const output = 'Some output MPLATROL_TEST_SKIPPED and more';

      final result = patrolSkipSummary(output);

      expect(result.hasSkippedTests, isTrue);
      expect(result.count, isNull);
    });

    test('an app-specific skip line without the mplatrol marker is not a skip', () {
      const output = 'VIDEOSDK_SMOKE_SKIPPED: videosdk sdk not configured';

      expect(patrolSkipSummary(output).hasSkippedTests, isFalse);
    });

    test('detects a TestSkippedException reference', () {
      const output = 'Caused by: TestSkippedException: login skipped';

      final result = patrolSkipSummary(output);

      expect(result.hasSkippedTests, isTrue);
      expect(result.count, isNull);
    });

    test('returns hasSkippedTests false when no skip signal is present', () {
      const output = 'Tests run: 5, Failures: 0, Errors: 0, Skipped: 0';

      final result = patrolSkipSummary(output);

      expect(result.hasSkippedTests, isFalse);
      expect(result.count, isNull);
    });
  });
}
