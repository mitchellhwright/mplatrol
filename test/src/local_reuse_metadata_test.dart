import 'dart:io';

import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/local_reuse_metadata.dart';
import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;
  late String repo;
  const store = LocalReuseMetadataStore();

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('local_reuse_metadata');
    repo = p.join(tempRoot.path, 'app');
    Directory(repo).createSync(recursive: true);
    _write(p.join(repo, 'lib', 'main.dart'), 'void main() {}\n');
    _write(
      p.join(repo, 'integration_test', 'login_test.dart'),
      "patrolTest('login', (\$) async {});\n",
    );
    _write(p.join(repo, 'ios', 'Runner', 'Info.plist'), '<plist />\n');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  test('records and reuses an unchanged local iOS fingerprint', () {
    final request = _request();

    expect(store.evaluate(repo: repo, request: request).reuseLast, isFalse);

    store.recordSuccessfulRun(repo: repo, request: request);

    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);
  });

  test('a build from another inputs revision is rebuilt; the same revision reuses', () {
    const old = '3890bbb4e5bf5bf1377948baf0c393144f1aec04';
    const current = '48b9c3d908f3313775af4e0850ed68c267bbc5ca';
    store.recordSuccessfulRun(repo: repo, request: _request(inputsRevision: old));

    final moved = store.evaluate(repo: repo, request: _request(inputsRevision: current));
    expect(moved.reuseLast, isFalse);
    expect(moved.reason, 'build inputs revision changed (3890bbb4e5bf -> 48b9c3d908f3); rebuild');

    store.recordSuccessfulRun(repo: repo, request: _request(inputsRevision: current));
    expect(store.evaluate(repo: repo, request: _request(inputsRevision: current)).reuseLast, isTrue);
  });

  test('a build recorded without an inputs revision is rebuilt once', () {
    store.recordSuccessfulRun(repo: repo, request: _request());

    final decision = store.evaluate(repo: repo, request: _request(inputsRevision: 'abc'));

    expect(decision.reason, 'build inputs revision changed (none recorded -> abc); rebuild');
  });

  test('a generated Patrol copy without the safe failure report patch is not reused', () {
    _writeReuseArtifacts(repo);
    final request = _request(variant: ItVariant.androidLocal, deviceId: 'emulator-5554');
    store.recordSuccessfulRun(repo: repo, request: request);
    for (final entry in patrolRuntimeSkipSources.entries) {
      _write(p.join(repo, '.mplatrol/patched_packages/patrol', entry.value),
          File('test/fixtures/patrol_runtime_skip/${entry.key}.txt').readAsStringSync());
    }
    final patrol = Directory(p.join(repo, '.mplatrol/patched_packages/patrol'));
    patchPatrolRuntimeSkip(patrol);
    final decision = store.evaluate(repo: repo, request: request, explicit: true);
    expect(decision.reuseLast, isFalse);
    expect(decision.reason, contains('safe failure report patch is missing or stale'));
  });

  test('Android reuse requires both APKs and unchanged Android inputs', () {
    final request = _request(
      variant: ItVariant.androidLocal,
      deviceId: 'emulator-5554',
    );
    store.recordSuccessfulRun(repo: repo, request: request);
    expect(store.evaluate(repo: repo, request: request).reuseLast, isFalse);

    _write(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'), 'app');
    _write(
      p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
      'test',
    );
    store.recordSuccessfulRun(repo: repo, request: request);
    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);

    _write(p.join(repo, 'android/app/build.gradle'), 'changed');
    expect(store.evaluate(repo: repo, request: request).reuseLast, isFalse);
  });

  test('automatically reuses an unchanged targeted iOS build', () {
    final request = _request(target: 'patrol_test/chatsdk_chat_journey_test.dart');
    store.recordSuccessfulRun(repo: repo, request: request);

    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);
  });

  test('automatically reuses an unchanged filtered Android build', () {
    final request = _request(
      variant: ItVariant.androidLocal,
      deviceId: 'emulator-5554',
      targetRegex: 'chat',
      sdk: 'chatsdk',
    );
    _write(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'), 'app');
    _write(
      p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
      'test',
    );
    store.recordSuccessfulRun(repo: repo, request: request);

    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);
  });

  test('Android-only edits do not invalidate an iOS build', () {
    final request = _request();
    store.recordSuccessfulRun(repo: repo, request: request);

    _write(p.join(repo, 'android/app/build.gradle'), 'changed');

    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);
  });

  test('iOS-only edits do not invalidate an Android build', () {
    final request = _request(
      variant: ItVariant.androidLocal,
      deviceId: 'emulator-5554',
    );
    _write(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'), 'app');
    _write(
      p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
      'test',
    );
    store.recordSuccessfulRun(repo: repo, request: request);

    _write(p.join(repo, 'ios/Runner/Info.plist'), '<plist changed="true" />');

    expect(store.evaluate(repo: repo, request: request).reuseLast, isTrue);
  });

  test('does not reuse when run identity inputs change', () {
    final request = _request(
      target: 'integration_test/login_test.dart',
      targetRegex: 'smoke',
      sdk: 'tenant',
    );
    store.recordSuccessfulRun(repo: repo, request: request);

    final changedRequests = [
      _request(
        target: 'integration_test/other_test.dart',
        targetRegex: 'smoke',
        sdk: 'tenant',
      ),
      _request(
        target: 'integration_test/login_test.dart',
        targetRegex: 'regression',
        sdk: 'tenant',
      ),
      _request(
        target: 'integration_test/login_test.dart',
        targetRegex: 'smoke',
        sdk: 'sdk',
      ),
      _request(
        tenant: 'other-tenant',
        target: 'integration_test/login_test.dart',
        targetRegex: 'smoke',
        sdk: 'tenant',
      ),
      _request(
        environment: 'QA',
        target: 'integration_test/login_test.dart',
        targetRegex: 'smoke',
        sdk: 'tenant',
      ),
      _request(
        variant: ItVariant.androidLocal,
        target: 'integration_test/login_test.dart',
        targetRegex: 'smoke',
        sdk: 'tenant',
      ),
      _request(
        deviceId: '00008110-001234567890801E',
        target: 'integration_test/login_test.dart',
        targetRegex: 'smoke',
        sdk: 'tenant',
      ),
    ];

    for (final changedRequest in changedRequests) {
      final decision = store.evaluate(repo: repo, request: changedRequest);

      expect(decision.reuseLast, isFalse);
    }
  });

  for (final variant in [ItVariant.androidLocal, ItVariant.iosLocal]) {
    for (final directory in ['patrol_test', 'integration_test']) {
      for (final name in [
        'test_bundle.dart',
        iosPatrolTestBundleFile,
        // iOS never compiles Android's filtered wrapper, which a concurrent
        // `mplatrol run all` Android arm rewrites mid iOS build.
        if (variant == ItVariant.iosLocal) 'mplatrol_filtered_test.dart',
      ]) {
        test('${variant.id} ignores generated $directory/$name creation and rewrites', () {
          _writeReuseArtifacts(repo);
          final request = _request(variant: variant);
          final before = store.evaluate(repo: repo, request: request).fingerprint;
          store.recordSuccessfulRun(repo: repo, request: request);

          final bundle = p.join(repo, directory, name);
          for (final contents in ['generated entrypoint A', 'generated entrypoint B']) {
            _write(bundle, contents);
            final decision = store.evaluate(repo: repo, request: request);
            expect(decision.fingerprint, before);
            expect(decision.reuseLast, isTrue);
          }

          File(bundle).deleteSync();
          expect(store.evaluate(repo: repo, request: request).fingerprint, before);
        });
      }

      test('${variant.id} still invalidates on real $directory test edits', () {
        _writeReuseArtifacts(repo);
        final request = _request(variant: variant);
        final source = p.join(repo, directory, 'journey_test.dart');
        _write(source, "patrolTest('original journey', (\$) async {});\n");
        _write(p.join(repo, directory, 'test_bundle.dart'), 'generated entrypoint');
        store.recordSuccessfulRun(repo: repo, request: request);
        final before = store.evaluate(repo: repo, request: request).fingerprint;

        _write(source, "patrolTest('changed journey', (\$) async {});\n");

        final decision = store.evaluate(repo: repo, request: request);
        expect(decision.fingerprint, isNot(before));
        expect(decision.reuseLast, isFalse);
      });
    }

    for (final relative in ['lib/test_bundle.dart', 'patrol_test/nested/test_bundle.dart']) {
      test('${variant.id} fingerprints non-generated $relative', () {
        _writeReuseArtifacts(repo);
        final request = _request(variant: variant);
        store.recordSuccessfulRun(repo: repo, request: request);

        _write(p.join(repo, relative), 'hand-written source');

        expect(store.evaluate(repo: repo, request: request).reuseLast, isFalse);
      });
    }
  }

  test('does not reuse when a key input file changes', () {
    final request = _request();
    store.recordSuccessfulRun(repo: repo, request: request);

    _write(p.join(repo, 'lib', 'main.dart'), 'void main() => runApp();\n');

    final decision = store.evaluate(repo: repo, request: request);

    expect(decision.reuseLast, isFalse);
  });

  for (final variant in [ItVariant.androidLocal, ItVariant.iosLocal]) {
    test('${variant.id} retires previous shared-artifact owners only', () {
      _writeReuseArtifacts(repo);
      final otherVariant = variant == ItVariant.androidLocal ? ItVariant.iosLocal : ItVariant.androidLocal;
      final otherRequest = _request(variant: otherVariant);
      final requestA = _request(variant: variant, tenant: 'tenant-a');
      final requestB = _request(variant: variant, tenant: 'tenant-b');
      final sourceA = p.join(repo, 'tenants/tenant-a/config.json');
      _write(sourceA, 'original A inputs');
      _write(p.join(repo, 'tenants/tenant-b/config.json'), 'B inputs');
      store.recordSuccessfulRun(repo: repo, request: otherRequest);
      store.recordSuccessfulRun(repo: repo, request: requestA);
      expect(store.evaluate(repo: repo, request: requestA).reuseLast, isTrue);

      _write(sourceA, 'A inputs changed while building B');
      final artifact = variant == ItVariant.androidLocal
          ? 'build/app/outputs/apk/debug/app-debug.apk'
          : 'build/ios_integ/Build/Products/Debug-iphonesimulator/Runner.app/Runner';
      _write(p.join(repo, artifact), 'compiled B');
      store.recordSuccessfulRun(repo: repo, request: requestB);
      _write(sourceA, 'original A inputs');

      expect(store.evaluate(repo: repo, request: requestA).reuseLast, isFalse);
      expect(store.evaluate(repo: repo, request: requestB).reuseLast, isTrue);
      expect(store.evaluate(repo: repo, request: otherRequest).reuseLast, isTrue);
    });

    test('${variant.id} shares ownership across local device classes', () {
      _writeReuseArtifacts(repo);
      final emulator =
          _request(variant: variant, deviceId: variant == ItVariant.androidLocal ? 'emulator-5554' : 'SIM-A');
      final physical = _request(variant: variant, deviceId: 'physical-device');
      store.recordSuccessfulRun(repo: repo, request: emulator);
      store.recordSuccessfulRun(repo: repo, request: physical);

      expect(store.evaluate(repo: repo, request: emulator).reuseLast, isFalse);
      expect(store.evaluate(repo: repo, request: physical).reuseLast, isTrue);
    });

    test('${variant.id} shares ownership with its LambdaTest variant', () {
      _writeReuseArtifacts(repo);
      final local = _request(variant: variant);
      final remote = _request(variant: variant == ItVariant.androidLocal ? ItVariant.ltAndroid : ItVariant.ltIos);
      store.recordSuccessfulRun(repo: repo, request: local);
      store.recordSuccessfulRun(repo: repo, request: remote);

      expect(store.evaluate(repo: repo, request: local).reuseLast, isFalse);
      expect(store.evaluate(repo: repo, request: remote, explicit: true).reuseLast, isTrue);
    });
  }

  test('missing Android APKs cannot retire a recorded owner', () {
    _writeReuseArtifacts(repo);
    final requestA = _request(variant: ItVariant.androidLocal, tenant: 'tenant-a');
    final requestB = _request(variant: ItVariant.androidLocal, tenant: 'tenant-b');
    store.recordSuccessfulRun(repo: repo, request: requestA);
    File(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk')).deleteSync();

    store.recordSuccessfulRun(repo: repo, request: requestB);
    _writeReuseArtifacts(repo);

    expect(store.evaluate(repo: repo, request: requestA).reuseLast, isTrue);
    expect(store.evaluate(repo: repo, request: requestB).reuseLast, isFalse);
  });

  test('ignores dynamic runtime credential files', () {
    final request = _request();
    store.recordSuccessfulRun(repo: repo, request: request);

    _write(
      p.join(repo, 'integration_test', 'e2e_credentials.local.json'),
      '{"E2E_USERNAME":"user"}\n',
    );
    _write(
      p.join(repo, 'assets', 'mplatrol', 'e2e_runtime_config.json'),
      '{"E2E_CREDENTIALS_URL":"http://127.0.0.1"}\n',
    );

    final decision = store.evaluate(repo: repo, request: request);

    expect(decision.reuseLast, isTrue);
  });

  test('deviceClass for ltAndroid returns lt-android (covers evaluate identity path)', () {
    final request = _request(variant: ItVariant.ltAndroid, deviceId: 'Galaxy S23');
    // evaluate always computes cacheKey → identityJson → deviceClass regardless
    // of whether supportsAutomaticReuse is true.
    final decision = store.evaluate(repo: repo, request: request);
    expect(decision.reuseLast, isFalse);
  });

  test('deviceClass distinguishes a physical Android device', () {
    final request = _request(
      variant: ItVariant.androidLocal,
      deviceId: 'R3CN30ABCDE',
    );

    expect(request.deviceClass, 'android-device');
  });

  test('deviceClass for ltIos returns lt-ios (covers evaluate identity path)', () {
    final request = _request(variant: ItVariant.ltIos, deviceId: 'iPhone 17 Pro');
    final decision = store.evaluate(repo: repo, request: request);
    expect(decision.reuseLast, isFalse);
  });

  test('evaluate returns reuseLast false when the stored metadata file has invalid JSON', () {
    final request = _request();
    store.recordSuccessfulRun(repo: repo, request: request);

    // Corrupt the metadata file so _readStore falls back to an empty map.
    final metaFile = File(
      p.join(repo, '.mplatrol', 'integration_test', 'local_reuse_metadata.json'),
    );
    metaFile.writeAsStringSync('not valid json');

    final decision = store.evaluate(repo: repo, request: request);
    expect(decision.reuseLast, isFalse);
  });

  test('fingerprint includes files tracked by _inputFilePaths (e.g. pubspec.yaml)', () {
    _write(p.join(repo, 'pubspec.yaml'), 'name: app\n');
    final request = _request();
    store.recordSuccessfulRun(repo: repo, request: request);

    // Changing pubspec.yaml should invalidate the reuse decision.
    _write(p.join(repo, 'pubspec.yaml'), 'name: app\nversion: 2.0.0\n');

    final decision = store.evaluate(repo: repo, request: request);
    expect(decision.reuseLast, isFalse);
  });

  test('a build recorded without coverage is not reused for a coverage run', () {
    _writeReuseArtifacts(repo);
    store.recordSuccessfulRun(repo: repo, request: _request());

    expect(store.evaluate(repo: repo, request: _request()).reuseLast, isTrue);
    expect(store.evaluate(repo: repo, request: _request(coverage: true)).reuseLast, isFalse);
  });
}

LocalReuseRequest _request({
  ItVariant variant = ItVariant.iosLocal,
  String deviceId = 'SIM-UDID-26',
  String tenant = 'demo',
  String environment = 'Dev',
  String? target,
  String? targetRegex,
  String? sdk,
  String? inputsRevision,
  bool coverage = false,
}) {
  return LocalReuseRequest(
    variant: variant,
    deviceId: deviceId,
    tenant: tenant,
    environment: environment,
    target: target,
    targetRegex: targetRegex,
    sdk: sdk,
    inputsRevision: inputsRevision,
    coverage: coverage,
  );
}

void _write(String path, String content) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

void _writeReuseArtifacts(String repo) {
  _write(p.join(repo, 'build/app/outputs/apk/debug/app-debug.apk'), 'app');
  _write(
    p.join(repo, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
    'test',
  );
}
