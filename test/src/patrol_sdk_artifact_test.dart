import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.repo.deleteSync(recursive: true));
  _duplicateZipCases(() => fixture);
  _compiledCases(() => fixture);
  _uploadCases(() => fixture);
  _receiptCases(() => fixture);
  _cacheBoundaryCases(() => fixture);
  _cacheCases(() => fixture);
}

void _compiledCases(_Fixture Function() current) {
  test('compiled pair binds selection, binary identities and upload IDs', () async {
    final f = current();
    final receipt = await f.upload();
    f.validate(receipt);
    expect(f.uploads, 1);
    final data = receipt.toJson();
    expect((data['app'] as Map)['size'], File(f.app).lengthSync());
    expect((data['manifest'] as Map)['selection'], f.plan.toJson());
  });
  for (final role in ['app', 'test']) {
    for (final failure in ['missing', 'absent asset', 'malformed', 'wrong identity']) {
      test('$role $failure aborts before upload', () async {
        final f = current();
        final path = role == 'app' ? f.app : f.testApk;
        switch (failure) {
          case 'missing':
            File(path).deleteSync();
          case 'absent asset':
            f.apk(path, entry: 'assets/unrelated.json');
          case 'malformed':
            f.apk(path, contents: '{');
          case 'wrong identity':
            final data = f.asset()..['buildIdentity'] = 'different-environment-build';
            f.apk(path, contents: jsonEncode(data));
        }
        await expectLater(f.upload(), throwsStateError);
        expect(f.uploads, 0);
      });
    }
  }
  test('semantic JSON key ordering does not invalidate compiled evidence', () async {
    final f = current();
    final data = f.asset();
    f.apk(f.app, contents: jsonEncode({for (final key in data.keys.toList().reversed) key: data[key]}));
    f.validate(await f.upload());
  });
  test('invalid APK fails before upload', () async {
    final f = current();
    File(f.app).writeAsBytesSync([1, 2, 3]);
    await expectLater(f.upload(), throwsStateError);
    expect(f.uploads, 0);
  });
  test('zero eligible selection cannot produce compiled assets', () {
    final f = current();
    final file = File(p.join(f.repo.path, patrolSdkRequirementsPath));
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    ((data['tests'] as List).single as Map)['platforms'] = ['ios'];
    file.writeAsStringSync(jsonEncode(data));
    final plan = planPatrolSdkSelection(f.repo.path, platform: 'android');
    expect(plan.selectedCount, 0);
    expect(() => prepareAndroidPatrolSdkAssets(plan, buildIdentity: 'build', nativeGeneratorIdentity: 'generator'),
        throwsStateError);
  });
  test('unknown platform producer is not activated', () {
    final f = current();
    final plan = planPatrolSdkSelection(f.repo.path, platform: 'ios');
    expect(() => prepareAndroidPatrolSdkAssets(plan, buildIdentity: 'build', nativeGeneratorIdentity: 'generator'),
        throwsStateError);
  });
  for (final identity in ['build', 'generator']) {
    test('missing $identity fails before assets or uploads', () {
      final f = current();
      expect(
          () => prepareAndroidPatrolSdkAssets(f.plan,
              buildIdentity: identity == 'build' ? '' : 'build',
              nativeGeneratorIdentity: identity == 'generator' ? '' : 'generator'),
          throwsStateError);
    });
  }
}

void _uploadCases(_Fixture Function() current) {
  for (final role in ['app', 'test']) {
    test('$role changed during upload never records receipt', () async {
      final f = current();
      await expectLater(f.upload(action: () {
        File(role == 'app' ? f.app : f.testApk).writeAsStringSync('changed');
        return (appId: 'app-id', testId: 'test-id');
      }), throwsStateError);
      expect(f.uploads, 1);
    });
  }
  test('prepared source changed during upload never records receipt', () async {
    final f = current();
    await expectLater(f.upload(action: () {
      f.write('pubspec.lock', 'changed');
      return (appId: 'app-id', testId: 'test-id');
    }), throwsStateError);
  });
  test('upload boundary failure propagates without retry', () async {
    final f = current();
    await expectLater(f.upload(action: () => throw StateError('provider unavailable')), throwsStateError);
    expect(f.uploads, 1);
  });
  for (final role in ['app', 'test']) {
    test('missing uploaded $role ID cannot produce receipt', () async {
      final f = current();
      await expectLater(
          f.upload(action: () => (appId: role == 'app' ? '' : 'app-id', testId: role == 'test' ? '' : 'test-id')),
          throwsStateError);
    });
  }
}

void _receiptCases(_Fixture Function() current) {
  for (final key in ['schema', 'receiptDigest', 'manifest', 'app', 'test']) {
    test('damaged receipt $key fails closed', () async {
      final data = (await current().upload()).toJson()..remove(key);
      expect(() => PatrolSdkArtifactReceipt.fromJson(data), throwsStateError);
    });
  }
  for (final field in ['build', 'generator', 'app', 'test']) {
    test('different $field identity refuses uploaded pair reuse', () async {
      final f = current();
      final receipt = await f.upload();
      expect(
          () => receipt.validate(
              selection: f.plan,
              buildIdentity: field == 'build' ? 'other' : 'build',
              nativeGeneratorIdentity: field == 'generator' ? 'other' : 'generator',
              appId: field == 'app' ? 'other' : 'app-id',
              testId: field == 'test' ? 'other' : 'test-id'),
          throwsStateError);
    });
  }
  for (final (field, value) in [
    ('schema', 2),
    ('platform', 'ios'),
  ]) {
    test('receipt manifest with unsupported $field fails closed', () async {
      final data = (await current().upload()).toJson();
      (data['manifest'] as Map)[field] = value;
      expect(
          () => PatrolSdkArtifactReceipt.fromJson(data),
          throwsA(isA<StateError>()
              .having((error) => error.message, 'message', contains('Unsupported compiled SDK manifest'))));
    });
  }
  for (final size in [0, -1, '12', null]) {
    test('receipt binary size $size fails closed', () async {
      final data = (await current().upload()).toJson();
      (data['test'] as Map)['size'] = size;
      expect(() => PatrolSdkArtifactReceipt.fromJson(data),
          throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Unknown SDK binary size'))));
    });
  }
  test('receipt export mutation does not mutate provenance', () async {
    final f = current();
    final receipt = await f.upload();
    (receipt.toJson()['app'] as Map)['id'] = 'other';
    f.validate(receipt);
  });
}

void _cacheBoundaryCases(_Fixture Function() current) {
  for (final body in [
    '{',
    '{"app":1,"test":"test-id","nativeGenerator":"generator"}',
    '{"app":"app-id","test":"test-id","nativeGenerator":"old"}'
  ]) {
    test('incomplete cache $body cannot reach loaded callback', () {
      final f = current();
      File(f.cache).writeAsStringSync(body);
      expect(f.load(), isNull);
      expect(f.loaded, 0);
      expect(f.reason, 'incomplete');
    });
  }
  test('SDK receipt cannot be saved without current selection', () async {
    final f = current();
    final receipt = await f.upload();
    expect(
        () => f.support
            .saveCachedAppIds(f.cache, 'app-id', 'test-id', nativeGeneratorIdentity: 'generator', sdkReceipt: receipt),
        throwsStateError);
    expect(File(f.cache).existsSync(), isFalse);
  });
  test('SDK cache requires complete build identity on reuse', () async {
    final f = current();
    f.save(await f.upload());
    expect(
        f.support.loadCachedAppIds(f.cache,
            nativeGeneratorIdentity: 'generator',
            sdkSelection: f.plan,
            onMissing: () {},
            onIncomplete: () {},
            onSdkInvalid: (value) => f.reason = value,
            onLoaded: (appId, testId) => f.loaded++),
        isNull);
    expect(f.reason, contains('complete build identity'));
    expect(f.loaded, 0);
  });
}

void _cacheCases(_Fixture Function() current) {
  test('legacy pair remains usable without SDK stage activation', () {
    final f = current();
    f.support.saveCachedAppIds(f.cache, 'app-id', 'test-id', nativeGeneratorIdentity: 'generator');
    expect(f.load(), ('app-id', 'test-id'));
    expect(f.loaded, 1);
  });
  test('legacy cache cannot satisfy SDK-aware reuse', () {
    final f = current();
    f.support.saveCachedAppIds(f.cache, 'app-id', 'test-id', nativeGeneratorIdentity: 'generator');
    expect(f.load(selected: true), isNull);
    expect(f.reason, contains('receipt'));
    expect(f.loaded, 0);
  });
  test('SDK-bound cache rejects a consumer without SDK selection', () async {
    final f = current();
    f.save(await f.upload());
    expect(f.load(), isNull);
    expect(f.reason, contains('current selection'));
    expect(f.loaded, 0);
  });
  test('matching receipt permits exact uploaded pair without new upload', () async {
    final f = current();
    f.save(await f.upload());
    expect(f.load(selected: true), ('app-id', 'test-id'));
    expect(f.loaded, 1);
    expect(f.uploads, 1);
  });
  test('different complete build identity prevents reuse', () async {
    final f = current();
    f.save(await f.upload());
    expect(f.load(selected: true, build: 'different'), isNull);
    expect(f.reason, contains('differs'));
  });
  test('saving receipt with another pair fails before writing cache', () async {
    final f = current();
    final receipt = await f.upload();
    expect(
        () => f.support.saveCachedAppIds(f.cache, 'other', 'test-id',
            nativeGeneratorIdentity: 'generator', sdkReceipt: receipt, sdkSelection: f.plan, sdkBuildIdentity: 'build'),
        throwsStateError);
    expect(File(f.cache).existsSync(), isFalse);
  });
  test('source drift invalidates receipt on reuse', () async {
    final f = current();
    f.save(await f.upload());
    f.write('pubspec.lock', 'changed');
    expect(f.load(selected: true), isNull);
    expect(f.reason, contains('inputs changed'));
  });
  test('SDK failure falls back to existing incomplete callback if none provided', () async {
    final f = current();
    f.save(await f.upload());
    var incomplete = 0;
    final result = f.support.loadCachedAppIds(f.cache,
        nativeGeneratorIdentity: 'generator',
        onMissing: () {},
        onIncomplete: () => incomplete++,
        onLoaded: (appId, testId) => f.loaded++);
    expect(result, isNull);
    expect(incomplete, 1);
    expect(f.loaded, 0);
  });
}

class _Fixture {
  _Fixture() {
    write('pubspec.yaml', 'name: app\npatrol:\n  test_directory: patrol_test\n');
    write('pubspec.lock', 'packages: {}');
    write('patrol_test/core_test.dart', "patrolTest('existing login');");
    write('lib/core/feature_registrations.dart', 'void register() {}');
    write('.dart_tool/package_config.json', '{"configVersion":2,"packages":[]}');
    write('.flutter-plugins-dependencies', '{"plugins":{"android":[],"ios":[]}}');
    write(
        patrolSdkRequirementsPath,
        jsonEncode({
          'schema': 1,
          'capabilities': {},
          'unresolvedRegistrations': [],
          'tests': [
            {
              'file': 'patrol_test/core_test.dart',
              'descriptions': ['existing login'],
              'platforms': ['android', 'ios'],
              'requires': [],
              'coverage': 'journey',
            }
          ],
        }));
    plan = planPatrolSdkSelection(repo.path, platform: 'android');
    prepareAndroidPatrolSdkAssets(plan, buildIdentity: 'build', nativeGeneratorIdentity: 'generator');
    apk(app);
    apk(testApk);
  }

  final repo = Directory.systemTemp.createTempSync('sdk-artifact-');
  final support = _Support();
  late PatrolSelectionPlan plan;
  int uploads = 0;
  int loaded = 0;
  String? reason;
  String get app => p.join(repo.path, 'app.apk');
  String get testApk => p.join(repo.path, 'test.apk');
  String get cache => p.join(repo.path, 'uploads.json');

  void write(String path, String contents) => File(p.join(repo.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  Map<String, dynamic> asset() =>
      jsonDecode(File(p.join(repo.path, 'android/app/src/main/assets', patrolSdkArtifactAsset)).readAsStringSync())
          as Map<String, dynamic>;

  void apk(String path, {String? contents, String entry = 'assets/mplatrol-sdk-selection.json'}) {
    final bytes = utf8.encode(contents ?? jsonEncode(asset()));
    final archive = Archive()..addFile(ArchiveFile(entry, bytes.length, bytes));
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  }

  Future<PatrolSdkArtifactReceipt> upload({({String appId, String testId}) Function()? action}) =>
      uploadPatrolSdkArtifacts(
          selection: plan,
          buildIdentity: 'build',
          nativeGeneratorIdentity: 'generator',
          appApk: app,
          testApk: testApk,
          upload: () async {
            uploads++;
            return action == null ? (appId: 'app-id', testId: 'test-id') : action();
          });

  void validate(PatrolSdkArtifactReceipt receipt) => receipt.validate(
      selection: plan,
      buildIdentity: 'build',
      nativeGeneratorIdentity: 'generator',
      appId: 'app-id',
      testId: 'test-id');

  void save(PatrolSdkArtifactReceipt receipt) => support.saveCachedAppIds(cache, 'app-id', 'test-id',
      nativeGeneratorIdentity: 'generator', sdkReceipt: receipt, sdkSelection: plan, sdkBuildIdentity: 'build');

  (String, String)? load({bool selected = false, String build = 'build'}) => support.loadCachedAppIds(cache,
      nativeGeneratorIdentity: 'generator',
      sdkSelection: selected ? plan : null,
      sdkBuildIdentity: selected ? build : null,
      onMissing: () => reason = 'missing',
      onIncomplete: () => reason = 'incomplete',
      onSdkInvalid: (value) => reason = value,
      onLoaded: (appId, testId) => loaded++);
}

class _Support with LtRunSupport {
  @override
  Duration get pollDelay => Duration.zero;
  @override
  final FileSystem ltFileSystem = FileSystem.constructGlobalInstance();
}

void _duplicateZipCases(_Fixture Function() current) {
  for (final role in ['app', 'test']) {
    test('real duplicate ZIP selection entries in $role refuse before upload', () async {
      final f = current();
      final contents = utf8.encode(jsonEncode(f.asset()));
      const name = 'assets/mplatrol-sdk-selection.json';
      const other = 'assets/mplatrol-sdk-selection.jsoX';
      final archive = Archive()
        ..addFile(ArchiveFile(name, contents.length, contents))
        ..addFile(ArchiveFile(other, contents.length, contents));
      final bytes = ZipEncoder().encode(archive);
      _replaceZipName(bytes, utf8.encode(other), utf8.encode(name));
      final decoder = ZipDecoder();
      final decoded = decoder.decodeBytes(bytes);
      expect(decoder.directory.fileHeaders.where((entry) => entry.filename == name).length, 2);
      expect(decoded.where((entry) => entry.name == name).length, 1,
          reason: 'Archive collapses names; counting decoded files cannot reject duplicates');
      File(role == 'app' ? f.app : f.testApk).writeAsBytesSync(bytes);
      await expectLater(f.upload(), throwsStateError);
      expect(f.uploads, 0);
    });
  }
}

void _replaceZipName(List<int> bytes, List<int> oldName, List<int> name) {
  for (var offset = 0; offset <= bytes.length - oldName.length; offset++) {
    var matches = true;
    for (var index = 0; index < oldName.length; index++) {
      if (bytes[offset + index] != oldName[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      bytes.setRange(offset, offset + name.length, name);
    }
  }
}
