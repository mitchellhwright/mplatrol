import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _request = LocalReuseRequest(
  variant: ItVariant.iosLocal,
  deviceId: 'SIM-cache-audit',
  tenant: 'audit',
  environment: 'Staging',
  target: 'patrol_test/cache_test.dart',
  targetRegex: null,
  sdk: null,
);
const _store = LocalReuseMetadataStore();

void main() {
  late Directory repo;
  late File runner;
  late String currentRunner;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('native-generator-cache-audit-');
    final test = File(p.join(repo.path, 'patrol_test/cache_test.dart'));
    test.parent.createSync(recursive: true);
    test.writeAsStringSync("patrolTest('cache journey', (\$) async {});\n");
    generateIosPatrolRunner(repo.path, target: _request.target);
    runner = File(p.join(repo.path, 'ios/RunnerUITests/RunnerUITests.swift'));
    currentRunner = runner.readAsStringSync();
  });

  tearDown(() => repo.deleteSync(recursive: true));
  _registerAndroidIdentityTests(() => repo);

  test('unchanged generated native runner remains reusable', () {
    _store.recordSuccessfulRun(repo: repo.path, request: _request);
    expect(_store.evaluate(repo: repo.path, request: _request).reuseLast, isTrue);
  });

  test('real native source changes invalidate reuse', () {
    _store.recordSuccessfulRun(repo: repo.path, request: _request);
    runner.writeAsStringSync('$currentRunner\n// Native source changed.\n');
    expect(_store.evaluate(repo: repo.path, request: _request).reuseLast, isFalse);
  });

  test('older generator output must be rejected before reuse skips generation', () {
    // Model a build recorded by an older CLI with different generated Swift.
    runner.writeAsStringSync('$currentRunner\n// Previous generator revision.\n');
    _store.recordSuccessfulRun(repo: repo.path, request: _request);
    _changeStoredIdentity(repo.path, null);
    final beforeGeneration = _store.evaluate(repo: repo.path, request: _request);

    generateIosPatrolRunner(repo.path, target: _request.target);
    expect(runner.readAsStringSync(), currentRunner);
    expect(_store.evaluate(repo: repo.path, request: _request).reuseLast, isFalse);
    expect(beforeGeneration.reuseLast, isFalse,
        reason: 'LocalRunner returns to cached execution before regenerating Swift');
  });
  test('changed generator identity rejects otherwise unchanged native inputs', () {
    _store.recordSuccessfulRun(repo: repo.path, request: _request);
    _changeStoredIdentity(repo.path, 'previous-templatrole-digest');
    final decision = _store.evaluate(repo: repo.path, request: _request);
    expect(decision.reuseLast, isFalse);
    expect(decision.reason, contains('native Patrol generator identity'));
  });
}

void _changeStoredIdentity(String repo, String? identity) {
  final file = File(p.join(repo, '.mplatrol/integration_test/local_reuse_metadata.json'));
  final metadata = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final entries = metadata['entries'] as Map<String, dynamic>;
  for (final value in entries.values) {
    final entry = value as Map<String, dynamic>;
    if (identity == null) {
      entry.remove('nativeGenerator');
    } else {
      entry['nativeGenerator'] = identity;
    }
  }
  file.writeAsStringSync(jsonEncode(metadata));
}

void _registerAndroidIdentityTests(Directory Function() currentRepo) {
  const request = LocalReuseRequest(
    variant: ItVariant.androidLocal,
    deviceId: 'emulator-5554',
    tenant: 'audit',
    environment: 'Staging',
    target: null,
    targetRegex: null,
    sdk: null,
  );
  for (final identity in ['current', null, 'previous-templatrole-digest']) {
    test('local Android generator identity: $identity', () {
      final repo = currentRepo().path;
      for (final relative in [
        'build/app/outputs/apk/debug/app-debug.apk',
        'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk',
      ]) {
        final file = File(p.join(repo, relative));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('retained artifact');
      }
      _store.recordSuccessfulRun(repo: repo, request: request);
      if (identity != 'current') {
        _changeStoredIdentity(repo, identity);
      }
      expect(_store.evaluate(repo: repo, request: request).reuseLast, identity == 'current');
    });
  }
}
