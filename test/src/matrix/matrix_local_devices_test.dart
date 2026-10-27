import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

void main() {
  late Directory root;
  late _MockLogger logger;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mplatrol_local_devices');
    logger = _MockLogger();
  });
  tearDown(() => root.deleteSync(recursive: true));

  MatrixLocalDevices devices() => MatrixLocalDevices(
      directory: p.join(root.path, 'local-devices'), logger: logger, pollInterval: const Duration(milliseconds: 5));

  MatrixLeg leg(String spec) => MatrixLeg.parse(spec)!;

  test('lives under HOME, with one budget of one device per platform', () {
    final fromHome = MatrixLocalDevices.fromHome(root.path, logger)!;
    expect(fromHome.directory, p.join(root.path, '.mplatrol', 'local-devices'));
    expect(fromHome.pollInterval, const Duration(seconds: 15));
    expect(MatrixLocalDevices.fromHome(null, logger), isNull);
    expect(MatrixLocalDevices.fromHome('', logger), isNull);

    final android = fromHome.budgetFor(leg('a:android'));
    expect([android.directory, android.limit, android.tag, android.unit, android.limitSource],
        [p.join(fromHome.directory, 'android'), 1, 'local-device', 'local android emulator (mplatrol_e2e_pixel9)', '']);
    expect(fromHome.budgetFor(leg('b:android')), same(android));
    expect(fromHome.budgetFor(leg('a:ios')).unit, 'local ios simulator (iPhone 17 Pro)');
  });

  test('one leg per platform at a time, across processes; the other platform runs meanwhile', () async {
    final android = await devices().acquire(leg('a:android'), report: (_) {}, cancel: Completer<void>().future);
    final ios = await devices().acquire(leg('a:ios'), report: (_) {}, cancel: Completer<void>().future);
    final lines = <String>[];
    final second = devices().acquire(leg('b:android'), report: lines.add, cancel: Completer<void>().future);
    while (lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(lines.single,
        '[local-device] b:android: waiting for 1 free local android emulator (mplatrol_e2e_pixel9) of the machine-wide 1');

    await android.release();
    await (await second).release();
    await ios.release();
    expect(
        lines.last, '[local-device] b:android: got 1 of 1 local android emulator (mplatrol_e2e_pixel9) after waiting');
  });
}
