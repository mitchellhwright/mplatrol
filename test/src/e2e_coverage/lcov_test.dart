import 'dart:io';

import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/e2e_coverage';

String _fixture(String name) => File('$_fixtures/$name').readAsStringSync();

void main() {
  group('Lcov.parse', () {
    test('reads the files and lines of a real flutter test report', () {
      final lcov = Lcov.parse(_fixture('flutter_test_a.info'));

      expect(lcov.files.keys, ['lib/e2e/credential_dom_scripts.dart', 'lib/e2e/flutter_control_readiness.dart']);
      expect(lcov.files.values.every((lines) => lines.isNotEmpty), isTrue);
    });

    test('adds up repeated lines of one file and ignores other records', () {
      final lcov =
          Lcov.parse('TN:\nSF:/a/lib/x.dart\nFN:1,f\nDA:1,2\nDA:1,3\nDA:2,0,abc\nBRDA:1,0,0,1\nend_of_record\n');

      expect(lcov.files, {
        '/a/lib/x.dart': {1: 5, 2: 0},
      });
    });

    for (final text in ['DA:1,1\n', 'SF:/a.dart\nDA:x,1\n', 'SF:/a.dart\nDA:1\n', 'SF:/a.dart\nDA:1,y\n']) {
      test('rejects the malformed record in ${text.replaceAll('\n', r'\n')}', () {
        expect(() => Lcov.parse(text),
            throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line'))));
      });
    }

    test('an empty report has no files', () => expect(Lcov.parse('').files, isEmpty));
  });

  group('Lcov.merge', () {
    test('unions files and lines and adds hit counts, across real reports', () {
      final a = Lcov.parse(_fixture('flutter_test_a.info'));
      final b = Lcov.parse(_fixture('flutter_test_b.info'));

      final merged = Lcov.merge([a, b]);

      expect(merged.files.keys, {...a.files.keys, ...b.files.keys});
      const shared = 'lib/e2e/credential_dom_scripts.dart';
      expect(merged.files[shared]!.keys, {...a.files[shared]!.keys, ...b.files[shared]!.keys});
      for (final line in merged.files[shared]!.keys) {
        expect(merged.files[shared]![line], (a.files[shared]![line] ?? 0) + (b.files[shared]![line] ?? 0));
      }
    });

    test('a line one report misses and another hits counts as hit', () {
      final merged = Lcov.merge([
        Lcov({
          'f.dart': {1: 0, 2: 0}
        }),
        Lcov({
          'f.dart': {2: 4, 3: 0}
        }),
      ]);

      expect(merged.files['f.dart'], {1: 0, 2: 4, 3: 0});
    });

    test('merging nothing is empty', () => expect(Lcov.merge(const []).files, isEmpty));
  });

  group('render', () {
    test('round-trips through parse with sorted records and LF/LH totals', () {
      final text = Lcov({
        '/b/lib/b.dart': {2: 0, 1: 3},
        '/a/lib/a.dart': {5: 1},
      }).render();

      expect(
          text, startsWith('SF:/a/lib/a.dart\nDA:5,1\nLF:1\nLH:1\nend_of_record\nSF:/b/lib/b.dart\nDA:1,3\nDA:2,0\n'));
      expect(text, contains('LF:2\nLH:1\n'));
      expect(Lcov.parse(text).files, {
        '/a/lib/a.dart': {5: 1},
        '/b/lib/b.dart': {1: 3, 2: 0},
      });
    });
  });

  group('isAppCodePath', () {
    for (final (path, expected) in [
      ('/w/app/lib/src/home/home_cubit.dart', true),
      ('/w/shared_platform/lib/src/x.dart', true),
      ('lib/main.dart', true),
      ('/w/app/lib/src/home/home_state.freezed.dart', false),
      ('/w/app/lib/src/home/home.g.dart', false),
      ('/w/app/lib/e2e/home_page.dart', false),
      ('lib/e2e/credential_dom_scripts.dart', false),
      ('/w/app/lib/src/e2e_helpers/x.dart', true),
      ('/w/app/test/home_test.dart', false),
      ('/w/app/patrol_test/login_test.dart', false),
      ('/w/pkg/lib/test/support.dart', false),
      ('/w/pkg/tool/build.dart', false),
      ('/w/pkg/lib/native.c', false),
      (r'C:\w\app\lib\src\x.dart', true),
    ]) {
      test('$path is ${expected ? 'kept' : 'dropped'}', () => expect(isAppCodePath(path), expected));
    }

    test('appCodeOnly keeps only app code files', () {
      final lcov = Lcov({
        '/w/a/lib/x.dart': {1: 1},
        '/w/a/lib/x.g.dart': {1: 1},
        '/w/a/lib/e2e/page.dart': {1: 1},
      });

      expect(lcov.appCodeOnly().files.keys, ['/w/a/lib/x.dart']);
    });
  });

  group('packageOf', () {
    for (final (path, expected) in [
      ('/w/app/lib/src/x.dart', 'app'),
      ('/c/hosted/pub.dev/example_core-1.2.3+4/lib/a.dart', 'example_core'),
      ('/w/package_example_accounts/lib/a.dart', 'package_example_accounts'),
      ('lib/main.dart', 'unknown'),
    ]) {
      test('$path is $expected', () => expect(packageOf(path), expected));
    }
  });

  group('PackageNames', () {
    const config = '''
{"packages": [
  {"name": "app", "rootUri": "../", "packageUri": "lib/"},
  {"name": "shared_platform", "rootUri": "file:///w/fp-e2e-plus-splash", "packageUri": "lib/"},
  {"name": "nested", "rootUri": "file:///w/fp-e2e-plus-splash/nested/", "packageUri": "lib/"},
  {"name": "bad"},
  "junk"
]}''';

    test('names a worktree path dependency by its package, longest root first', () {
      final names = PackageNames.fromPackageConfig(config, configDirectory: '/r/app/.dart_tool');

      expect(names.of('/w/fp-e2e-plus-splash/lib/a.dart'), 'shared_platform');
      expect(names.of('/w/fp-e2e-plus-splash/nested/lib/a.dart'), 'nested');
      expect(names.of('/r/app/lib/main.dart'), 'app');
    });

    test('falls back to the path for a file outside every root', () {
      final names = PackageNames.fromPackageConfig(config, configDirectory: '/r/app/.dart_tool');

      expect(names.of('/elsewhere/other_pkg/lib/a.dart'), 'other_pkg');
      expect(const PackageNames().of('/x/pkg/lib/a.dart'), 'pkg');
    });

    test('rejects JSON that is not a package config', () {
      expect(() => PackageNames.fromPackageConfig('{}', configDirectory: '/d'), throwsFormatException);
      expect(() => PackageNames.fromPackageConfig('[]', configDirectory: '/d'), throwsFormatException);
    });
  });

  group('e2eCoveragePackagePattern', () {
    late Directory repo;
    setUp(() => repo = Directory.systemTemp.createTempSync('lcov_pattern'));
    tearDown(() => repo.deleteSync(recursive: true));

    test("keeps only the app's own package by default", () {
      File(p.join(repo.path, 'pubspec.yaml')).writeAsStringSync('name: shop_app\nversion: 1.0.0\n');
      final pattern = RegExp(e2eCoveragePackagePattern(repo.path));

      expect(pattern.hasMatch('shop_app'), isTrue);
      for (final name in ['flutter', 'patrol', 'shop_app_extra', 'my_shop_app']) {
        expect(pattern.hasMatch(name), isFalse, reason: name);
      }
    });

    test('is the configured pattern when one is set, and app without a pubspec', () {
      expect(e2eCoveragePackagePattern(repo.path, configured: r' ^(a|b_.+)$ '), r'^(a|b_.+)$');
      expect(e2eCoveragePackagePattern(repo.path), r'^app$');
    });
  });
}
