import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_ios_native_views_patch.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:test/test.dart';

const _fixture = 'test/fixtures/patrol_ios_native_views';

void main() {
  final upstream = File('$_fixture/upstream.swift').readAsStringSync();
  test('preserves predicate and scope, exact recipe is idempotent', () {
    final patched = patchPatrolIosNativeViewsSource(upstream);
    expect(patched, contains('matching(selector.toNSPredicate())'));
    expect(patched, contains('self.getApp(withBundleId: bundleId)'));
    expect(patched, isNot(contains('allElementsBoundByIndex')));
    expect(patched, contains('let snapshot = try element.snapshot()'));
    expect(patchPatrolIosNativeViewsSource(patched), patched);
  });
  test('changed, ambiguous and incomplete native sources fail closed', () {
    final patched = patchPatrolIosNativeViewsSource(upstream);
    for (final invalid in [
      '',
      '$upstream$upstream',
      upstream.replaceFirst('matching(selector.toNSPredicate())', 'matching(otherPredicate)'),
      upstream.replaceFirst('inApp bundleId: String', 'inApp otherApp: String'),
      patched.replaceFirst('try element.snapshot()', 'element.snapshot()'),
      upstream.replaceFirst('fromXCUIElementSnapshot', 'unsupportedConverter'),
    ]) {
      expect(() => patchPatrolIosNativeViewsSource(invalid), throwsStateError);
    }
  });
  test('prepared copy rejects stale recipe and preserves unchanged timestamps', () {
    final root = Directory.systemTemp.createTempSync('patrol-snapshot-patch-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/$patrolIosTextInputSourcePath');
    expect(hasPatrolIosNativeViewsPatch(root), isFalse);
    expect(() => patchPatrolIosNativeViews(root), throwsA(isA<FileSystemException>()));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(upstream);
    expect(hasPatrolIosNativeViewsPatch(root), isFalse);
    patchPatrolIosNativeViews(root);
    expect(hasPatrolIosNativeViewsPatch(root), isTrue);
    file.setLastModifiedSync(DateTime.utc(2000));
    patchPatrolIosNativeViews(root);
    expect(file.lastModifiedSync().toUtc(), DateTime.utc(2000));
  });
  test('source-derived recipe changes existing receipt identity, then remains stable', () {
    final old = (FingerprintBuilder()..addString('unchanged Dart inputs')).finish();
    String current() => (FingerprintBuilder()
          ..addString(patrolIosNativeViewsPatchIdentity())
          ..addString('unchanged Dart inputs'))
        .finish();
    expect(current(), isNot(old));
    expect(current(), current());
  });
  test('actual patched Swift executes boundary fixture; old code fails mutation', () async {
    await _runSwiftFixture(upstream, patched: false);
    await _runSwiftFixture(upstream, patched: true);
  }, testOn: 'mac-os');
  test('actual patched query typechecks against Apple XCTest', () async {
    await _typecheckXCTest(patchPatrolIosNativeViewsSource(upstream));
  }, testOn: 'mac-os');
}

Future<void> _runSwiftFixture(String upstream, {required bool patched}) async {
  final root = Directory.systemTemp.createTempSync('patrol-snapshot-swift-');
  addTearDown(() => root.deleteSync(recursive: true));
  final source = patched ? patchPatrolIosNativeViewsSource(upstream) : upstream;
  final boundary = source.indexOf('    static func fromXCUIElementSnapshot');
  final harness = File('$_fixture/harness.swift')
      .readAsStringSync()
      .replaceFirst('// INSERT_QUERY', source.substring(0, boundary))
      .replaceFirst('// INSERT_CONVERTER', source.substring(boundary));
  final file = File('${root.path}/main.swift')..writeAsStringSync(harness);
  final binary = '${root.path}/fixture';
  final compile = await Process.run('/usr/bin/swiftc', [file.path, '-o', binary]);
  expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  if (compile.exitCode != 0) {
    return;
  }
  final run = await Process.run(binary, []);
  if (patched) {
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('SWIFT_SNAPSHOT_FIXTURE_PASSED'));
  } else {
    expect(run.exitCode, isNot(0));
    expect(run.stderr, contains('LIVE_INDEX_COLLECTION_INVALIDATED'));
  }
}

Future<void> _typecheckXCTest(String source) async {
  final root = Directory.systemTemp.createTempSync('patrol-snapshot-xctest-');
  addTearDown(() => root.deleteSync(recursive: true));
  final boundary = source.indexOf('    static func fromXCUIElementSnapshot');
  final file = File('${root.path}/query.swift')..writeAsStringSync('''
import XCTest
struct IOSSelector { func toNSPredicate() -> NSPredicate { NSPredicate(value: true) } }
struct IOSNativeView {
  static func fromXCUIElementSnapshot(_ s: XCUIElementSnapshot, _ id: String) -> IOSNativeView {
    IOSNativeView()
  }
}
class Automator {
  func getApp(withBundleId id: String) throws -> XCUIApplication { XCUIApplication(bundleIdentifier: id) }
  func createLogMessage(element: String, from: IOSSelector) -> String { element }
  func runAction<T>(_ log: String, block: () throws -> T) rethrows -> T { try block() }
${source.substring(0, boundary)}
}
''');
  final developer = await Process.run('/usr/bin/xcode-select', ['-p']);
  expect(developer.exitCode, 0);
  final frameworks = '${developer.stdout.toString().trim()}'
      '/Platforms/MacOSX.platform/Developer/Library/Frameworks';
  final compile = await Process.run('/usr/bin/xcrun', [
    '--sdk',
    'macosx',
    'swiftc',
    '-typecheck',
    '-F',
    frameworks,
    file.path,
  ]);
  expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
}
