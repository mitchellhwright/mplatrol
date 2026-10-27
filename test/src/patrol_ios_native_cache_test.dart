import 'dart:io';

import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:mplatrol/src/patrol_safe_failure_report_patch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory _repo;
const _metadata = LocalReuseMetadataStore();
const _nativePath = '.mplatrol/patched_packages/patrol/$patrolIosTextInputSourcePath';

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('patrol-native-cache-');
    _seedRuntimeSkipBridge();
  });
  tearDown(() => _repo.deleteSync(recursive: true));
  _registerFingerprintTests();
}

File _write(String relative, String contents) => File(p.join(_repo.path, relative))
  ..createSync(recursive: true)
  ..writeAsStringSync(contents);

File _seedNative() =>
    _write(_nativePath, File('test/fixtures/patrol_ios_text_input/upstream_methods.swift').readAsStringSync());

Directory get _patrolRoot => Directory(p.join(_repo.path, '.mplatrol', 'patched_packages', 'patrol'));

void _seedRuntimeSkipBridge() {
  for (final entry in patrolRuntimeSkipSources.entries) {
    _write('.mplatrol/patched_packages/patrol/${entry.value}',
        File('test/fixtures/patrol_runtime_skip/${entry.key}.txt').readAsStringSync());
  }
  patchPatrolRuntimeSkip(_patrolRoot);
  patchPatrolSafeFailureReport(_patrolRoot);
  expect(hasPatrolRuntimeSkipPatch(_patrolRoot), isTrue);
}

LocalReuseRequest _request(ItVariant variant) => LocalReuseRequest(
      variant: variant,
      deviceId: 'SIM-test',
      tenant: 'demo',
      environment: 'QA',
      target: null,
      targetRegex: null,
      sdk: null,
    );

void _registerFingerprintTests() {
  for (final variant in [ItVariant.iosLocal, ItVariant.ltIos]) {
    test('${variant.id} hashes transformed Swift with unchanged overrides and then reuses', () {
      final source = _seedNative();
      final overrides = _write(
          'pubspec_overrides.yaml', 'dependency_overrides:\n  patrol:\n    path: .mplatrol/patched_packages/patrol\n');
      final originalOverrides = overrides.readAsStringSync();
      final request = _request(variant);
      LocalReuseDecision evaluate() => _metadata.evaluate(repo: _repo.path, request: request, explicit: true);
      _metadata.recordSuccessfulRun(repo: _repo.path, request: request);
      final old = evaluate();
      expect(old.reuseLast, isFalse);
      expect(old.reason, contains('native input patch is missing or stale'));
      patchPatrolIosTextInput(_patrolRoot);
      final changed = evaluate();
      expect(changed.fingerprint, isNot(old.fingerprint));
      expect(changed.reuseLast, isFalse);
      expect(overrides.readAsStringSync(), originalOverrides);
      _metadata.recordSuccessfulRun(repo: _repo.path, request: request);
      patchPatrolIosTextInput(_patrolRoot);
      _write('.dart_tool/unrelated.cache', 'changed');
      _write('.mplatrol/unrelated.cache', 'changed');
      expect(evaluate().reuseLast, isTrue);
      source.writeAsStringSync('${source.readAsStringSync()}\n// native build input changed\n');
      expect(evaluate().fingerprint, isNot(changed.fingerprint));
      expect(evaluate().reuseLast, isFalse);
      _metadata.recordSuccessfulRun(repo: _repo.path, request: request);
      source.deleteSync();
      expect(evaluate().reuseLast, isFalse);
    });
  }
  test('iOS-only generated native edits leave the Android fingerprint unchanged', () {
    final source = _seedNative();
    final request = _request(ItVariant.androidLocal);
    final before = _metadata.evaluate(repo: _repo.path, request: request).fingerprint;
    patchPatrolIosTextInput(_patrolRoot);
    expect(_metadata.evaluate(repo: _repo.path, request: request).fingerprint, before);
    source.deleteSync();
    expect(_metadata.evaluate(repo: _repo.path, request: request).fingerprint, before);
  });
}
