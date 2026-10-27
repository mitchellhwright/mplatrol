import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/checkout_independent_inputs.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_android_native_views_patch.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Identifies Android compilation inputs, excluding operational credentials and transport.
///
/// Args:
///   selection: Plan consumed by the actual Dart and Android native generators.
///   env: Runtime/build controls; compiled arguments and compiler paths are fingerprinted.
///   nativeGeneratorIdentity: Exact compiled native generator identity.
///   inputDigests: Optional private per-input hashes; never stores input contents.
///
/// Returns an input-consistency fingerprint, not a cryptographic signature.
String androidSdkBuildIdentity(
  PatrolSelectionPlan selection, {
  required Map<String, String> env,
  required String nativeGeneratorIdentity,
  Map<String, String>? inputDigests,
}) {
  selection.validate(selection.repo, target: selection.target, targetRegex: selection.targetRegex, sdk: selection.sdk);
  final compiledArguments = jsonEncode(androidSdkBuildArguments(selection, env));
  final controls = {
    'selection': selection.selectionDigest,
    'native-generator': nativeGeneratorIdentity,
    'native-snapshot-recipe': patrolAndroidNativeViewsPatchIdentity(),
    'abi-property': androidSdkAbiBuildProperty,
    'compiled-arguments': compiledArguments,
    for (final key in _compilerEnvironment)
      if (env.containsKey(key)) 'compiler:$key': env[key]!,
  };
  for (final entry in controls.entries) {
    inputDigests?['build/${entry.key}'] = (FingerprintBuilder()..addString(entry.value)).finish();
  }
  final builder = FingerprintBuilder()
    ..addString('lt-android-sdk-build:5:prepared-package-binding:node-snapshot')
    ..addString(patrolAndroidNativeViewsPatchIdentity())
    ..addString(selection.selectionDigest)
    ..addString(nativeGeneratorIdentity)
    ..addString(androidSdkAbiBuildProperty)
    ..addString(compiledArguments)
    ..addString(jsonEncode({
      for (final key in _compilerEnvironment)
        if (env.containsKey(key)) key: env[key]
    }));
  _addInputs(
      builder,
      selection.repo,
      'app',
      [
        ..._projectFiles,
        'lib',
        'android',
        patrolTestDirectory(selection.repo),
        'integration_test',
        'assets',
        'tenants',
        ..._declaredAssets(selection.repo),
      ],
      inputDigests: inputDigests,
      excluded: {
        ..._derivedInputs,
        if (e2eCredentialsFilePath(selection.repo, env) != null)
          p.relative(e2eCredentialsFilePath(selection.repo, env)!, from: selection.repo).replaceAll('\\', '/'),
      });
  final config = File(p.join(selection.repo, '.dart_tool/package_config.json'));
  final data = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final configBytes =
      checkoutIndependentBytes(selection.repo, '.dart_tool/package_config.json', config.readAsBytesSync());
  builder.addBytes(configBytes);
  inputDigests?['resolution/package_config.json'] = (FingerprintBuilder()..addBytes(configBytes)).finish();
  _addPackages(builder, config, data['packages'] as List, inputDigests: inputDigests);
  final identity = builder.finish();
  inputDigests?['@identity'] = identity;
  return identity;
}

void _addPackages(FingerprintBuilder builder, File config, List<dynamic> packages,
    {Map<String, String>? inputDigests}) {
  final entries = packages.cast<Map<String, dynamic>>().toList()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  for (final entry in entries) {
    final uri = entry['rootUri'] as String;
    final root = config.parent.uri.resolve(uri.endsWith('/') ? uri : '$uri/');
    if (root.scheme != 'file' || !Directory(root.toFilePath()).existsSync()) {
      throw StateError('Resolved Android package root is missing or not local; prepare first.');
    }
    final path = root.toFilePath();
    _addInputs(
        builder,
        path,
        'package:${entry['name']}',
        [
          entry['packageUri'] as String,
          'android',
          'java/src/main',
          'hook',
          'hooks',
          'src',
          'native',
          'pubspec.yaml',
          'pubspec.lock',
          'build.yaml',
          'CMakeLists.txt',
          ..._declaredAssets(path),
        ],
        inputDigests: inputDigests);
  }
}

List<String> _declaredAssets(String root) {
  final file = File(p.join(root, 'pubspec.yaml'));
  if (!file.existsSync()) {
    return const [];
  }
  final yaml = loadYaml(file.readAsStringSync());
  if (yaml is! YamlMap) {
    throw StateError('Malformed build asset metadata; prepare Android dependencies first.');
  }
  final flutter = yaml['flutter'];
  if (flutter == null) {
    return const [];
  }
  if (flutter is! YamlMap) {
    throw StateError('Unknown Flutter build asset metadata; do not reuse Android artifacts.');
  }
  final result = <String>[];
  for (final asset in flutter['assets'] as List? ?? const []) {
    result.add(_assetPath(asset is Map ? asset['path'] : asset));
  }
  return [...result, ..._fontAssets(flutter['fonts'])];
}

List<String> _fontAssets(Object? value) {
  final result = <String>[];
  for (final font in value as List? ?? const []) {
    for (final asset in (font as Map)['fonts'] as List) {
      result.add(_assetPath((asset as Map)['asset']));
    }
  }
  return result;
}

String _assetPath(Object? value) {
  if (value is! String || value.trim().isEmpty || p.isAbsolute(value)) {
    throw StateError('Unknown declared Android asset path; prepare before building.');
  }
  return value;
}

void _addInputs(FingerprintBuilder builder, String root, String label, List<String> inputs,
    {Set<String> excluded = _derivedInputs, Map<String, String>? inputDigests}) {
  final files = <String, File>{};
  for (final input in inputs.toSet()) {
    final path = p.normalize(p.join(root, input));
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link) {
      throw StateError('Unresolved link in Android compilation inputs; resolve before building.');
    }
    final FileSystemEntity initial;
    if (FileSystemEntity.isDirectorySync(path)) {
      initial = Directory(path);
    } else {
      initial = File(path);
    }
    final pending = <FileSystemEntity>[initial];
    while (pending.isNotEmpty) {
      _collectInput(root, pending.removeLast(), pending, files, excluded: excluded);
    }
  }
  final names = files.keys.toList()..sort();
  for (final name in names) {
    final bytes = checkoutIndependentBytes(root, name, files[name]!.readAsBytesSync());
    builder
      ..addString('$label/$name')
      ..addBytes(bytes);
    inputDigests?['$label/$name'] = (FingerprintBuilder()..addBytes(bytes)).finish();
  }
}

void _collectInput(String root, FileSystemEntity entry, List<FileSystemEntity> pending, Map<String, File> files,
    {required Set<String> excluded}) {
  final relative = p.relative(entry.path, from: root).replaceAll('\\', '/');
  if (excluded.contains(relative) || _outputDirectories.contains(relative) || _androidBuildOutput(root, entry.path)) {
    return;
  }
  if (entry is Link) {
    throw StateError('Unresolved link in Android compilation inputs; resolve before building.');
  }
  if (entry is Directory) {
    pending.addAll(entry.listSync(followLinks: false));
  } else if (entry is File && entry.existsSync()) {
    files[relative] = entry;
  }
}

const _compilerEnvironment = ['JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'FLUTTER_ROOT'];
const _projectFiles = [
  'pubspec.yaml',
  'pubspec.lock',
  'pubspec_overrides.yaml',
  'build.yaml',
  'Makefile',
  'melos.yaml',
  'mplatrol.yaml',
  '.fvmrc',
  '.fvm/fvm_config.json',
  '.dart_tool/version',
];
const _derivedInputs = {
  'android/app/src/main/assets/$patrolSdkArtifactAsset',
  'android/app/src/androidTest/assets/$patrolSdkArtifactAsset',
  defaultE2eDartDefineFile,
  runtimeE2eAssetConfigFile,
  'patrol_test/test_bundle.dart',
  'integration_test/test_bundle.dart',
  'patrol_test/$iosPatrolTestBundleFile',
  'integration_test/$iosPatrolTestBundleFile',
};
const _outputDirectories = {'.git', '.dart_tool', '.gradle', 'build'};

const androidSdkAbiBuildProperty = 'ORG_GRADLE_PROJECT_disable-abi-filtering=true';
const _androidSdkBuildMode = 'debug';

/// Stages Flutter's source-derived build properties before the input stamp.
///
/// Args:
///   repo: Prepared APP root; other local properties remain compilation inputs.
void prepareAndroidSdkBuildProperties(String repo) {
  final file = File(p.join(repo, 'android/local.properties'));
  if (FileSystemEntity.isLinkSync(file.path) || FileSystemEntity.isLinkSync(file.parent.path)) {
    throw StateError('Linked android/local.properties cannot be prepared safely; '
        'resolve the compilation input before building.');
  }
  if (!file.existsSync()) {
    return;
  }
  final contents = file.readAsStringSync();
  final properties = _androidLocalProperties(contents);
  final expected = {
    'flutter.buildMode': _androidSdkBuildMode,
    ..._androidVersionProperties(repo),
  };
  var changed = false;
  for (final entry in expected.entries) {
    if (properties[entry.key] == entry.value) {
      continue;
    }
    if (entry.value == null) {
      properties.remove(entry.key);
    } else {
      properties[entry.key] = entry.value!;
    }
    changed = true;
  }
  if (changed) {
    file.writeAsStringSync(properties.entries.map((e) => '${e.key}=${e.value}').join('\n'));
  }
}

Map<String, String> _androidLocalProperties(String contents) {
  final properties = <String, String>{};
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final separator = line.indexOf('=');
    if (separator < 1) {
      throw StateError('Malformed android/local.properties; use unambiguous key=value entries.');
    }
    final key = line.substring(0, separator);
    if (!RegExp(r'^[^\s=\\]+$').hasMatch(key) || properties.containsKey(key)) {
      throw StateError('Ambiguous android/local.properties; resolve duplicate or escaped keys.');
    }
    properties[key] = line.substring(separator + 1);
  }
  return properties;
}

Map<String, String?> _androidVersionProperties(String repo) {
  try {
    final manifest = loadYaml(File(p.join(repo, 'pubspec.yaml')).readAsStringSync());
    if (manifest is! YamlMap) {
      throw StateError('Malformed Android version metadata; prepare a valid pubspec.yaml.');
    }
    final value = manifest['version'];
    if (value == null) {
      return {'flutter.versionName': null, 'flutter.versionCode': null};
    }
    if (value is! String) {
      throw StateError('Malformed Android version; use a pubspec semantic version string.');
    }
    final parts = Version.parse(value).toString().split('+');
    return {
      'flutter.versionName': parts.first,
      'flutter.versionCode': _androidVersionCode(parts.length > 1 ? parts[1] : null),
    };
  } on YamlException {
    throw StateError('Malformed Android version metadata; prepare a valid pubspec.yaml.');
  } on FormatException {
    throw StateError('Malformed Android version; use a pubspec semantic version string.');
  }
}

String? _androidVersionCode(String? value) {
  if (value == null) {
    return null;
  }
  final number = int.tryParse(value.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
  return (number < 1 ? 1 : number).toString();
}

/// Returns exact Patrol arguments used by the selected LT Android producer.
///
/// Args:
///   selection: Shared plan; every selected file is in the generated Dart wrapper.
///   env: Controls used to resolve actual runtime defines, including credential transport.
List<String> androidSdkBuildArguments(PatrolSelectionPlan selection, Map<String, String> env) {
  final packageName = preparedAndroidApplicationId(selection.repo);
  return [
    'build',
    'android',
    '--$_androidSdkBuildMode',
    '--package-name',
    packageName,
    '--no-label',
    '--target',
    p
        .relative(p.join(patrolTestDirectoryPath(selection.repo), 'mplatrol_filtered_test.dart'), from: selection.repo)
        .replaceAll('\\', '/'),
    '--dart-define=LT_PROXY=true',
    '--dart-define=E2E_TEST_BRIDGE=true',
    '--dart-define=PATROL_APP_PACKAGE_NAME=$packageName',
    ...e2eDartDefineArgs(selection.repo, env),
  ];
}

bool _androidBuildOutput(String root, String path) {
  final relative = p.relative(path, from: root).replaceAll('\\', '/');
  if (const {'android/build', 'android/app/build', 'android/.gradle'}.contains(relative)) {
    return true;
  }
  return relative.startsWith('android/') &&
      const {'build', '.cxx'}.contains(p.basename(path)) &&
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory &&
      (File(p.join(p.dirname(path), 'build.gradle')).existsSync() ||
          File(p.join(p.dirname(path), 'build.gradle.kts')).existsSync());
}

/// Resolves the literal application ID in the prepared Android Gradle configuration.
///
/// Args:
///   repo: Prepared application root, not a pubspec package-name fallback.
///   fileSystem: Optional filesystem boundary for local runner tests.
///
/// Throws StateError when the prepared build cannot establish one exact application ID.
String preparedAndroidApplicationId(String repo, {FileSystem? fileSystem}) {
  final paths = ['build.gradle', 'build.gradle.kts']
      .map((name) => p.join(repo, 'android/app', name))
      .where((path) => fileSystem?.fileExistsSync(path) ?? File(path).existsSync())
      .toList();
  if (paths.length != 1) {
    throw StateError('Android package binding requires one prepared app Gradle file; prepare first.');
  }
  final source = fileSystem?.readAsStringSync(paths.single) ?? File(paths.single).readAsStringSync();
  final text = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'), '');
  if (RegExp(r'\b(?:applicationIdSuffix|productFlavors)\b').hasMatch(text) ||
      RegExp(r'\bapplicationId\b').allMatches(text).length != 1) {
    throw StateError('Android package binding is ambiguous; prepare one literal applicationId.');
  }
  final config = _preparedAndroidDefaultConfig(text);
  final matches = RegExp(
    r'''^\s*applicationId\s*(?:=\s*)?(['"])'''
    r'([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+)\1\s*;?\s*$',
    multiLine: true,
  ).allMatches(config).toList();
  if (matches.length != 1) {
    throw StateError('Android package binding is unresolved; prepare a literal applicationId.');
  }
  return matches.single.group(2)!;
}

String _preparedAndroidDefaultConfig(String source) {
  final starts = RegExp(r'\bdefaultConfig\s*\{').allMatches(source).toList();
  if (starts.length != 1) {
    throw StateError('Android package binding requires one prepared defaultConfig block.');
  }
  var depth = 1;
  for (var i = starts.single.end; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(starts.single.end, i);
      }
    }
  }
  throw StateError('Android package binding has a malformed defaultConfig block.');
}
