import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';

/// [value] escaped for a TeamCity service message attribute: `|`, `'`, `[`,
/// `]`, newline and carriage return get a `|` prefix, and every other
/// non-ASCII character becomes `|0xXXXX`.
String escapeTeamCityValue(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    buffer.write(switch (rune) {
      0x7C => '||',
      0x27 => "|'",
      0x0A => '|n',
      0x0D => '|r',
      0x5B => '|[',
      0x5D => '|]',
      < 0x80 => String.fromCharCode(rune),
      _ => _unicodeEscape(rune),
    });
  }
  return buffer.toString();
}

String _unicodeEscape(int rune) {
  if (rune <= 0xFFFF) {
    return '|0x${rune.toRadixString(16).padLeft(4, '0')}';
  }
  final offset = rune - 0x10000;
  final high = 0xD800 + (offset >> 10);
  final low = 0xDC00 + (offset & 0x3FF);
  return '|0x${high.toRadixString(16)}|0x${low.toRadixString(16)}';
}

String _message(String name, Map<String, String> attributes) {
  final rendered = attributes.entries.map((entry) => "${entry.key}='${escapeTeamCityValue(entry.value)}'").join(' ');
  return '##teamcity[$name $rendered]';
}

/// The TeamCity service messages for [results] of one leg: a suite named after
/// the leg, a nested suite per test file, and per test its start, metadata,
/// failure or ignore, and finish with its duration. Every message carries the
/// leg's `flowId`, so legs that run in parallel never interleave.
List<String> teamCityTestMessages(List<ItTestResult> results) {
  if (results.isEmpty) {
    return const [];
  }
  final leg = results.first.leg;
  final flow = leg.suiteName.replaceAll(RegExp('[^A-Za-z0-9._-]+'), '-');
  String message(String name, Map<String, String> attributes) => _message(name, {...attributes, 'flowId': flow});
  final byFile = <String, List<ItTestResult>>{};
  for (final result in results) {
    byFile.putIfAbsent(result.file, () => []).add(result);
  }
  return [
    message('testSuiteStarted', {'name': leg.suiteName}),
    for (final MapEntry(key: file, value: tests) in byFile.entries) ...[
      message('testSuiteStarted', {'name': file}),
      for (final test in tests) ..._testMessages(test, message),
      message('testSuiteFinished', {'name': file}),
    ],
    message('testSuiteFinished', {'name': leg.suiteName}),
  ];
}

typedef _Message = String Function(String name, Map<String, String> attributes);

List<String> _testMessages(ItTestResult test, _Message message) {
  final name = test.name;
  return [
    message('testStarted', {'name': name, 'captureStandardOutput': 'false'}),
    for (final entry in test.metadata)
      message('testMetadata', {
        'testName': name,
        'name': entry.name,
        'value': entry.value,
        if (entry.link) 'type': 'link',
      }),
    ..._verdictMessages(test, message),
    message('testFinished', {
      'name': name,
      if (test.duration != null) 'duration': '${test.duration!.inMilliseconds}',
    }),
  ];
}

/// Like the JUnit report: only a failed category (`app-defect`,
/// `test-failure`) fails the test; every other non-pass is ignored with its
/// category first in the message, so blockers stay out of TeamCity's failed
/// count. [teamCityStatisticMessages] keeps a leg without a pass from going green.
List<String> _verdictMessages(ItTestResult test, _Message message) {
  final reason = test.reason ?? test.outcome.label;
  final category = test.category;
  if (category == ItResultCategory.pass) {
    return const [];
  }
  if (!category.failed) {
    return [
      message('testIgnored', {'name': test.name, 'message': '${test.categoryName}: $reason'})
    ];
  }
  return [
    message('testFailed', {
      'name': test.name,
      'message': '${test.categoryName}: $reason',
    }),
  ];
}

/// Run counts of [results], keyed by the TeamCity statistic name: `failed`
/// counts the failed categories only, NOT RUN tests count as skipped, and
/// `mplatrol.category.<name>` counts each category; [queueWait] is included
/// only when known.
Map<String, int> teamCityStatistics(List<ItTestResult> results,
    {required Duration duration, required int buildReuses, Duration? queueWait}) {
  int count(ItTestOutcome outcome) => results.where((result) => result.outcome == outcome).length;
  return {
    'mplatrol.total': results.length,
    'mplatrol.passed': count(ItTestOutcome.pass),
    'mplatrol.failed': results.where((result) => result.category.failed).length,
    'mplatrol.skipped': count(ItTestOutcome.notRun),
    'mplatrol.notVerified': count(ItTestOutcome.notVerified),
    'mplatrol.mocked': count(ItTestOutcome.mocked),
    'mplatrol.flakyRetried': results.where((result) => result.flaky).length,
    'mplatrol.durationSec': duration.inSeconds,
    if (queueWait != null) 'mplatrol.queueWaitSec': queueWait.inSeconds,
    'mplatrol.buildReuses': buildReuses,
    for (final MapEntry(:key, :value) in itCategoryCounts(results).entries) 'mplatrol.category.$key': value,
  };
}

/// One `buildStatisticValue` message per entry of [statistics], plus build
/// problems that keep a run without a verdict from going green: one when
/// [results] holds no pass and no failure at all, else one per leg with no
/// pass and no failure, naming its categories.
List<String> teamCityStatisticMessages(Map<String, int> statistics, List<ItTestResult> results) {
  final legs = <ItRunLeg, List<ItTestResult>>{};
  for (final result in results) {
    legs.putIfAbsent(result.leg, () => []).add(result);
  }
  bool unverified(List<ItTestResult> tests) =>
      !tests.any((test) => test.category == ItResultCategory.pass || test.category.failed);
  return [
    for (final MapEntry(:key, :value) in statistics.entries)
      _message('buildStatisticValue', {'key': key, 'value': '$value'}),
    if (unverified(results))
      _message('buildProblem', {
        'description': 'mplatrol executed no Patrol test (${results.length} result(s), '
            'none passed or failed); the run is not verified.',
        'identity': 'mplatrol-no-executed-tests',
      })
    else
      for (final MapEntry(key: leg, value: tests) in legs.entries)
        if (unverified(tests))
          _message('buildProblem', {
            'description': '${leg.suiteName}: no test passed or failed (${_categoryList(tests)}); '
                'the leg is not verified.',
            'identity': 'mplatrol-unverified-${leg.tenant}-${leg.variant}',
          }),
  ];
}

String _categoryList(List<ItTestResult> tests) =>
    [for (final MapEntry(:key, :value) in itCategoryCounts(tests).entries) '$value $key'].join(', ');
