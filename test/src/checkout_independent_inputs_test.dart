import 'dart:convert';

import 'package:mplatrol/src/checkout_independent_inputs.dart';
import 'package:test/test.dart';

void main() {
  String normalized(String repo, String relative, String text) =>
      utf8.decode(checkoutIndependentBytes(repo, relative, utf8.encode(text)));

  test('the same generated inputs in two checkouts are identical', () {
    for (final (relative, templatrole) in [
      ('pubspec_overrides.yaml', 'patrol:\n  path: {repo}/.mplatrol/patched_packages/patrol\n'),
      ('pubspec.lock', '  patrol:\n    description:\n      path: "{repo}/.mplatrol/patched_packages/patrol"\n'),
      ('.dart_tool/package_config.json', '{"rootUri": "file://{repo}/.mplatrol/patched_packages/patrol/"}'),
      ('ios/Flutter/Generated.xcconfig', 'FLUTTER_APPLICATION_PATH={repo}\n'),
      ('ios/Flutter/flutter_export_environment.sh', 'export "FLUTTER_APPLICATION_PATH={repo}"\n'),
      ('.flutter-plugins', 'patrol={repo}/.mplatrol/patched_packages/patrol/\n'),
    ]) {
      final lane1 = normalized('/w/lane1/app', relative, templatrole.replaceAll('{repo}', '/w/lane1/app'));
      final lane2 = normalized('/w/lane2/app', relative, templatrole.replaceAll('{repo}', '/w/lane2/app'));
      expect(lane1, lane2, reason: relative);
      expect(lane1, isNot(contains('lane1')), reason: relative);
    }
  });

  test('drops the pub get timestamp of .flutter-plugins-dependencies', () {
    String plugins(String date) => '{"info":"x","plugins":{"ios":[{"path":"/w/lane1/app/p/"}]},'
        '"date_created":"$date","version":"3.41.6"}';
    expect(normalized('/w/lane1/app', '.flutter-plugins-dependencies', plugins('2026-10-03 07:30:58.573015')),
        '{"info":"x","plugins":{"ios":[{"path":"<app>/p/"}]},"version":"3.41.6"}');
  });

  test('leaves every other input unchanged', () {
    final bytes = utf8.encode('const root = "/w/lane1/app";');
    expect(checkoutIndependentBytes('/w/lane1/app', 'lib/main.dart', bytes), same(bytes));
  });
}
