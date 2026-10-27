import 'dart:io';

import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:mplatrol/src/patrol_safe_failure_report_patch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory _repo;
const _store = LocalReuseMetadataStore();

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('patrol-runtime-freshness-');
    _write('build/app/outputs/apk/debug/app-debug.apk', 'app');
    _write('build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk', 'test');
    for (final entry in patrolRuntimeSkipSources.entries) {
      _write('.mplatrol/patched_packages/patrol/${entry.value}',
          File('test/fixtures/patrol_runtime_skip/${entry.key}.txt').readAsStringSync());
    }
    _write('.mplatrol/patched_packages/patrol/$patrolIosTextInputSourcePath',
        File('test/fixtures/patrol_ios_text_input/upstream_methods.swift').readAsStringSync());
    patchPatrolIosTextInput(_root);
    patchPatrolSafeFailureReport(_root);
  });
  tearDown(() => _repo.deleteSync(recursive: true));
  _registerCacheTests();
  _registerCompletenessTests();
}

Directory get _root => Directory(p.join(_repo.path, '.mplatrol/patched_packages/patrol'));

void _write(String relative, String source) => File(p.join(_repo.path, relative))
  ..createSync(recursive: true)
  ..writeAsStringSync(source);

LocalReuseRequest _request(ItVariant variant) => LocalReuseRequest(
      variant: variant,
      deviceId: 'SIM-test',
      tenant: 'demo',
      environment: 'QA',
      target: null,
      targetRegex: null,
      sdk: null,
    );

LocalReuseDecision _evaluate(LocalReuseRequest request) =>
    _store.evaluate(repo: _repo.path, request: request, explicit: true);

void _registerCacheTests() {
  for (final variant in ItVariant.values) {
    test('${variant.id} old compiled bridge is invalidated, unchanged bridge reuses', () {
      final request = _request(variant);
      _store.recordSuccessfulRun(repo: _repo.path, request: request);
      final old = _evaluate(request);
      expect(old.reuseLast, isFalse);
      expect(old.reason, contains('runtime skip patch'));
      patchPatrolRuntimeSkip(_root);
      expect(_evaluate(request).fingerprint, isNot(old.fingerprint));
      expect(_evaluate(request).reuseLast, isFalse);
      _store.recordSuccessfulRun(repo: _repo.path, request: request);
      patchPatrolRuntimeSkip(_root);
      expect(_evaluate(request).reuseLast, isTrue);
    });
    for (final relative in patrolRuntimeSkipMobileInputs) {
      test('${variant.id} detects during-build edits to $relative even with same mtime', () {
        patchPatrolRuntimeSkip(_root);
        final request = _request(variant);
        _store.recordSuccessfulRun(repo: _repo.path, request: request);
        final buildStarted = _evaluate(request).fingerprint;
        final file = File(p.join(_repo.path, relative));
        final modified = file.lastModifiedSync();
        file.writeAsStringSync('${file.readAsStringSync()}\n// real compiled source edit\n');
        file.setLastModifiedSync(modified);
        expect(_evaluate(request).fingerprint, isNot(buildStarted));
        expect(_evaluate(request).reuseLast, isFalse);
      });
    }
    test('${variant.id} unused web and unrelated generated sources do not churn mobile cache', () {
      patchPatrolRuntimeSkip(_root);
      final request = _request(variant);
      _store.recordSuccessfulRun(repo: _repo.path, request: request);
      final before = _evaluate(request).fingerprint;
      final web = File(p.join(_root.path, patrolRuntimeSkipSources['web']!));
      web.writeAsStringSync('${web.readAsStringSync()}\n// unused web source change\n');
      _write('.mplatrol/patched_packages/patrol/lib/uncompiled.dart', 'unused');
      expect(_evaluate(request).fingerprint, before);
      expect(_evaluate(request).reuseLast, isTrue);
    });
  }
}

void _registerCompletenessTests() {
  for (final kind in patrolRuntimeSkipSources.keys) {
    test('missing $kind fails closed, including web signature compatibility', () {
      patchPatrolRuntimeSkip(_root);
      final request = _request(ItVariant.androidLocal);
      _store.recordSuccessfulRun(repo: _repo.path, request: request);
      File(p.join(_root.path, patrolRuntimeSkipSources[kind]!)).deleteSync();
      expect(hasPatrolRuntimeSkipPatch(_root), isFalse);
      expect(_evaluate(request).reuseLast, isFalse);
      expect(_evaluate(request).reason, contains('runtime skip patch'));
    });
    test('incomplete $kind patch fails without partial repair', () {
      patchPatrolRuntimeSkip(_root);
      final file = File(p.join(_root.path, patrolRuntimeSkipSources[kind]!));
      final marker = switch (kind) {
        'global_state' => 'state.result == Result.skipped',
        'binding' => 'global_state.isCurrentTestSkipped',
        _ => 'required this.skipped',
      };
      final source = file.readAsStringSync().replaceFirst(marker, 'BROKEN_RUNTIME_SKIP');
      file.writeAsStringSync(source);
      expect(hasPatrolRuntimeSkipPatch(_root), isFalse);
      expect(() => patchPatrolRuntimeSkip(_root), throwsStateError);
      expect(file.readAsStringSync(), source);
    });
  }
}
