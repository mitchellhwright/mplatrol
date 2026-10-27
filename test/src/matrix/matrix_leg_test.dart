import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('parses legs, with and without a device', () {
    final leg = MatrixLeg.parse(' acme:lt-ios ')!;
    expect([leg.tenant, leg.variant, leg.device, leg.isIos, leg.key, '$leg'],
        ['acme', 'lt-ios', null, true, 'acme_lt-ios', 'acme:lt-ios']);
    final pinned = MatrixLeg.parse('globex:lt-android@Pixel 8-14')!;
    expect([pinned.device, pinned.isIos, '$pinned'], ['Pixel 8-14', false, 'globex:lt-android@Pixel 8-14']);
    for (final bad in [
      'globex',
      'globex:lt-mac',
      'globex:iOS',
      'GLOBEX:lt-ios',
      ':lt-ios',
      'globex:lt-android@',
      'globex:ios@'
    ]) {
      expect(MatrixLeg.parse(bad), isNull, reason: bad);
    }
  });

  test('parses a leg environment, user type and tests, keeping the plain syntax and key', () {
    final leg = MatrixLeg.parse('demo@QA:lt-android;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756)')!;
    expect([
      leg.tenant,
      leg.environment,
      leg.variant,
      leg.device,
      leg.userType,
      leg.tests,
      leg.key
    ], [
      'demo',
      'QA',
      'lt-android',
      null,
      'PinnedSdk_Enrolled',
      'PROJ-TC-(16752|17756)',
      'demo@QA+PinnedSdk_Enrolled_lt-android',
    ]);
    expect('$leg', 'demo@QA:lt-android;user=PinnedSdk_Enrolled;tests=PROJ-TC-(16752|17756)');
    expect(MatrixLeg.parse('$leg')!.key, leg.key, reason: 'queue.log lines are parsed back');

    final pinned = MatrixLeg.parse('demo@UAT:lt-ios@iPhone 16-18;tests=pinnedsdk')!;
    expect([pinned.environment, pinned.device, pinned.userType, pinned.tests, pinned.key],
        ['UAT', 'iPhone 16-18', null, 'pinnedsdk', 'demo@UAT_lt-ios']);
    expect('$pinned', 'demo@UAT:lt-ios@iPhone 16-18;tests=pinnedsdk');

    final plain = MatrixLeg.parse('acme:lt-ios')!;
    expect([plain.environment, plain.userType, plain.tests, plain.key], [null, null, null, 'acme_lt-ios']);
    expect(MatrixLeg.parse('demo:android;user=PinnedSdk_Enrolled')!.key, 'demo+PinnedSdk_Enrolled_android');

    for (final bad in [
      'demo@:lt-ios',
      'demo@Trin ity:lt-ios',
      'demo@1qa:lt-ios',
      'demo:lt-ios;user=',
      'demo:lt-ios;user=a b',
      'demo:lt-ios;user=a-b',
      'demo:lt-ios;tests=a b',
      'demo:lt-ios;tests=',
      'demo:lt-ios;color=red',
      'demo:lt-ios;user=A;user=B',
      'demo:lt-ios;',
      'demo:lt-ios@;user=A',
    ]) {
      expect(MatrixLeg.parse(bad), isNull, reason: bad);
    }
  });

  test('parses local legs: the emulator and the simulator, never pinned to a device', () {
    final android = MatrixLeg.parse('globex:android')!;
    final ios = MatrixLeg.parse('globex:ios')!;
    expect([android.isLocal, android.isIos, android.platform, android.key, android.localWithDevice],
        [true, false, 'android', 'globex_android', false]);
    expect([ios.isLocal, ios.isIos, ios.platform, ios.key], [true, true, 'ios', 'globex_ios']);
    expect(MatrixLeg.parse('globex:ios@iPhone 15-17')!.localWithDevice, isTrue);
    final lt = MatrixLeg.parse('globex:lt-ios@iPhone 15-17')!;
    expect([lt.isLocal, lt.platform, lt.localWithDevice], [false, 'ios', false]);
    expect(matrixVariants, ['lt-ios', 'lt-android', 'ios', 'android']);
  });

  test('interleaves the platforms, keeping each platform in order', () {
    final legs = ['a:lt-ios', 'b:lt-ios', 'c:lt-ios', 'a:lt-android'].map((s) => MatrixLeg.parse(s)!).toList();
    expect(interleaveByPlatform(legs).map((leg) => '$leg'), ['a:lt-ios', 'a:lt-android', 'b:lt-ios', 'c:lt-ios']);
    final mixed = ['a:ios', 'a:lt-ios', 'a:android'].map((s) => MatrixLeg.parse(s)!).toList();
    expect(interleaveByPlatform(mixed).map((leg) => '$leg'), ['a:ios', 'a:android', 'a:lt-ios']);
    expect(interleaveByPlatform(const []), isEmpty);
  });

  group('run directory', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('mplatrol_matrix'));
    tearDown(() => root.deleteSync(recursive: true));

    test('lays out the leg files and appends timestamped queue lines', () {
      final run = MatrixRunDir(p.join(root.path, '2026-10-03-round7'));
      final leg = MatrixLeg.parse('initech:lt-android')!;
      expect(run.id, '2026-10-03-round7');
      expect(run.started, isFalse);
      expect(run.log(leg), p.join(run.path, 'initech_lt-android.log'));
      expect(run.times(leg), p.join(run.path, 'initech_lt-android.log.times'));
      expect(run.legDir(leg), p.join(run.path, 'legs', 'initech_lt-android'));
      expect(run.junit(leg, DateTime.utc(2026, 10, 3, 7, 4, 5)),
          p.join(run.path, 'legs', 'initech_lt-android', 'reports', 'junit-initech-lt-android-20261003T070405Z.xml'));

      run.append('lane1 start initech:lt-android', DateTime(2026, 10, 3, 9, 5, 7));
      run.writeTimings('report');
      expect(File(run.queueLog).readAsStringSync(), '2026-10-03 09:05:07 lane1 start initech:lt-android\n');
      expect(run.started, isTrue);
      expect(File(p.join(run.path, 'timings.md')).readAsStringSync(), 'report');
    });

    test('an app checkout has a pubspec', () {
      expect(isAppCheckout(root.path), isFalse);
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app');
      expect(isAppCheckout(root.path), isTrue);
    });
  });
}
