import 'dart:io';

import 'package:mplatrol/src/write_if_changed.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('write_if_changed'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('creates a missing file and its parent directories', () {
    final file = File(p.join(dir.path, 'nested', 'build.gradle'));

    writeIfChanged(file, 'content');

    expect(file.readAsStringSync(), 'content');
  });

  test('leaves identical content untouched so its timestamp is preserved', () {
    final file = File(p.join(dir.path, 'build.gradle'))..writeAsStringSync('same');
    final stamp = DateTime(2020);
    file.setLastModifiedSync(stamp);

    writeIfChanged(file, 'same');

    expect(file.lastModifiedSync(), stamp);
  });

  test('rewrites a file whose content changed', () {
    final file = File(p.join(dir.path, 'build.gradle'))..writeAsStringSync('old');

    writeIfChanged(file, 'new');

    expect(file.readAsStringSync(), 'new');
  });
}
