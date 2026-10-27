import 'dart:io';

import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory _repo;
const _metadata = LocalReuseMetadataStore();
const _request = LocalReuseRequest(
  variant: ItVariant.iosLocal,
  deviceId: 'SIM-test',
  tenant: 'demo',
  environment: 'QA',
  target: null,
  targetRegex: null,
  sdk: null,
);
const _derivedPaths = [
  'ios/Flutter/Generated.xcconfig',
  'ios/Flutter/flutter_export_environment.sh',
];

void main() {
  setUp(() => _repo = Directory.systemTemp.createTempSync('reuse-fingerprint'));
  tearDown(() => _repo.deleteSync(recursive: true));
  _registerDerivedInputTests();
  _registerSourceProtectionTests();
}

void _write(String path, String contents) {
  File(p.join(_repo.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

LocalReuseDecision _evaluate() => _metadata.evaluate(repo: _repo.path, request: _request);

void _registerDerivedInputTests() {
  test('Flutter config-only derived rewrites do not invalidate the compiled inputs', () {
    _write('lib/main.dart', 'source');
    for (final path in _derivedPaths) {
      _write(path, 'FLUTTER_TARGET=lib/main.dart');
    }
    _metadata.recordSuccessfulRun(repo: _repo.path, request: _request);
    final before = _evaluate();
    for (final path in _derivedPaths) {
      _write(path, 'FLUTTER_TARGET=patrol_test/test_bundle.dart');
    }
    final after = _evaluate();
    expect(before.reuseLast, isTrue);
    expect(after.reuseLast, isTrue);
    expect(after.fingerprint, before.fingerprint);
  });

  test('adding and removing only the two derived Flutter files preserves reuse', () {
    _write('lib/main.dart', 'source');
    _metadata.recordSuccessfulRun(repo: _repo.path, request: _request);
    final before = _evaluate();
    for (final path in _derivedPaths) {
      _write(path, 'derived');
    }
    expect(_evaluate().fingerprint, before.fingerprint);
    expect(_evaluate().reuseLast, isTrue);
    for (final path in _derivedPaths) {
      File(p.join(_repo.path, path)).deleteSync();
    }
    expect(_evaluate().fingerprint, before.fingerprint);
    expect(_evaluate().reuseLast, isTrue);
  });
}

void _registerSourceProtectionTests() {
  for (final path in [
    'lib/main.dart',
    'lib/generated/model.g.dart',
    'patrol_test/login_test.dart',
    'integration_test/login_test.dart',
    'ios/RunnerUITests/RunnerUITests.swift',
    'ios/Runner.xcodeproj/project.pbxproj',
    'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    'ios/Flutter/Debug.xcconfig',
    'ios/Flutter/Profile.xcconfig',
    'ios/Flutter/Release.xcconfig',
    'ios/Flutter/AppFrameworkInfo.plist',
    'ios/Podfile.lock',
    'pubspec.yaml',
    'pubspec.lock',
    'pubspec_overrides.yaml',
    '.fvm/fvm_config.json',
    'assets/config.json',
    'tenants/demo/config.json',
  ]) {
    test('real source/build edits still reject reuse: $path', () {
      _write(path, 'before');
      _metadata.recordSuccessfulRun(repo: _repo.path, request: _request);
      final before = _evaluate();
      final modified = File(p.join(_repo.path, path)).lastModifiedSync();
      _write(path, 'after');
      File(p.join(_repo.path, path)).setLastModifiedSync(modified);
      final after = _evaluate();
      expect(before.reuseLast, isTrue);
      expect(after.reuseLast, isFalse);
      expect(after.fingerprint, isNot(before.fingerprint));
    });
  }

  test('Android filtered wrapper edits still reject Android reuse', () {
    const android = LocalReuseRequest(
      variant: ItVariant.androidLocal,
      deviceId: 'emulator-5554',
      tenant: 'demo',
      environment: 'QA',
      target: null,
      targetRegex: 'login',
      sdk: null,
    );
    LocalReuseDecision evaluate() => _metadata.evaluate(repo: _repo.path, request: android);
    _write('patrol_test/mplatrol_filtered_test.dart', 'before');
    final before = evaluate().fingerprint;
    _write('patrol_test/mplatrol_filtered_test.dart', 'after');
    expect(evaluate().fingerprint, isNot(before));
  });

  test('real source additions and removals still change the fingerprint', () {
    _write('lib/removed.dart', 'source');
    _metadata.recordSuccessfulRun(repo: _repo.path, request: _request);
    final before = _evaluate();
    File(p.join(_repo.path, 'lib/removed.dart')).deleteSync();
    _write('lib/added.dart', 'source');
    final after = _evaluate();
    expect(after.reuseLast, isFalse);
    expect(after.fingerprint, isNot(before.fingerprint));
  });
}
