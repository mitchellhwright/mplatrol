import 'dart:io';

/// Device-log prefix of the line printed when formatting a test failure itself threw.
const patrolSafeFailureLogPrefix = 'MPLATROL_TEST_FAILURE_RAW';

/// Patrol source that gathers test failures, relative to the package root.
const patrolSafeFailureSourcePath = 'lib/src/binding.dart';

/// Whether the generated copy reports a failure's own exception when formatting it throws.
///
/// Args:
///   packageRoot: Generated Patrol package directory.
///
/// Returns:
///   Whether every safe-failure transformation is present exactly once.
bool hasPatrolSafeFailureReportPatch(Directory packageRoot) {
  try {
    final source = File('${packageRoot.path}/$patrolSafeFailureSourcePath').readAsStringSync();
    return _isComplete(source);
  } on FileSystemException {
    return false;
  }
}

/// Makes Patrol report a failure's own exception and stack when formatting the failure throws.
///
/// Args:
///   packageRoot: Generated copy, never the shared upstream package cache.
///
/// Throws:
///   FileSystemException: The binding source is missing.
///   StateError: Upstream anchors changed or a previous patch is incomplete.
void patchPatrolSafeFailureReport(Directory packageRoot) {
  final file = File('${packageRoot.path}/$patrolSafeFailureSourcePath');
  final before = file.readAsStringSync();
  final after = patchPatrolSafeFailureReportSource(before);
  if (before != after) {
    file.writeAsStringSync(after);
  }
}

/// Patches Patrol's binding so a failure that cannot be formatted is still reported.
///
/// On Android debug builds `FlutterErrorDetails.toString()` runs the widget inspector, which can
/// throw "Looking up a deactivated widget's ancestor is unsafe" once the failing widget is
/// disposed. Patrol then reported that error instead of the test's assertion (GLOBEX, 2026-10-14).
/// The patch falls back to the exception and stack in Patrol's failure details, guards the chained
/// `FlutterError.onError`, and wraps `reportTestException`; each fallback prints one
/// [patrolSafeFailureLogPrefix] line.
///
/// Args:
///   source: Current `lib/src/binding.dart` text.
///
/// Returns:
///   Idempotently patched source.
///
/// Throws:
///   StateError: Required anchors are missing or ambiguous, or a previous patch is incomplete.
String patchPatrolSafeFailureReportSource(String source) {
  if (_isComplete(source)) {
    return source;
  }
  if (_changes.any((change) => source.contains(change.$2))) {
    throw StateError('Patrol safe-failure patch is incomplete; regenerate from pristine source');
  }
  var result = source;
  for (final (before, after) in _changes) {
    if (before.allMatches(result).length != 1) {
      throw StateError('Patrol safe-failure binding source changed near "${before.split('\n').first.trim()}"; '
          'regenerate from pristine source and review failure reporting');
    }
    result = result.replaceFirst(before, after);
  }
  return result;
}

bool _isComplete(String source) => _changes.every((change) => change.$2.allMatches(source).length == 1);

const _changes = <(String, String)>[
  (
    "/// Binding that enables some of Patrol's custom functionality, such as tapping",
    '''/// mplatrol: the failure text, or its exception and stack when formatting it throws.
String _mplatrolDescribeFailure(FlutterErrorDetails details) {
  try {
    return details.toString();
  } catch (formatError) {
    final raw = '\${details.exceptionAsString()}\\n\${details.stack}';
    // The runner reads this line from the device log.
    // ignore: avoid_print
    print('$patrolSafeFailureLogPrefix \$raw\\n(formatting the failure threw: \$formatError)');
    return raw;
  }
}

/// mplatrol: keeps flutter_test's failure report when its formatting throws, and prints the raw failure.
void _mplatrolInstallSafeTestExceptionReporter() {
  final original = reportTestException;
  reportTestException = (details, testDescription) {
    try {
      original(details, testDescription);
    } catch (formatError) {
      // The runner reads this line from the device log.
      // ignore: avoid_print
      print('$patrolSafeFailureLogPrefix \$testDescription: \${details.exceptionAsString()}\\n\${details.stack}\\n'
          '(formatting the failure threw: \$formatError)');
    }
  };
}

/// Binding that enables some of Patrol's custom functionality, such as tapping''',
  ),
  (
    '    : _serviceExtensions = DevtoolsServiceExtensions(platform) {',
    '    : _serviceExtensions = DevtoolsServiceExtensions(platform) {\n'
        '    _mplatrolInstallSafeTestExceptionReporter();',
  ),
  ('            : details.toString();', '            : _mplatrolDescribeFailure(details);'),
  (
    '        previousOnError?.call(details);',
    '''        try {
          previousOnError?.call(details);
        } catch (formatError) {
          // The runner reads this line from the device log.
          // ignore: avoid_print
          print('$patrolSafeFailureLogPrefix \${details.exceptionAsString()}\\n\${details.stack}\\n'
              '(the previous FlutterError.onError threw: \$formatError)');
        }''',
  ),
];
