import 'dart:io';

import 'package:mplatrol/src/ios_simulator_ui_tests_link.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;
  late File xcconfig;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('ios_sim_link');
    addTearDown(() => repo.deleteSync(recursive: true));
    xcconfig = File(p.join(repo.path, 'ios', 'Pods', 'Target Support Files', 'Pods-Runner-RunnerUITests',
        'Pods-Runner-RunnerUITests.debug.xcconfig'))
      ..createSync(recursive: true)
      ..writeAsStringSync('FRAMEWORK_SEARCH_PATHS = \$(inherited) "\${PODS_ROOT}/Firebase"\n'
          'OTHER_LDFLAGS = \$(inherited) -ObjC -l"c++" -framework "patrol"\n'
          'PODS_ROOT = \${SRCROOT}/Pods\n');
    File(p.join(repo.path, 'ios', 'Flutter', 'Generated.xcconfig'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// Generated\nFLUTTER_ROOT=/fvm/versions/3.41.6\nFLUTTER_APPLICATION_PATH=/repo\n');
  });

  test('links Flutter.framework into RunnerUITests for the simulator SDK only', () {
    expect(linkFlutterIntoSimulatorUiTests(repo.path), isTrue);

    final patched = xcconfig.readAsStringSync();
    expect(patched,
        contains(r'OTHER_LDFLAGS = $(inherited) -ObjC -l"c++" -framework "patrol" $(MPLATROL_SIM_FLUTTER_LDFLAGS)'));
    expect(patched,
        contains(r'FRAMEWORK_SEARCH_PATHS = $(inherited) "${PODS_ROOT}/Firebase" $(MPLATROL_SIM_FLUTTER_FRAMEWORKS)'));
    expect(patched, contains('MPLATROL_SIM_FLUTTER_LDFLAGS[sdk=iphonesimulator*] = -framework Flutter'));
    expect(
        patched,
        contains('MPLATROL_SIM_FLUTTER_FRAMEWORKS[sdk=iphonesimulator*] = '
            '"/fvm/versions/3.41.6/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"'));
    expect(patched, contains('SWIFT_ENABLE_EXPLICIT_MODULES = NO'));
    expect(patched, contains('CLANG_ENABLE_EXPLICIT_MODULES = NO'));
    expect(patched, contains(r'PODS_ROOT = ${SRCROOT}/Pods'));
  });

  test('is idempotent', () {
    linkFlutterIntoSimulatorUiTests(repo.path);
    final once = xcconfig.readAsStringSync();

    expect(linkFlutterIntoSimulatorUiTests(repo.path), isFalse);
    expect(xcconfig.readAsStringSync(), once);
  });

  test('adds the settings when the Pods xcconfig has none', () {
    xcconfig.writeAsStringSync('PODS_ROOT = \${SRCROOT}/Pods\n');

    expect(linkFlutterIntoSimulatorUiTests(repo.path), isTrue);

    final patched = xcconfig.readAsStringSync();
    expect(patched, contains(r'OTHER_LDFLAGS = $(inherited) $(MPLATROL_SIM_FLUTTER_LDFLAGS)'));
    expect(patched, contains(r'FRAMEWORK_SEARCH_PATHS = $(inherited) $(MPLATROL_SIM_FLUTTER_FRAMEWORKS)'));
  });

  for (final (name, setUpMissing) in [
    ('the Pods xcconfig is missing', (Directory r) => xcconfig.deleteSync()),
    (
      'Generated.xcconfig is missing',
      (Directory r) => File(p.join(r.path, 'ios', 'Flutter', 'Generated.xcconfig')).deleteSync()
    ),
    (
      'FLUTTER_ROOT is empty',
      (Directory r) => File(p.join(r.path, 'ios', 'Flutter', 'Generated.xcconfig')).writeAsStringSync('FLUTTER_ROOT=\n')
    ),
    (
      'FLUTTER_ROOT is absent',
      (Directory r) => File(p.join(r.path, 'ios', 'Flutter', 'Generated.xcconfig')).writeAsStringSync('A=B\n')
    ),
  ]) {
    test('changes nothing when $name', () {
      setUpMissing(repo);
      final before = xcconfig.existsSync() ? xcconfig.readAsStringSync() : null;

      expect(linkFlutterIntoSimulatorUiTests(repo.path), isFalse);
      expect(xcconfig.existsSync() ? xcconfig.readAsStringSync() : null, before);
    });
  }
}
