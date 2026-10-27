import 'dart:io';

import 'package:mplatrol/src/patrol_safe_failure_report_patch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _pristine = File('test/fixtures/patrol_runtime_skip/binding.txt').readAsStringSync();

void main() {
  late Directory root;
  late File binding;

  setUp(() {
    root = Directory.systemTemp.createTempSync('patrol-safe-failure-');
    binding = File(p.join(root.path, patrolSafeFailureSourcePath))
      ..createSync(recursive: true)
      ..writeAsStringSync(_pristine);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('pristine binding is not detected as patched', () {
    expect(hasPatrolSafeFailureReportPatch(root), isFalse);
  });

  test('missing binding is not detected and patching it fails loudly', () {
    binding.deleteSync();
    expect(hasPatrolSafeFailureReportPatch(root), isFalse);
    expect(() => patchPatrolSafeFailureReport(root), throwsA(isA<FileSystemException>()));
  });

  // Regression 2026-10-14 (GLOBEX Android): FlutterErrorDetails.toString() ran the widget inspector, which threw
  // "Looking up a deactivated widget's ancestor is unsafe", so Patrol reported that instead of the assertion.
  test('falls back to the exception and stack wherever Patrol formats a failure', () {
    patchPatrolSafeFailureReport(root);
    final source = binding.readAsStringSync();

    expect(hasPatrolSafeFailureReportPatch(root), isTrue);
    expect(source, contains(': _mplatrolDescribeFailure(details);'));
    expect(source, isNot(contains(': details.toString();')));
    expect(source, contains("final raw = '\${details.exceptionAsString()}\\n\${details.stack}';"));
    expect(source, contains('          previousOnError?.call(details);\n        } catch (formatError) {'));
    expect(source, contains('DevtoolsServiceExtensions(platform) {\n    _mplatrolInstallSafeTestExceptionReporter();'));
    expect(source, contains('reportTestException = (details, testDescription) {'));
    expect(patrolSafeFailureLogPrefix.allMatches(source).length, 3, reason: 'one raw-failure line per fallback');
    expect(source, contains("}\n\n/// Binding that enables some of Patrol's custom functionality"),
        reason: 'PatrolBinding keeps its own doc comment');
  });

  test('patching twice changes nothing', () {
    patchPatrolSafeFailureReport(root);
    final once = binding.readAsStringSync();
    patchPatrolSafeFailureReport(root);
    expect(binding.readAsStringSync(), once);
  });

  test('a partly patched binding is refused', () {
    binding.writeAsStringSync(_pristine.replaceFirst(': details.toString();', ': _mplatrolDescribeFailure(details);'));
    expect(hasPatrolSafeFailureReportPatch(root), isFalse);
    expect(() => patchPatrolSafeFailureReport(root), throwsStateError);
  });

  test('a changed upstream anchor is refused instead of silently skipped', () {
    binding.writeAsStringSync(_pristine.replaceFirst('        previousOnError?.call(details);', ''));
    expect(
        () => patchPatrolSafeFailureReport(root),
        throwsA(isA<StateError>()
            .having((error) => error.message, 'message', contains('previousOnError?.call(details);'))));
  });
}
