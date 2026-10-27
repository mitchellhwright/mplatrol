import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_publish_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('matrix_publish_state'));
  tearDown(() => home.deleteSync(recursive: true));

  test('records the newest run for external publishers', () {
    final run = MatrixRunDir(p.join(home.path, 'rounds', 'round8'));

    MatrixPublishState(home.path).recordRun(run, DateTime.utc(2026, 10, 3, 12));

    final latest =
        jsonDecode(File(p.join(home.path, '.mplatrol', 'matrix-publish', 'latest-run.json')).readAsStringSync())
            as Map<String, dynamic>;
    expect(latest, {'run': 'round8', 'dir': run.path, 'updated_at': '2026-10-03T12:00:00.000Z'});
  });

  test('without a home directory nothing is written', () {
    for (final none in [MatrixPublishState(null), MatrixPublishState('')]) {
      expect(none.directory, isNull);
      none.recordRun(MatrixRunDir(p.join(home.path, 'r')), DateTime.utc(2026));
    }
    expect(Directory(p.join(home.path, '.mplatrol')).existsSync(), isFalse);
  });
}
