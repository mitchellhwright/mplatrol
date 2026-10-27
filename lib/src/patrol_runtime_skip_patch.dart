import 'dart:io';

import 'package:mplatrol/src/ci_report/it_test_result.dart';

const patrolRuntimeSkipSources = <String, String>{
  'global_state': 'lib/src/global_state.dart',
  'binding': 'lib/src/binding.dart',
  'mobile': 'lib/src/platform/mobile/patrol_app_service_io.dart',
  'web': 'lib/src/platform/web/patrol_app_service_web.dart',
};

/// Mobile sources compiled from the generated Patrol override, excluding web.
const patrolRuntimeSkipMobileInputs = <String>[
  '.mplatrol/patched_packages/patrol/lib/src/global_state.dart',
  '.mplatrol/patched_packages/patrol/lib/src/binding.dart',
  '.mplatrol/patched_packages/patrol/lib/src/platform/mobile/patrol_app_service_io.dart',
];

/// Checks all platform signatures before reusing a generated package copy.
///
/// Args:
///   packageRoot: Generated Patrol package directory.
///
/// Returns:
///   Whether all runtime-skip transformations are present exactly once.
bool hasPatrolRuntimeSkipPatch(Directory packageRoot) {
  try {
    for (final entry in patrolRuntimeSkipSources.entries) {
      final source = File('${packageRoot.path}/${entry.value}').readAsStringSync();
      if (!_runtimeSkipReplacements(entry.key).every((change) => change.$2.allMatches(source).length == 1)) {
        return false;
      }
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Preserves runtime skip identity in a generated Patrol package copy.
///
/// Args:
///   packageRoot: Generated copy, never the shared upstream package cache.
///
/// Throws:
///   FileSystemException: A required source file is missing.
///   StateError: Upstream anchors changed or a previous patch is incomplete.
void patchPatrolRuntimeSkip(Directory packageRoot) {
  final changes = <File, String>{};
  for (final entry in patrolRuntimeSkipSources.entries) {
    final file = File('${packageRoot.path}/${entry.value}');
    final before = file.readAsStringSync();
    final after = patchPatrolRuntimeSkipSource(entry.key, before);
    if (before != after) {
      changes[file] = after;
    }
  }
  for (final entry in changes.entries) {
    entry.key.writeAsStringSync(entry.value);
  }
}

/// Patches actual Patrol completion code without changing discovery-time skips.
///
/// Args:
///   kind: One of the keys in [patrolRuntimeSkipSources].
///   source: Current Patrol source text.
///
/// Returns:
///   Idempotently patched source: a skip before any error is a skip, any other error a failure.
///
/// Throws:
///   StateError: Required anchors are missing or ambiguous.
String patchPatrolRuntimeSkipSource(String kind, String source) {
  final replacements = _runtimeSkipReplacements(kind);
  _rejectIncompleteRuntimeSkipPatch(kind, source, replacements);
  var result = source;
  for (final (before, after) in replacements) {
    if (after.allMatches(result).length == 1) {
      continue;
    }
    if (before.allMatches(result).length != 1) {
      throw StateError('Patrol runtime-skip $kind source changed near "$before"; '
          'regenerate from pristine source and review completion semantics');
    }
    result = result.replaceFirst(before, after);
  }
  return result;
}

void _rejectIncompleteRuntimeSkipPatch(String kind, String source, List<(String, String)> replacements) {
  final complete = replacements.every((change) => change.$2.allMatches(source).length == 1);
  final marker = switch (kind) {
    'global_state' => 'bool get isCurrentTestSkipped',
    'binding' => '\n            skipped:',
    _ => 'final bool skipped;',
  };
  if (!complete && (source.contains(marker) || replacements.any((change) => source.contains(change.$2)))) {
    throw StateError('Patrol runtime-skip $kind patch is incomplete; regenerate from pristine source');
  }
}

List<(String, String)> _runtimeSkipReplacements(String kind) => switch (kind) {
      'global_state' => _globalChanges,
      'binding' => _bindingChanges,
      'mobile' => _serviceChanges('testExecutionResult'),
      'web' => _serviceChanges('result'),
      _ => throw StateError('Unknown Patrol runtime-skip source: $kind'),
    };

const _globalChanges = <(String, String)>[
  (
    "import 'common.dart';",
    '// Result identity is required; isPassing also includes skipped tests.\n'
        '// ignore: implementation_imports\n'
        "import 'package:test_api/src/backend/state.dart';\n\nimport 'common.dart';",
  ),
  (
    "import 'package:test_api/src/backend/live_test.dart';",
    "import 'package:flutter/foundation.dart' show FlutterErrorDetails;\n"
        "import 'package:test_api/src/backend/live_test.dart';\n\n"
        '// The markTestSkipped reason travels only as a message on the live test.\n'
        '// ignore: implementation_imports\n'
        "import 'package:test_api/src/backend/message.dart';",
  ),
  (
    '''bool get isCurrentTestPassing {
  return Invoker.current!.liveTest.state.result.isPassing;
}''',
    '''bool get isCurrentTestPassing {
  return Invoker.current!.liveTest.state.result.isPassing;
}

/// Returns whether the current test was skipped rather than passed or failed.
///
/// A test that skipped itself before any error stays skipped when an error
/// follows (an unawaited app exception): it never ran its checks. A skip
/// after an error is that failure.
bool get isCurrentTestSkipped {
  return _skippedBeforeError ??
      Invoker.current!.liveTest.state.result == Result.skipped;
}

/// Whether the current test has raised no error. A skip after an error
/// resets the test's result to skipped, which isPassing counts as passing.
bool get currentTestHasNoErrors => Invoker.current!.liveTest.errors.isEmpty;

String? _currentTestSkipReason;
bool? _skippedBeforeError;

/// The reason the current test gave `markTestSkipped`, with the first error
/// raised after the skip; null when it gave none.
String? get currentTestSkipReason {
  final error = currentTestErrorDetails;
  return _currentTestSkipReason == null || error == null
      ? _currentTestSkipReason
      : '\$_currentTestSkipReason (an error followed the skip: \$error)';
}

/// The current test's first error, on one line with its first stack frames,
/// or null without one. flutter_test records a widget test's failure as a
/// FlutterErrorDetails, whose toString() is only "Instance of
/// 'FlutterErrorDetails'"; its exception text is reported instead.
/// Patrol has no failure details for an error outside the test body.
String? get currentTestErrorDetails {
  final errors = Invoker.current!.liveTest.errors;
  if (errors.isEmpty) {
    return null;
  }
  final first = errors.first;
  final error = first.error;
  final text = error is FlutterErrorDetails ? error.exceptionAsString() : error.toString();
  final stack = (error is FlutterErrorDetails ? error.stack : null) ?? first.stackTrace;
  final frames = stack.toString().split('\\n').map((line) => line.trim()).where((line) => line.isNotEmpty).take(3);
  final collapsed = text.trim().replaceAll(RegExp(r'\\s+'), ' ');
  final message = collapsed.length > 1200 ? '\${collapsed.substring(0, 1200)}...' : collapsed;
  return frames.isEmpty ? message : '\$message @ \${frames.join(' | ')}';
}

/// Records the current test's `markTestSkipped` reason, which Patrol reports
/// only for failures, so the native side can name why the test did not run.
void watchCurrentTestSkipReason() {
  _currentTestSkipReason = null;
  _skippedBeforeError = null;
  final liveTest = Invoker.current!.liveTest;
  liveTest.onMessage
      .where((message) => message.type == MessageType.skip)
      .listen((message) {
    _currentTestSkipReason = message.text;
    _skippedBeforeError ??= liveTest.errors.isEmpty;
  });
}''',
  ),
];

const _bindingChanges = <(String, String)>[
  (
    '            passed: passed,',
    '            passed: global_state.isCurrentTestSkipped ||\n'
        '                (passed && global_state.currentTestHasNoErrors),\n'
        '            skipped: global_state.isCurrentTestSkipped,',
  ),
  (
    '      _currentDartTest = global_state.currentTestFullName;',
    '      _currentDartTest = global_state.currentTestFullName;\n'
        '      global_state.watchCurrentTestSkipReason();',
  ),
  (
    '            details: _testResults[_currentDartTest!] is Failure\n'
        '                ? (_testResults[_currentDartTest!] as Failure?)?.details\n'
        '                : null,',
    '            details: global_state.isCurrentTestSkipped\n'
        '                ? global_state.currentTestSkipReason\n'
        '                : _testResults[_currentDartTest!] is Failure\n'
        '                    ? (_testResults[_currentDartTest!] as Failure?)?.details\n'
        '                    : global_state.currentTestErrorDetails,',
  ),
];

List<(String, String)> _serviceChanges(String result) => [
      (
        'const _TestExecutionResult({required this.passed, required this.details});',
        'const _TestExecutionResult({required this.passed, '
            'required this.skipped, required this.details});',
      ),
      ('  final bool passed;', '  final bool passed;\n  final bool skipped;'),
      (
        '    required bool passed,',
        '    required bool passed,\n    required bool skipped,',
      ),
      (
        '_TestExecutionResult(passed: passed, details: details)',
        '_TestExecutionResult(passed: passed, skipped: skipped, details: details)',
      ),
      (
        '    if (!$result.passed) {',
        '''    if ($result.passed && $result.skipped) {
      _patrolLog.log(
        TestEntry(name: request.name, status: TestEntryStatus.skip),
      );
      return RunDartTestResponse(
        result: RunDartTestResponseResult.skipped,
        details: $result.details ?? '$itGenericSkipDetail',
      );
    }
    if (!$result.passed) {''',
      ),
    ];
