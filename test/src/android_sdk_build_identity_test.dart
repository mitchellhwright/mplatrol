import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/android_sdk_build_identity.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_android_native_views_patch.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.root.deleteSync(recursive: true));
  for (final path in [
    'app/lib/feature.dart',
    'app/android/build.gradle',
    'app/custom-assets/theme.json',
    'dependency/lib/source.dart',
    'dependency/lib/src/build/actual_source.dart',
    'dependency/android/build.gradle',
    'dependency/hook/build.dart',
    'app/android/app/signature.properties'
  ]) {
    test('actual build input $path invalidates identity', () {
      fixture.write(path, 'before');
      final before = fixture.identity();
      fixture.write(path, 'after');
      expect(fixture.identity(), isNot(before));
    });
  }
  test('Flutter version pin remains an input while SDK caches are excluded', () {
    fixture.write('app/.fvm/fvm_config.json', '{"flutterSdkVersion":"one"}');
    final before = fixture.identity();
    fixture.write('app/.fvm/fvm_config.json', '{"flutterSdkVersion":"two"}');
    expect(fixture.identity(), isNot(before));
  });
  test('derived SDK assets do not recursively change their own identity', () {
    final before = fixture.identity();
    prepareAndroidPatrolSdkAssets(fixture.plan, buildIdentity: before, nativeGeneratorIdentity: 'generator');
    expect(fixture.identity(), before);
  });
  test('concurrent iOS bundle writes do not change Android identity', () {
    final before = fixture.identity();
    fixture.write('app/patrol_test/$iosPatrolTestBundleFile', 'ios bundle');
    expect(fixture.identity(), before);
    fixture.write('dependency/lib/source.dart', 'void changed() {}');
    expect(fixture.identity(), isNot(before));
  });
  test('runtime environment and exact compiled arguments change identity', () {
    final env = {'MPLATROL_E2E_ENVIRONMENT': 'QA'};
    final before = fixture.identity(env: env);
    env['MPLATROL_E2E_ENVIRONMENT'] = 'Staging';
    expect(fixture.identity(env: env), isNot(before));
    expect(androidSdkBuildArguments(fixture.plan, env), contains('--dart-define=E2E_ENVIRONMENT=Staging'));
  });
  test('remote job/tunnel naming does not change compiled build identity', () {
    expect(fixture.identity(env: {'LT_BUILD_NAME': 'one', 'LT_TUNNEL_NAME': 'one'}),
        fixture.identity(env: {'LT_BUILD_NAME': 'two', 'LT_TUNNEL_NAME': 'two'}));
  });
  test('native snapshot recipe is bound independently of prepared package bytes', () {
    final digests = <String, String>{};
    androidSdkBuildIdentity(fixture.plan, env: {}, nativeGeneratorIdentity: 'generator', inputDigests: digests);
    expect(digests['build/native-snapshot-recipe'],
        (FingerprintBuilder()..addString(patrolAndroidNativeViewsPatchIdentity())).finish());
  });
  _packageBindingCases(() => fixture);
  _optimizationCases(() => fixture);
  _privateInputDiagnosticCases(() => fixture);
  _localPropertiesCases(() => fixture);
  _ndkIntermediateCases(() => fixture);
  _dependencyJavaCases(() => fixture);
  _assetMetadataCases(() => fixture);
  test('missing resolved dependency source root fails closed', () {
    Directory(p.join(fixture.root.path, 'dependency')).deleteSync(recursive: true);
    expect(fixture.identity, throwsStateError);
  });
  test('unresolved source link is refused rather than silently omitted', () {
    Link(p.join(fixture.repo.path, 'lib/source-link')).createSync('missing-input');
    expect(fixture.identity, throwsStateError);
  });
}

void _dependencyJavaCases(_Fixture Function() current) {
  for (final path in [
    'dependency/java/src/main/java/com/example/PortContinuation.java',
    'dependency/java/src/main/java/com/example/PortProxy.java',
  ]) {
    test('compiled dependency Java input $path changes identity', () {
      final fixture = current();
      fixture.write(path, 'class NativeBridge { int result() { return 1; } }');
      final before = fixture.identity();
      fixture.write(path, 'class NativeBridge { int result() { return 2; } }');
      expect(fixture.identity(), isNot(before));
    });
  }
  for (final path in [
    'dependency/java/src/test/java/com/example/UnusedTest.java',
    'dependency/java/docs/guide.md',
    'dependency/java/build/generated/sources/Generated.java',
    'dependency/java/build/classes/Generated.class',
  ]) {
    test('uncompiled dependency Java input $path preserves identity', () {
      final fixture = current();
      fixture.write(path, 'original unused input');
      final before = fixture.identity();
      fixture.write(path, 'changed unused input');
      expect(fixture.identity(), before);
    });
  }
}

void _ndkIntermediateCases(_Fixture Function() current) {
  for (final module in ['app/android/app', 'dependency/android']) {
    test('first-build NDK intermediates under $module leave identity stable', () {
      final fixture = current();
      fixture.write(
          '$module/build.gradle',
          'android { externalNativeBuild {} '
              'defaultConfig {\napplicationId "com.example.tenant.staging"\n} }');
      final before = fixture.identity();
      for (final output in [
        'Debug/hash/arm64-v8a/CMakeCache.txt',
        'Debug/hash/arm64-v8a/build.ninja',
        'Debug/hash/arm64-v8a/.cmake/api/v1/query/client-agp/cache-v2',
        'Debug/hash/arm64-v8a/.cmake/api/v1/reply/index.json',
        'Debug/hash/arm64-v8a/CMakeFiles/CompilerIdC/CMakeCCompilerId.c',
        'Debug/hash/arm64-v8a/CMakeFiles/jni.dir/dartjni.c.o',
        'tools/profile/arm64-v8a/compile_commands.json',
      ]) {
        fixture.write('$module/.cxx/$output', 'generated first-build output');
      }
      expect(fixture.identity(), before);
      fixture.write('$module/.cxx/Debug/hash/arm64-v8a/CMakeCache.txt', 'regenerated');
      expect(fixture.identity(), before);
    });
  }
  test('Kotlin Gradle module intermediate root is recognized', () {
    final fixture = current();
    fixture.write('dependency/android/library/build.gradle.kts', 'plugins {}');
    final before = fixture.identity();
    fixture.write('dependency/android/library/.cxx/Debug/hash/build.ninja', 'generated');
    expect(fixture.identity(), before);
  });
  for (final path in [
    'app/android/app/src/main/cpp/feature.cpp',
    'app/android/app/src/main/cpp/CMakeLists.txt',
    'dependency/CMakeLists.txt',
    'dependency/src/dartjni.c',
    'dependency/src/include/dart_api_dl.h',
    'dependency/src/native.cpp',
    'dependency/src/native.cxx',
    'dependency/src/CMakeLists.txt',
    'dependency/android/build.gradle',
    'dependency/android/native/build.gradle.kts',
    'dependency/android/src/main/cpp/feature.cpp',
    'dependency/android/src/main/cpp/feature.cxx',
    'dependency/android/src/main/cpp/CMakeLists.txt',
    'dependency/android/src/main/cpp/include/sdk.h',
    'dependency/android/src/main/jniLibs/arm64-v8a/libsdk.so',
    'dependency/android/src/main/assets/sdk/data.bin',
    'dependency/android/src/main/cpp/.cxx/real_source.cpp',
    'dependency/android/.cxx-not-intermediate/real_source.cpp',
    'dependency/android/.cxx',
  ]) {
    test('genuine native input $path still changes identity', () {
      final fixture = current();
      fixture.write('dependency/android/build.gradle', 'android {}');
      fixture.write(path, 'original input');
      final before = fixture.identity();
      fixture.write(path, 'changed input');
      expect(fixture.identity(), isNot(before));
    });
  }
  test('directory named .cxx without Gradle module marker remains an input', () {
    final fixture = current();
    fixture.write('dependency/android/custom/.cxx/source.cpp', 'original');
    final before = fixture.identity();
    fixture.write('dependency/android/custom/.cxx/source.cpp', 'changed');
    expect(fixture.identity(), isNot(before));
  });
}

void _localPropertiesCases(_Fixture Function() current) {
  const properties = 'sdk.dir=/fixture/android\n'
      'flutter.sdk=/fixture/flutter\n'
      'flutter.buildMode=release\n'
      'flutter.versionName=1.2.0\nflutter.versionCode=12\ncustom.control=retained';
  const path = 'app/android/local.properties';
  test('prepare stamps effective debug mode before Flutter updates properties', () {
    final fixture = current();
    fixture.write(path, properties);
    prepareAndroidSdkBuildProperties(fixture.repo.path);
    final stamped = fixture.identity();
    fixture.write(path, properties.replaceFirst('buildMode=release', 'buildMode=debug'));
    expect(fixture.identity(), stamped);
  });
  test('unchanged prepared properties remain byte and mtime stable', () {
    final fixture = current();
    final contents = properties.replaceFirst('buildMode=release', 'buildMode=debug');
    fixture.write(path, contents);
    final file = File(p.join(fixture.repo.path, 'android/local.properties'));
    final modified = file.lastModifiedSync();
    prepareAndroidSdkBuildProperties(fixture.repo.path);
    expect(file.readAsStringSync(), contents);
    expect(file.lastModifiedSync(), modified);
  });
  for (final change in [
    ('sdk.dir=/fixture/android', 'sdk.dir=/different/android'),
    ('flutter.sdk=/fixture/flutter', 'flutter.sdk=/different/flutter'),
    ('flutter.buildMode=debug', 'flutter.buildMode=profile'),
    ('flutter.versionName=1.2.0', 'flutter.versionName=1.3.0'),
    ('flutter.versionCode=12', 'flutter.versionCode=13'),
    ('custom.control=retained', 'custom.control=changed'),
  ]) {
    test('post-stamp real property change ${change.$1} still invalidates', () {
      final fixture = current();
      final contents = properties.replaceFirst('buildMode=release', 'buildMode=debug');
      fixture.write(path, contents);
      prepareAndroidSdkBuildProperties(fixture.repo.path);
      final before = fixture.identity();
      fixture.write(path, contents.replaceFirst(change.$1, change.$2));
      expect(fixture.identity(), isNot(before));
    });
  }
  test('ambiguous duplicate mode refuses preparation', () {
    final fixture = current();
    fixture.write(path, '$properties\nflutter.buildMode=debug');
    expect(() => prepareAndroidSdkBuildProperties(fixture.repo.path), throwsStateError);
  });
  test('missing mode is prepared without changing SDK or version controls', () {
    final fixture = current();
    const contents = 'sdk.dir=/fixture/android\nflutter.versionCode=12';
    fixture.write(path, contents);
    prepareAndroidSdkBuildProperties(fixture.repo.path);
    final file = File(p.join(fixture.repo.path, 'android/local.properties'));
    expect(file.readAsStringSync(), '$contents\nflutter.buildMode=debug\nflutter.versionName=1.2.0');
  });
  test('missing properties are not invented and later generated inputs invalidate', () {
    final fixture = current();
    prepareAndroidSdkBuildProperties(fixture.repo.path);
    final before = fixture.identity();
    fixture.write(path, properties);
    expect(fixture.identity(), isNot(before));
  });
  test('linked properties refuse preparation without modifying their target', () {
    final fixture = current();
    fixture.write('outside.properties', properties);
    final target = File(p.join(fixture.root.path, 'outside.properties'));
    final link = Link(p.join(fixture.repo.path, 'android/local.properties'));
    link.parent.createSync(recursive: true);
    link.createSync(target.path);
    expect(() => prepareAndroidSdkBuildProperties(fixture.repo.path), throwsStateError);
    expect(target.readAsStringSync(), properties);
  });
  test('explicit debug mode is part of compiled argument identity', () {
    expect(androidSdkBuildArguments(current().plan, const {}), contains('--debug'));
  });
  test("builds without Patrol's red test-name label over the app", () {
    expect(androidSdkBuildArguments(current().plan, const {}), contains('--no-label'));
  });
  _derivedVersionCases(current);
}

void _derivedVersionCases(_Fixture Function() current) {
  for (final version in ['1.2.0', '1.2.0+0012', '1.2.0+build.0', null]) {
    test('stages source-derived version $version before Flutter property rewrite', () {
      final fixture = current();
      fixture.write(
          'app/pubspec.yaml',
          'name: app\n'
              '${version == null ? '' : 'version: $version\n'}');
      fixture.write(
          'app/android/local.properties',
          '# old build\r\n'
              'sdk.dir=/fixture/android\r\nflutter.sdk=/fixture/flutter\r\n'
              'flutter.buildMode=release\r\nflutter.versionName=old\r\n'
              'flutter.versionCode=999\r\ncustom.control=retained\r\n');
      prepareAndroidSdkBuildProperties(fixture.repo.path);
      final file = File(p.join(fixture.repo.path, 'android/local.properties'));
      final code = version == '1.2.0+0012' ? '12' : '1';
      final expected = 'sdk.dir=/fixture/android\nflutter.sdk=/fixture/flutter\n'
          'flutter.buildMode=debug'
          '${version == null ? '' : '\nflutter.versionName=1.2.0'}'
          '${version?.contains('+') == true ? '\nflutter.versionCode=$code' : ''}'
          '\ncustom.control=retained';
      expect(file.readAsStringSync(), expected);
      final before = fixture.identity();
      file.writeAsStringSync(expected);
      expect(fixture.identity(), before);
      final modified = file.lastModifiedSync();
      prepareAndroidSdkBuildProperties(fixture.repo.path);
      expect(file.lastModifiedSync(), modified);
    });
  }
  for (final contents in [
    'sdk.dir=/fixture/android\nsdk.dir=/different/android',
    'flutter.versionName=one\nflutter.versionName=two',
    'flutter.versionCode=1\nflutter.versionCode=2',
    'flutter.buildMode: release',
    'flutter\\.buildMode=release',
    'flutter.buildMode =release',
  ]) {
    test('unsafe local properties refuse without mutation: $contents', () {
      final fixture = current();
      fixture.write('app/android/local.properties', contents);
      expect(() => prepareAndroidSdkBuildProperties(fixture.repo.path), throwsStateError);
      expect(File(p.join(fixture.repo.path, 'android/local.properties')).readAsStringSync(), contents);
    });
  }
  for (final version in ['not-a-version', '[unterminated', 'false', '{}']) {
    test('malformed source version $version refuses before property mutation', () {
      final fixture = current();
      fixture.write('app/pubspec.yaml', 'name: app\nversion: $version\n');
      fixture.write('app/android/local.properties', 'flutter.buildMode=release');
      expect(() => prepareAndroidSdkBuildProperties(fixture.repo.path), throwsStateError);
      expect(
          File(p.join(fixture.repo.path, 'android/local.properties')).readAsStringSync(), 'flutter.buildMode=release');
    });
  }
  test('source version remains a whole-file compilation input', () {
    final fixture = current();
    fixture.write('app/android/local.properties', 'flutter.buildMode=debug');
    prepareAndroidSdkBuildProperties(fixture.repo.path);
    final before = fixture.identity();
    fixture.write('app/pubspec.yaml', 'name: app\nversion: 2.0.0+99\n');
    expect(fixture.identity(), isNot(before));
  });
}

class _Fixture {
  _Fixture() {
    write(
        'app/pubspec.yaml',
        'name: app\nversion: 1.2.0+12\npatrol:\n'
            '  test_directory: patrol_test\nflutter:\n  assets:\n    - custom-assets/\n');
    write('app/android/app/build.gradle', 'android { defaultConfig {\napplicationId "com.example.tenant.staging"\n} }');
    write('app/pubspec.lock', 'packages: {}');
    write('app/patrol_test/core_test.dart', "patrolTest('existing test');");
    write('app/lib/core/feature_registrations.dart', 'void register() {}');
    write('dependency/lib/source.dart', 'void dependency() {}');
    write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'dependency', 'rootUri': '../../dependency', 'packageUri': 'lib/'},
          ],
        }));
    write('app/.flutter-plugins-dependencies', '{"plugins":{"android":[],"ios":[]}}');
    write(
        'app/patrol_test/sdk_requirements.json',
        jsonEncode({
          'schema': 1,
          'capabilities': {},
          'unresolvedRegistrations': [],
          'tests': [
            {
              'file': 'patrol_test/core_test.dart',
              'descriptions': ['existing test'],
              'platforms': ['android'],
              'requires': [],
              'coverage': 'journey',
            }
          ],
        }));
    plan = planPatrolSdkSelection(repo.path, platform: 'android');
  }

  final root = Directory.systemTemp.createTempSync('android-sdk-identity-');
  Directory get repo => Directory(p.join(root.path, 'app'));
  late PatrolSelectionPlan plan;

  void write(String path, String contents) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  String identity({Map<String, String> env = const {}}) =>
      androidSdkBuildIdentity(plan, env: env, nativeGeneratorIdentity: 'generator');
}

void _optimizationCases(_Fixture Function() current) {
  for (final path in [
    'dependency/test/unused_test.dart',
    'dependency/docs/guide.md',
    'dependency/example/lib/main.dart',
    'app/test/unused_test.dart'
  ]) {
    test('unused test/docs/example $path does not invalidate compilation', () {
      final fixture = current();
      final before = fixture.identity();
      fixture.write(path, 'unrelated');
      expect(fixture.identity(), before);
    });
  }
  test('SS refresh, port setting, PWD and process state do not invalidate', () {
    final fixture = current();
    final before = fixture.identity();
    final env = {
      'OPERATIONAL_TOKEN': 'refreshed-fixture-token',
      'PWD': '/different/location',
      'SHLVL': '9',
      'MPLATROL_E2E_CREDENTIALS_PORT': '12345',
    };
    expect(fixture.identity(env: env), before);
  });
  for (final endpoint in [
    'http://localhost:12346/runtime?token=first-fixture',
    'http://localhost:12345/runtime?token=second-fixture',
  ]) {
    test('compiled credential endpoint $endpoint invalidates artifact identity', () {
      final fixture = current();
      final before = fixture.identity(env: const {
        'MPLATROL_E2E_CREDENTIALS_URL': 'http://localhost:12345/runtime?token=first-fixture',
      });
      expect(fixture.identity(env: {'MPLATROL_E2E_CREDENTIALS_URL': endpoint}), isNot(before));
    });
  }
  test('refreshed explicit runtime credentials source does not invalidate', () {
    final fixture = current();
    fixture.write('app/integration_test/custom-creds.json', '{"E2E_ENVIRONMENT":"QA","E2E_USERNAME":"first-fixture"}');
    final env = {'MPLATROL_E2E_DART_DEFINE_FILE': 'integration_test/custom-creds.json'};
    final before = fixture.identity(env: env);
    fixture.write(
        'app/integration_test/custom-creds.json', '{"E2E_ENVIRONMENT":"QA","E2E_USERNAME":"refreshed-fixture"}');
    expect(fixture.identity(env: env), before);
  });
  test('actual compiler control and exact generator signature invalidate', () {
    final fixture = current();
    final before = fixture.identity();
    expect(fixture.identity(env: {'JAVA_HOME': '/different/compiler'}), isNot(before));
    expect(androidSdkBuildIdentity(fixture.plan, env: const {}, nativeGeneratorIdentity: 'different-generator'),
        isNot(before));
  });
}

void _privateInputDiagnosticCases(_Fixture Function() current) {
  test('private digests preserve complete identity and never store credentials', () {
    final fixture = current();
    fixture.write('app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
        'class GeneratedPluginRegistrant { NativeSdkPlugin plugin; }');
    final inputs = <String, String>{};
    final identity = androidSdkBuildIdentity(fixture.plan,
        env: const {'MPLATROL_E2E_CREDENTIALS_URL': 'http://fixture/token=private-fixture'},
        nativeGeneratorIdentity: 'generator',
        inputDigests: inputs);
    expect(
        identity,
        fixture.identity(env: const {
          'MPLATROL_E2E_CREDENTIALS_URL': 'http://fixture/token=private-fixture',
        }));
    expect(inputs['@identity'], identity);
    expect(
        inputs,
        contains('app/android/app/src/main/java/io/flutter/plugins/'
            'GeneratedPluginRegistrant.java'));
    expect(jsonEncode(inputs), isNot(contains('private-fixture')));
    expect(jsonEncode(inputs), isNot(contains('NativeSdkPlugin')));
  });
  test('private digests identify real generated native source and package drift', () {
    final fixture = current();
    const registry = 'app/android/app/src/main/java/io/flutter/plugins/'
        'GeneratedPluginRegistrant.java';
    fixture.write(registry, 'class GeneratedPluginRegistrant { OriginalSdk sdk; }');
    final before = <String, String>{};
    final after = <String, String>{};
    androidSdkBuildIdentity(fixture.plan, env: const {}, nativeGeneratorIdentity: 'generator', inputDigests: before);
    fixture.write(registry, 'class GeneratedPluginRegistrant { DifferentSdk sdk; }');
    fixture.write('dependency/lib/source.dart', 'void differentDependency() {}');
    androidSdkBuildIdentity(fixture.plan, env: const {}, nativeGeneratorIdentity: 'generator', inputDigests: after);
    final changed = before.keys.where((name) => before[name] != after[name]).toSet();
    expect(changed, containsAll([registry, 'package:dependency/lib/source.dart', '@identity']));
  });
}

void _packageBindingCases(_Fixture Function() current) {
  test('prepared package, not pubspec alias, binds compiled Patrol arguments', () {
    final fixture = current();
    fixture.write(
        'app/pubspec.yaml',
        'name: app\n'
            'patrol:\n  android:\n    package_name: com.example.base\n');
    expect(androidSdkBuildArguments(fixture.plan, const {}),
        containsAllInOrder(['--package-name', 'com.example.tenant.staging']));
    final before = fixture.identity();
    fixture.write(
        'app/android/app/build.gradle', 'android { defaultConfig {\napplicationId "com.example.other.staging"\n} }');
    expect(fixture.identity(), isNot(before));
  });
  test('Kotlin prepared applicationId is supported without pubspec fallback', () {
    final fixture = current();
    File(p.join(fixture.repo.path, 'android/app/build.gradle')).deleteSync();
    fixture.write(
        'app/android/app/build.gradle.kts', 'android { defaultConfig {\napplicationId = "com.example.kotlin"\n} }');
    expect(preparedAndroidApplicationId(fixture.repo.path), 'com.example.kotlin');
  });
  for (final source in [
    'android { defaultConfig {} }',
    'android { defaultConfig {\napplicationId project.tenant\n} }',
    'android { defaultConfig {\napplicationId "com.example.\$tenant"\n} }',
    '''android { defaultConfig {
applicationId "com.example.app"
applicationIdSuffix ".debug"
} }''',
    '''android { defaultConfig {
applicationId "com.example.one"
applicationId "com.example.two"
} }''',
    '// applicationId "com.example.comment"\nandroid { defaultConfig {} }',
    'android { defaultConfig {\napplicationId "com.example.app"\n',
    'applicationId "com.example.outside"',
  ]) {
    test('unresolved or ambiguous Gradle package refuses compilation: $source', () {
      final fixture = current();
      fixture.write('app/android/app/build.gradle', source);
      expect(() => androidSdkBuildArguments(fixture.plan, const {}), throwsStateError);
      expect(fixture.identity, throwsStateError);
    });
  }
  test('missing prepared Gradle refuses rather than using pubspec', () {
    final fixture = current();
    File(p.join(fixture.repo.path, 'android/app/build.gradle')).deleteSync();
    expect(() => preparedAndroidApplicationId(fixture.repo.path), throwsStateError);
  });
  test('conflicting Groovy and Kotlin build files refuse', () {
    final fixture = current();
    fixture.write('app/android/app/build.gradle.kts', 'android {}');
    expect(() => preparedAndroidApplicationId(fixture.repo.path), throwsStateError);
  });
}

void _assetMetadataCases(_Fixture Function() current) {
  test('compiled arguments bind the prepared package as the Patrol app package', () {
    expect(
      androidSdkBuildArguments(current().plan, const {}),
      contains('--dart-define=PATROL_APP_PACKAGE_NAME=com.example.tenant.staging'),
    );
  });
  test('declared font asset is a compilation input', () {
    final fixture = current();
    fixture.write(
      'dependency/pubspec.yaml',
      'name: dependency\nflutter:\n  fonts:\n'
          '    - family: AppFont\n      fonts:\n        - asset: fonts/app.ttf\n',
    );
    fixture.write('dependency/fonts/app.ttf', 'font-v1');
    final before = fixture.identity();
    fixture.write('dependency/fonts/app.ttf', 'font-v2');
    expect(fixture.identity(), isNot(before));
  });
  for (final (name, pubspec, message) in [
    ('non-map pubspec', '- not\n- a map\n', 'Malformed build asset metadata'),
    ('non-map flutter section', 'name: dependency\nflutter: assets\n', 'Unknown Flutter build asset metadata'),
    ('absolute asset', 'name: dependency\nflutter:\n  assets:\n    - /etc/hosts\n', 'Unknown declared Android asset'),
    (
      'blank font asset',
      'name: dependency\nflutter:\n  fonts:\n    - family: AppFont\n      fonts:\n'
          '        - asset: " "\n',
      'Unknown declared Android asset',
    ),
  ]) {
    test('dependency with $name refuses identity', () {
      final fixture = current();
      fixture.write('dependency/pubspec.yaml', pubspec);
      expect(
        fixture.identity,
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains(message))),
      );
    });
  }
  test('top-level input link is refused rather than followed', () {
    final fixture = current();
    fixture.write('shared.lock', 'packages: {}');
    File(p.join(fixture.repo.path, 'pubspec.lock')).deleteSync();
    Link(p.join(fixture.repo.path, 'pubspec.lock')).createSync(p.join(fixture.root.path, 'shared.lock'));
    expect(
      fixture.identity,
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Unresolved link'))),
    );
  });
  test('non-map app pubspec refuses property preparation', () {
    final fixture = current();
    fixture.write('app/pubspec.yaml', '- not\n- a map\n');
    fixture.write('app/android/local.properties', 'flutter.buildMode=release');
    expect(
      () => prepareAndroidSdkBuildProperties(fixture.repo.path),
      throwsA(
        isA<StateError>().having((error) => error.message, 'message', contains('Malformed Android version metadata')),
      ),
    );
    expect(File(p.join(fixture.repo.path, 'android/local.properties')).readAsStringSync(), 'flutter.buildMode=release');
  });
}
