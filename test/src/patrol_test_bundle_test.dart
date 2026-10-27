import 'dart:io';

import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('patrol_bundle');
    // Create the patrol_test directory that patrolTestDirectoryPath expects.
    Directory(p.join(repo.path, 'patrol_test')).createSync();
  });

  tearDown(() => repo.deleteSync(recursive: true));

  group('retargetPatrolTestBundle', () {
    test('throws StateError when no patrol test files match', () {
      // No test files in patrol_test → files.isEmpty → StateError.
      expect(
        () => retargetPatrolTestBundle(
          repo.path,
          target: null,
          targetRegex: 'no_match',
          sdk: null,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('No patrolTest() found'),
        )),
      );
    });

    test('names the SDK filter in the StateError when nothing matches', () {
      // A discoverable file exists, but the SDK filter excludes it, so the
      // message includes the `for SDK "<sdk>"` clause.
      File(p.join(repo.path, 'patrol_test', 'login_test.dart'))
          .writeAsStringSync("patrolTest('does login', (\$) async {});\n");

      expect(
        () => retargetPatrolTestBundle(
          repo.path,
          target: null,
          targetRegex: null,
          sdk: 'zzznomatch',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('for SDK "zzznomatch"'),
        )),
      );
    });

    test('writes a filtered target that imports every discovered file', () {
      File(p.join(repo.path, 'patrol_test', 'login_test.dart'))
          .writeAsStringSync("patrolTest('does login', (\$) async {});\n");
      File(p.join(repo.path, 'patrol_test', 'faults_test.dart'))
          .writeAsStringSync("patrolTest('handles faults', (\$) async {});\n");

      final relativePath = retargetPatrolTestBundle(
        repo.path,
        target: null,
        targetRegex: null,
        sdk: null,
      );

      expect(relativePath, 'patrol_test/mplatrol_filtered_test.dart');
      final generated = File(
        p.join(repo.path, 'patrol_test', 'mplatrol_filtered_test.dart'),
      ).readAsStringSync();
      expect(generated, contains("import 'login_test.dart' as login_test;"));
      expect(generated, contains("import 'faults_test.dart' as faults_test;"));
      expect(
        generated,
        contains("group('login_test', () { login_test.main(); });"),
      );
      expect(
        generated,
        contains("group('faults_test', () { faults_test.main(); });"),
      );
    });
  });

  group('removeFilteredPatrolTestTarget', () {
    test('deletes the filtered target file when it exists', () {
      final filteredFile = File(
        p.join(repo.path, 'patrol_test', 'mplatrol_filtered_test.dart'),
      )..writeAsStringSync('// generated');

      expect(filteredFile.existsSync(), isTrue);

      removeFilteredPatrolTestTarget(repo.path);

      expect(filteredFile.existsSync(), isFalse);
    });

    test('does nothing when the filtered target file does not exist', () {
      // Should not throw — the guard `if (file.existsSync())` protects deleteSync.
      expect(
        () => removeFilteredPatrolTestTarget(repo.path),
        returnsNormally,
      );
    });
  });
}
