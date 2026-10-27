import 'dart:io';

import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('discovery');
    Directory(p.join(repo.path, 'patrol_test')).createSync();
  });

  tearDown(() => repo.deleteSync(recursive: true));

  void writeTest(String name, String body) => File(p.join(repo.path, 'patrol_test', name)).writeAsStringSync(body);

  void writeLegacyTest(String name, String body) => File(p.join(repo.path, 'integration_test', name))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  void writePubspec(String body) => File(p.join(repo.path, 'pubspec.yaml')).writeAsStringSync(body);

  _unsupportedNameCases(() => repo, writeTest);

  group('discoverPatrolTestFiles', () {
    test('groups tests by file, sorted by file then description', () {
      writeTest('b_test.dart', "patrolTest('zeta'); patrolTest('alpha');");
      writeTest('a_test.dart', "patrolTest('only one');");

      final files = discoverPatrolTestFiles(repo.path);

      expect(files.map((f) => f.basename), ['a_test', 'b_test']);
      expect(files[1].tests.map((t) => t.description), ['alpha', 'zeta']);
    });

    test('joins a name wrapped into adjacent literals, as Dart compiles it', () {
      writeTest('wrapped_test.dart', """
patrolTest(
  'PROJ-TC-1205 PROJ-TC-1206 Settings shows the footer; Edit '
  "takes a nickname, doesn't save" ' and cancels',
  (\$) async {},
);""");

      final tests = discoverPatrolTestFiles(repo.path).single.tests;

      expect(tests.single.description,
          "PROJ-TC-1205 PROJ-TC-1206 Settings shows the footer; Edit takes a nickname, doesn't save and cancels");
    });

    test('a wrapped group name is joined before the "/" check', () {
      writeTest('wrapped_group_test.dart', "group('terms' '/video', () { patrolTest('opens UI'); });");

      expect(() => discoverPatrolTestFiles(repo.path), throwsA(isA<StateError>()));
    });

    test('keeps credential-dependent tests when the skip env is set', () {
      writeTest('patrol_login_test.dart', "patrolTest('login');");
      writeTest('login_faults_test.dart', "patrolTest('faults');");
      writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('sdk');");

      final files = discoverPatrolTestFiles(repo.path, environment: const {e2eSkipHappyLoginTestEnv: 'TRUE\n'});

      expect(files.map((f) => f.basename), ['login_faults_test', 'patrol_login_test', 'tenant_sdk_matrix_smoke_test']);
    });

    test('keeps an explicitly targeted patrol_login_test even with skip set', () {
      writeTest('patrol_login_test.dart', "patrolTest('login');");
      writeTest('login_faults_test.dart', "patrolTest('faults');");

      final files = discoverPatrolTestFiles(repo.path,
          target: 'patrol_test/patrol_login_test.dart', environment: const {e2eSkipHappyLoginTestEnv: 'true'});

      expect(files.map((f) => f.basename), ['patrol_login_test']);
    });

    test('keeps patrol_login_test when the skip env is unset', () {
      writeTest('patrol_login_test.dart', "patrolTest('login');");
      writeTest('login_faults_test.dart', "patrolTest('faults');");

      final files = discoverPatrolTestFiles(repo.path, environment: const {});

      expect(files.map((f) => f.basename), ['login_faults_test', 'patrol_login_test']);
    });

    test('uses the patrol.test_directory configured in pubspec.yaml', () {
      writePubspec('''
name: app
patrol:
  test_directory: patrol_test
''');
      writeLegacyTest('legacy_test.dart', "patrolTest('legacy');");
      writeTest('standard_test.dart', "patrolTest('standard');");

      final files = discoverPatrolTestFiles(repo.path);

      expect(files.map((f) => f.basename), ['standard_test']);
      expect(files.single.tests.single.description, 'standard');
    });

    test('falls back to integration_test when patrol_test is missing', () {
      Directory(p.join(repo.path, 'patrol_test')).deleteSync();
      writeLegacyTest('legacy_test.dart', "patrolTest('legacy');");

      final files = discoverPatrolTestFiles(repo.path);

      expect(files.map((f) => f.basename), ['legacy_test']);
      expect(files.single.tests.single.description, 'legacy');
    });

    test('derives a readable method name from the description', () {
      writeTest('x_test.dart', "patrolTest('reaches accounts + MFA!');");

      final test = discoverPatrolTestFiles(repo.path).single.tests.single;

      expect(test.method, 'reaches_accounts_MFA');
      expect(test.description, 'reaches accounts + MFA!');
    });

    test('prefixes a leading-digit method name so it is a valid identifier', () {
      writeTest('x_test.dart', "patrolTest('2fa works');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.single.method, 't_2fa_works');
    });

    test('falls back to patrolTest when the description has no word chars', () {
      writeTest('x_test.dart', "patrolTest('!!!');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.single.method, 'patrolTest');
    });

    test('uniquifies duplicate method names within a file', () {
      writeTest('x_test.dart', "patrolTest('same name'); patrolTest('same name');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.map((t) => t.method), ['same_name', 'same_name_2']);
    });

    test('matches single- and double-quoted descriptions', () {
      writeTest(
        'x_test.dart',
        'patrolTest("double"); '
            "patrolTest('single');",
      );

      expect(discoverPatrolTestFiles(repo.path).single.tests.map((t) => t.description), ['double', 'single']);
    });

    test('ignores non-_test.dart files and files with no patrolTest', () {
      writeTest('helper.dart', "patrolTest('ignored, wrong suffix');");
      writeTest('empty_test.dart', 'void main() {}');
      writeTest('real_test.dart', "patrolTest('kept');");

      expect(discoverPatrolTestFiles(repo.path).map((f) => f.basename), ['real_test']);
    });

    test('ignores generated Patrol bundle targets during full discovery', () {
      writeTest('real_test.dart', "patrolTest('kept');");
      writeTest('mplatrol_filtered_test.dart', "patrolTest('generated target should not run directly');");
      writeTest('mplatrol_filtered_test_bundle_test.dart', "patrolTest('generated helper should not run directly');");

      expect(discoverPatrolTestFiles(repo.path).map((f) => f.basename), ['real_test']);
    });

    test('restricts discovery to the requested target file', () {
      writeTest('login_faults_test.dart', "patrolTest('fault');");
      writeTest('patrol_login_test.dart', "patrolTest('happy path');");

      final files = discoverPatrolTestFiles(repo.path, target: 'patrol_test/patrol_login_test.dart');

      expect(files.map((f) => f.basename), ['patrol_login_test']);
      expect(files.single.tests.map((t) => t.description), ['happy path']);
    });

    test('targetRegex keeps every test in matching files', () {
      writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('first'); patrolTest('second');");
      writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('videosdk');");

      final files = discoverPatrolTestFiles(repo.path, targetRegex: 'tenant_sdk');

      expect(files.map((f) => f.basename), ['tenant_sdk_matrix_smoke_test']);
      expect(files.single.tests.map((t) => t.description), ['first', 'second']);
    });

    test('targetRegex can select individual Patrol descriptions', () {
      writeTest('sdk_smoke_test.dart', "patrolTest('tenant SDK happy path'); patrolTest('VideoSdk SDK loads');");

      final files = discoverPatrolTestFiles(repo.path, targetRegex: 'VideoSdk');

      expect(files.map((f) => f.basename), ['sdk_smoke_test']);
      expect(files.single.tests.map((t) => t.description), ['VideoSdk SDK loads']);
    });

    test('sdk and targetRegex ignore directories outside the repo', () {
      // A checkout location whose path contains the filter words must not
      // select every test in the repo.
      final nestedRepo = p.join(repo.path, 'tenant-checkout');
      for (final entry in {
        'tenant_sdk_matrix_smoke_test.dart': "patrolTest('tenant matrix');",
        'videosdk_sdk_smoke_test.dart': "patrolTest('videosdk smoke');",
      }.entries) {
        File(p.join(nestedRepo, 'patrol_test', entry.key))
          ..createSync(recursive: true)
          ..writeAsStringSync(entry.value);
      }

      expect(
          discoverPatrolTestFiles(nestedRepo, sdk: 'tenant').map((f) => f.basename), ['tenant_sdk_matrix_smoke_test']);
      expect(
        discoverPatrolTestFiles(nestedRepo, targetRegex: 'checkout').map((f) => f.basename),
        isEmpty,
      );
    });

    test('sdk matches SDK tokens in file names without hardcoded names', () {
      writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('tenant matrix');");
      writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('videosdk smoke');");

      final files = discoverPatrolTestFiles(repo.path, sdk: 'videosdk');

      expect(files.map((f) => f.basename), ['videosdk_sdk_smoke_test']);
      expect(files.single.tests.map((t) => t.description), ['videosdk smoke']);
    });

    test('sdk can select individual Patrol descriptions', () {
      writeTest('sdk_smoke_test.dart', "patrolTest('tenant SDK happy path'); patrolTest('VideoSdk SDK loads');");

      final files = discoverPatrolTestFiles(repo.path, sdk: 'tenant');

      expect(files.map((f) => f.basename), ['sdk_smoke_test']);
      expect(files.single.tests.map((t) => t.description), ['tenant SDK happy path']);
    });

    test('accepts an absolute target path', () {
      final target = p.join(repo.path, 'patrol_test', 'target_test.dart');
      File(target).writeAsStringSync("patrolTest('targeted');");
      writeTest('other_test.dart', "patrolTest('ignored');");

      final files = discoverPatrolTestFiles(repo.path, target: target);

      expect(files.map((f) => f.basename), ['target_test']);
    });

    test('returns empty when there are no patrol tests', () {
      writeTest('empty_test.dart', 'void main() {}');

      expect(discoverPatrolTestFiles(repo.path), isEmpty);
    });

    test('skips commented-out patrolTest (line and block comments)', () {
      writeTest(
        'x_test.dart',
        "patrolTest('live');\n"
            "// patrolTest('line commented');\n"
            "/* patrolTest('block commented'); */",
      );

      expect(discoverPatrolTestFiles(repo.path).single.tests.map((t) => t.description), ['live']);
    });

    test('requires a word boundary so myPatrolTest( is not matched', () {
      writeTest('x_test.dart', "myPatrolTest('nope'); patrolTest('yes');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.map((t) => t.description), ['yes']);
    });

    test('captures an escaped quote and interprets Dart escapes', () {
      writeTest('x_test.dart', r"patrolTest('user\'s tab\nwraps');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.single.description, "user's tab\nwraps");
    });

    test('interprets unicode escapes', () {
      writeTest('x_test.dart', r"patrolTest('café \u{1F600}');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.single.description, 'café \u{1F600}');
    });

    test('interprets common escapes and preserves malformed unicode escapes', () {
      writeTest('x_test.dart', r"patrolTest('a\tb\rc\bd\fe\vg\u0041h\u12zzi\u{zz}j');");

      expect(discoverPatrolTestFiles(repo.path).single.tests.single.description, 'a\tb\rc\bd\fe\vgAhu12zziu{zz}j');
    });

    test('increments duplicate suffixes until the method name is unique', () {
      writeTest(
        'x_test.dart',
        "patrolTest('a'); "
            "patrolTest('a 2'); "
            "patrolTest('a!');",
      );

      expect(discoverPatrolTestFiles(repo.path).single.tests.map((t) => t.method), ['a', 'a_2', 'a_3']);
    });

    test('throws when a file basename is not a valid class identifier', () {
      writeTest('2fa_test.dart', "patrolTest('x');");

      expect(() => discoverPatrolTestFiles(repo.path), throwsStateError);
    });

    test('throws when target is outside the Patrol test directory', () {
      final target = p.join(repo.path, 'test', 'unit_test.dart');
      File(target)
        ..createSync(recursive: true)
        ..writeAsStringSync("patrolTest('x');");

      expect(
        () => discoverPatrolTestFiles(repo.path, target: target),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('must be inside'))),
      );
    });

    test('throws when target is not a *_test.dart file', () {
      writeTest('helper.dart', "patrolTest('x');");

      expect(
        () => discoverPatrolTestFiles(repo.path, target: 'patrol_test/helper.dart'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('*_test.dart'))),
      );
    });

    test('throws when target does not exist', () {
      expect(
        () => discoverPatrolTestFiles(repo.path, target: 'patrol_test/missing_test.dart'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('does not exist'))),
      );
    });

    test('throws when the Patrol test directory is missing', () {
      Directory(p.join(repo.path, 'patrol_test')).deleteSync();

      expect(() => discoverPatrolTestFiles(repo.path), throwsStateError);
    });

    test('throws a StateError when targetRegex is not a valid regex', () {
      writeTest('real_test.dart', "patrolTest('kept');");

      expect(
        () => discoverPatrolTestFiles(repo.path, targetRegex: '(unclosed'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Invalid Patrol target regex'),
        )),
      );
    });
  });
}

void _unsupportedNameCases(Directory Function() repo, void Function(String, String) writeTest) {
  for (final entry in {
    'description': "patrolTest('terms/video UI');",
    'URL description': "patrolTest('https://example.invalid/terms');",
    'group': "group('terms/video', () { patrolTest('opens UI'); });",
    'nested group': "group('outer', () { group('terms/video', () { "
        "patrolTest('opens UI'); }); });",
    'escaped description': r"patrolTest('terms\u002fvideo UI');",
    'escaped group': r"group('terms\u{2f}video', () { patrolTest('opens UI'); });",
  }.entries) {
    test('rejects slash in Patrol ${entry.key} before filtering', () {
      writeTest('names_test.dart', entry.value);
      expect(
        () => discoverPatrolTestFiles(repo().path, targetRegex: 'unmatched'),
        throwsA(isA<StateError>()
            .having((error) => error.message, 'file', contains('names_test.dart'))
            .having(
                (error) => error.message, 'name', contains(entry.key == 'URL description' ? 'https://' : 'terms/video'))
            .having((error) => error.message, 'action', contains('Replace "/"'))),
      );
    });
  }
  test('normal nested groups and target path separators are accepted', () {
    writeTest(
        'names_test.dart',
        "group('outer', () { group('terms or video', () { "
            "patrolTest('opens UI'); }); });");
    final files = discoverPatrolTestFiles(repo().path, target: 'patrol_test/names_test.dart');
    expect(files.single.tests.single.description, 'opens UI');
  });
  test('commented names and unrelated identifiers are not Patrol names', () {
    writeTest(
        'names_test.dart',
        "// group('terms/video');\n"
            "/* patrolTest('terms/video'); */\n"
            "mygroup('terms/video'); myPatrolTest('terms/video'); "
            "patrolTest('opens UI');");
    expect(discoverPatrolTestFiles(repo().path).single.tests.single.description, 'opens UI');
  });
}
