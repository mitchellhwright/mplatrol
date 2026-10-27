import 'dart:io';

import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;
  const store = LocalReuseMetadataStore();
  setUp(() {
    repo = Directory.systemTemp.createTempSync('local-timeout-metadata-');
    for (final relative in [
      'build/app/outputs/apk/debug/app-debug.apk',
      'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk',
    ]) {
      final file = File(p.join(repo.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('retained compiled artifact');
    }
  });
  tearDown(() => repo.deleteSync(recursive: true));

  for (final timeout in [null, 0, -1, 240000]) {
    test('normalized default timeout $timeout reuses the same cache', () {
      store.recordSuccessfulRun(repo: repo.path, request: _request());
      final original = store.evaluate(repo: repo.path, request: _request());
      final decision = store.evaluate(repo: repo.path, request: _request(timeout));
      expect(decision.reuseLast, isTrue);
      expect(decision.cacheKey, original.cacheKey);
      expect(decision.fingerprint, original.fingerprint);
    });
  }

  test('changed positive compiled timeout invalidates then stabilizes', () {
    store.recordSuccessfulRun(repo: repo.path, request: _request(240000));
    final original = store.evaluate(repo: repo.path, request: _request(240000));
    final changed = store.evaluate(repo: repo.path, request: _request(600000));
    expect(changed.reuseLast, isFalse);
    expect(changed.fingerprint, isNot(original.fingerprint));
    expect(changed.reason, contains('native Patrol generator identity'));
    store.recordSuccessfulRun(repo: repo.path, request: _request(600000));
    expect(store.evaluate(repo: repo.path, request: _request(600000)).reuseLast, isTrue);
    expect(store.evaluate(repo: repo.path, request: _request(240000)).reuseLast, isFalse);
  });

  test('Android timeout does not invalidate iOS cache identity', () {
    final original = _request(240000, ItVariant.iosLocal);
    store.recordSuccessfulRun(repo: repo.path, request: original);
    expect(store.evaluate(repo: repo.path, request: _request(600000, ItVariant.iosLocal)).reuseLast, isTrue);
  });
}

LocalReuseRequest _request([int? timeout, ItVariant variant = ItVariant.androidLocal]) => LocalReuseRequest(
      variant: variant,
      deviceId: 'emulator-audit',
      tenant: 'audit',
      environment: 'Staging',
      target: null,
      targetRegex: null,
      sdk: null,
      androidTestTimeoutMs: timeout,
    );
