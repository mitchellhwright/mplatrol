import 'dart:convert';

import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';

/// One test verdict Patrol printed for a local run. A failure's [reason] is its exception message on one
/// line; [details] is the whole failure block Patrol printed under it (message, stack and test description).
typedef PatrolConsoleResult = ({
  String id,
  ItTestOutcome outcome,
  Duration? duration,
  String? reason,
  String? details,
});

final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final _verdictLine = RegExp(r'^\s*(✅|❌|⏩)\s+(.+?)(?:\s+\(([^()\s]+\.dart)\))?(?:\s+\((\d+)s\))?\s*$');

/// The Dart test name every local result is reported by: `<file> <description>`.
String patrolDartTestName(PatrolTestFile file, PatrolTest test) => '${file.basename} ${test.description}';

/// The tests of [files] as report selections, under their Dart test names.
List<ItSelectedTest> patrolSelectedTests(List<PatrolTestFile> files) => [
      for (final file in files)
        for (final test in file.tests)
          ItSelectedTest(id: patrolDartTestName(file, test), file: file.basename, description: test.description),
    ];

/// The per-test verdicts Patrol printed in a local run's [output]: the
/// `✅`/`❌`/`⏩` lines of its log reader, matched to the selected [files] by
/// description (and file, when the line names it). A failure carries the
/// exception message and the failure block Patrol printed under it; a skip is NOT RUN, never a pass.
List<PatrolConsoleResult> parsePatrolConsoleResults(String output, List<PatrolTestFile> files) {
  final lines = output.replaceAll(_ansi, '').split('\n');
  final results = <PatrolConsoleResult>[];
  for (final (index, line) in lines.indexed) {
    final match = _verdictLine.firstMatch(line);
    final id = match == null ? null : _matchTest(match[2]!.trim(), match[3], files);
    if (id == null) {
      continue;
    }
    final seconds = int.tryParse(match![4] ?? '');
    final failure = match[1] == '❌' ? _failureAfter(lines, index) : null;
    results.add((
      id: id,
      outcome: switch (match[1]) {
        '✅' => ItTestOutcome.pass,
        '❌' => ItTestOutcome.fail,
        _ => ItTestOutcome.notRun,
      },
      duration: seconds == null ? null : Duration(seconds: seconds),
      reason: switch (match[1]) {
        '❌' => failure?.message ?? 'Patrol reported the test failed',
        '⏩' => itRuntimeSkipReason,
        _ => null,
      },
      details: failure?.details,
    ));
  }
  return results;
}

String? _matchTest(String name, String? path, List<PatrolTestFile> files) {
  for (final file in files) {
    if (path != null && path.split('/').last != '${file.basename}.dart') {
      continue;
    }
    for (final test in file.tests) {
      if (name == test.description || name.endsWith(' ${test.description}')) {
        return patrolDartTestName(file, test);
      }
    }
  }
  return null;
}

const _maxMessageLength = 300;
const _maxDetailLines = 80;
const _maxDetailLength = 8000;

/// The failure block Patrol printed after the verdict line at [index], up to the next test, verdict or
/// summary: its exception [message] (Patrol wraps it over several lines; joined here, without the
/// `EXCEPTION CAUGHT` banner and the "The following … was thrown" header) and the whole block as
/// [details], bounded. Null when Patrol printed nothing under the verdict.
({String message, String details})? _failureAfter(List<String> lines, int index) {
  final block = <String>[];
  for (final line in lines.skip(index + 1)) {
    final text = line.trimRight();
    if (_verdictLine.hasMatch(line) || text.trimLeft().startsWith('🧪') || text.trim() == 'Test summary:') {
      break;
    }
    if (!_banner.hasMatch(text)) {
      block.add(text);
    }
  }
  while (block.isNotEmpty && block.last.trim().isEmpty) {
    block.removeLast();
  }
  while (block.isNotEmpty && block.first.trim().isEmpty) {
    block.removeAt(0);
  }
  if (block.isEmpty) {
    return null;
  }
  final message = <String>[];
  for (final line in block) {
    final text = line.trim();
    if (_thrownHeader.hasMatch(text) && message.isEmpty) {
      continue;
    }
    if (text.isEmpty || _stackStart.hasMatch(text)) {
      break;
    }
    message.add(text);
  }
  final joined = message.isEmpty ? block.first.trim() : message.join(' ');
  final kept = block.length > _maxDetailLines
      ? [...block.take(_maxDetailLines), '… ${block.length - _maxDetailLines} more line(s) in the build log']
      : block;
  final details = kept.join('\n');
  return (
    message: joined.length > _maxMessageLength ? '${joined.substring(0, _maxMessageLength)}...' : joined,
    details: details.length > _maxDetailLength ? '${details.substring(0, _maxDetailLength)}...' : details,
  );
}

final _banner = RegExp(r'^\s*(?:═+╡.*╞═*|═{5,})\s*$');
final _thrownHeader = RegExp('^The following .+ was thrown');
final _stackStart = RegExp(r'^(?:#\d+\s|When the exception was thrown|<asynchronous suspension>)');

/// The reasons iOS gave for the tests it skipped, by Dart test name, from the xcresult action log that a local
/// iOS run appends to its [output] (`xcresulttool get log --type action`, one JSON line): each
/// `Run test case test<prefix><Description>()` section carries `Test skipped - <CODE> <reason>`.
///
/// Patrol's iOS console prints only `⏩ <test>`, so without these the reason a test gave (e.g.
/// `DEVICE_NO_BIOMETRICS ...`) is lost and the skip counts as one without a known cause.
Map<String, String> iosSkipReasons(String output, List<PatrolTestFile> files) {
  final skips = <String, String>{};
  for (final line in output.split('\n')) {
    if (!line.startsWith('{') || !line.contains('Test skipped - ')) {
      continue;
    }
    try {
      _collectIosSkips(jsonDecode(line), skips);
    } on FormatException {
      continue;
    }
  }
  final reasons = <String, String>{};
  for (final file in files) {
    for (final test in file.tests) {
      final method = '${_iosCamelCase(test.description)}()';
      for (final MapEntry(key: title, value: reason) in skips.entries) {
        if (title.endsWith(method)) {
          reasons[patrolDartTestName(file, test)] = reason;
        }
      }
    }
  }
  return reasons;
}

void _collectIosSkips(Object? section, Map<String, String> skips) {
  if (section is! Map<String, dynamic>) {
    return;
  }
  final title = section['title'];
  final messages = section['messages'];
  if (title is String && title.startsWith('Run test case ') && messages is List) {
    for (final message in messages.whereType<Map<String, dynamic>>()) {
      final text = message['title'];
      if (text is String && text.startsWith('Test skipped - ')) {
        skips[title] = text.substring('Test skipped - '.length).trim();
      }
    }
  }
  final subsections = section['subsections'];
  if (subsections is List) {
    for (final subsection in subsections) {
      _collectIosSkips(subsection, skips);
    }
  }
}

/// A description as Patrol's iOS test method names it: its alphanumeric words, each capitalised, joined.
String _iosCamelCase(String description) => description
    .split(RegExp('[^A-Za-z0-9]+'))
    .where((word) => word.isNotEmpty)
    .map((word) => word[0].toUpperCase() + word.substring(1))
    .join();
