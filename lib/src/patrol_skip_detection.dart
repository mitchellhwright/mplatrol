/// Summary of skipped tests observed in Patrol or instrumentation output.
class PatrolSkipSummary {
  const PatrolSkipSummary({required this.hasSkippedTests, required this.count});

  final bool hasSkippedTests;
  final int? count;

  String get countLabel => count == null ? 'one or more' : count.toString();
}

final _patrolSkippedSummary = RegExp(
  r'\bSkipped:\s*([1-9][0-9]*)\b',
  caseSensitive: false,
);
final _explicitSkipMarker = RegExp(r'\bMPLATROL_TEST_SKIPPED\b');
final _testSkippedException = RegExp(
  r'\b(TestSkippedException|markTestSkipped)\b',
  caseSensitive: false,
);

/// Returns whether [output] proves Patrol skipped at least one test.
PatrolSkipSummary patrolSkipSummary(String output) {
  final summaryMatch = _patrolSkippedSummary.firstMatch(output);
  if (summaryMatch != null) {
    return PatrolSkipSummary(
      hasSkippedTests: true,
      count: int.tryParse(summaryMatch.group(1)!),
    );
  }
  if (_explicitSkipMarker.hasMatch(output) || _testSkippedException.hasMatch(output)) {
    return const PatrolSkipSummary(hasSkippedTests: true, count: null);
  }
  return const PatrolSkipSummary(hasSkippedTests: false, count: null);
}

final _patrolFailedSummary = RegExp(r'\bFailed:\s*[1-9][0-9]*\b');

/// Returns whether [output] contains Patrol's test summary with at least one
/// failed test, i.e. the tests ran and failed on their own rather than the
/// run breaking before results were reported.
bool patrolReportedTestFailures(String output) => _patrolFailedSummary.hasMatch(output);
