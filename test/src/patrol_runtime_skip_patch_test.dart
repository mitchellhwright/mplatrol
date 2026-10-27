import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/patrol_runtime_skip';

void main() {
  _registerSourceTests();
  _registerFileTests();
  _registerCompletionTests();
}

String _upstream(String kind) => File('$_fixtures/$kind.txt').readAsStringSync();

void _registerSourceTests() {
  test('unknown source kind is refused instead of passing through unpatched', () {
    expect(
        () => patchPatrolRuntimeSkipSource('desktop', 'source'),
        throwsA(isA<StateError>()
            .having((error) => error.message, 'message', contains('Unknown Patrol runtime-skip source: desktop'))));
  });
  for (final kind in patrolRuntimeSkipSources.keys) {
    test('$kind actual upstream patch is idempotent and detects drift', () {
      final source = _upstream(kind);
      final patched = patchPatrolRuntimeSkipSource(kind, source);
      expect(patched, isNot(source));
      expect(patchPatrolRuntimeSkipSource(kind, patched), patched);
      expect(() => patchPatrolRuntimeSkipSource(kind, '$source$source'), throwsStateError);
      expect(() => patchPatrolRuntimeSkipSource(kind, ''), throwsStateError);
    });
  }
  test('binding transmits explicit skip identity, not isPassing as success', () {
    final patched = patchPatrolRuntimeSkipSource('binding', _upstream('binding'));
    expect(patched, contains('skipped: global_state.isCurrentTestSkipped,'));
    final state = patchPatrolRuntimeSkipSource('global_state', _upstream('global_state'));
    expect(state, contains('state.result == Result.skipped'));
  });
  // Regression: r11 reported every runtime skip as "Dart test skipped at runtime",
  // because Patrol sends details only for failures.
  test('binding sends the markTestSkipped reason as the skip details', () {
    final patched = patchPatrolRuntimeSkipSource('binding', _upstream('binding'));
    expect(patched, contains('global_state.watchCurrentTestSkipReason();'));
    expect(
        patched,
        contains('            details: global_state.isCurrentTestSkipped\n'
            '                ? global_state.currentTestSkipReason\n'));
    final state = patchPatrolRuntimeSkipSource('global_state', _upstream('global_state'));
    expect(state, contains("import 'package:test_api/src/backend/message.dart';"));
    expect(state, contains('message.type == MessageType.skip'));
    expect(state, contains('String? get currentTestSkipReason'));
  });
}

void _registerFileTests() {
  test('generated copy patches once without repeated mtime churn', () {
    final root = Directory.systemTemp.createTempSync('patrol-runtime-skip-');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final entry in patrolRuntimeSkipSources.entries) {
      final file = File('${root.path}/${entry.value}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_upstream(entry.key));
    }
    patchPatrolRuntimeSkip(root);
    final timestamp = DateTime.utc(2000);
    for (final relative in patrolRuntimeSkipSources.values) {
      File('${root.path}/$relative').setLastModifiedSync(timestamp);
    }
    patchPatrolRuntimeSkip(root);
    for (final relative in patrolRuntimeSkipSources.values) {
      expect(File('${root.path}/$relative').lastModifiedSync().toUtc(), timestamp);
    }
  });
  test('missing later source never leaves an earlier file half-patched', () {
    final root = Directory.systemTemp.createTempSync('patrol-runtime-missing-');
    addTearDown(() => root.deleteSync(recursive: true));
    final entry = patrolRuntimeSkipSources.entries.first;
    final file = File('${root.path}/${entry.value}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(_upstream(entry.key));
    expect(() => patchPatrolRuntimeSkip(root), throwsA(isA<FileSystemException>()));
    expect(file.readAsStringSync(), _upstream(entry.key));
  });
}

const _lockedOutDetails = 'passed=false skipped=false details=Expected: true Actual: <false> '
    'login page chain: AUTHERR:ChallengeStatus_LockedOut @ #0      fail (expect.dart:187) | '
    '#1      _expect (expect.dart:182) | #2      x';

void _registerCompletionTests() {
  // Regression 2026-10-22: demo QA iOS PROJ-TC-16754 skipped itself (TEST_DATA_PINNEDSDK_USER_TYPE), an error
  // followed, and the test was reported a test-failure whose message was the skip reason.
  test('a skip before any error is a skip naming the later error; an error before the skip is a failure', () async {
    final root = Directory.systemTemp.createTempSync('patrol-skip-state-');
    addTearDown(() => root.deleteSync(recursive: true));
    final state = patchPatrolRuntimeSkipSource('global_state', _upstream('global_state'));
    final binding = patchPatrolRuntimeSkipSource('binding', _upstream('binding'));
    final getters = state.substring(state.indexOf('/// Returns whether the current test was skipped'),
        state.indexOf('\n}\n', state.indexOf('void watchCurrentTestSkipReason()')) + 3);
    final argumentsStart = binding.indexOf('            passed: global_state.isCurrentTestSkipped');
    final arguments = binding
        .substring(argumentsStart, binding.indexOf('\n          );', argumentsStart))
        .replaceAll('global_state.', '');
    final harness = File('$_fixtures/skip_state_harness.txt')
        .readAsStringSync()
        .replaceFirst('// ACTUAL_GLOBAL_STATE', getters)
        .replaceFirst('// ACTUAL_COMPLETION_ARGUMENTS', arguments);
    final file = File('${root.path}/main.dart')..writeAsStringSync(harness);
    final run = await Process.run('dart', [file.path]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(const LineSplitter().convert('${run.stdout}'), [
      'passed=true skipped=false details=null',
      'passed=true skipped=true details=TEST_DATA_X needs another user',
      'passed=true skipped=true details=TEST_DATA_X needs another user (an error followed the skip: Bad state: late app error stack line)',
      'passed=true skipped=true details=TEST_DATA_X needs another user',
      'passed=false skipped=false details=boom',
      'passed=false skipped=false details=boom',
      'passed=false skipped=false details=Expected: true',
      _lockedOutDetails,
      'passed=false skipped=false details=Bad state: late @ #0      main (main.dart:1)',
    ]);
  });
  for (final kind in ['mobile', 'web']) {
    test('$kind actual completion methods distinguish pass, skip, and failure', () async {
      final root = Directory.systemTemp.createTempSync('patrol-verdict-fixture-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = patchPatrolRuntimeSkipSource(kind, _upstream(kind));
      final harness = File('$_fixtures/completion_harness.txt').readAsStringSync();
      final file = File('${root.path}/main.dart');
      file.writeAsStringSync(harness
          .replaceFirst('// ACTUAL_RESULT_CLASS', _resultClass(source))
          .replaceFirst('// ACTUAL_COMPLETION_METHOD', _method(source, 'markDartTestAsCompleted'))
          .replaceFirst('// ACTUAL_RUN_METHOD', _method(source, 'runDartTest')));
      final run = await Process.run('dart', [file.path]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(run.stdout, contains('VERDICTS success skipped failure failure'));
    });
  }
}

String _resultClass(String source) => source.substring(source.indexOf('class _TestExecutionResult {'),
    source.indexOf('\n}', source.indexOf('class _TestExecutionResult {')) + 2);

String _method(String source, String name) {
  final signature =
      name == 'runDartTest' ? '  Future<RunDartTestResponse> runDartTest(' : '  Future<void> markDartTestAsCompleted(';
  final start = source.indexOf(signature);
  final end = source.indexOf('\n  }\n', start) + 4;
  return source.substring(start, end);
}
