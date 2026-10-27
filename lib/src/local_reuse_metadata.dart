import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:mplatrol/src/patrol_safe_failure_report_patch.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:path/path.dart' as p;

const _schemaVersion = 1;
const _patrolNativeInput = '.mplatrol/patched_packages/patrol/$patrolIosTextInputSourcePath';

/// Inputs that identify one local integration-test build cache entry.
class LocalReuseRequest {
  const LocalReuseRequest({
    required this.variant,
    required this.deviceId,
    required this.tenant,
    required this.environment,
    required this.target,
    required this.targetRegex,
    required this.sdk,
    this.androidTestTimeoutMs,
    this.inputsRevision,
    this.coverage = false,
  });

  final ItVariant variant;
  final String deviceId;
  final String tenant;
  final String environment;
  final String? target;
  final String? targetRegex;
  final String? sdk;

  /// Resolved compiled JUnit timeout; null retains the generator default.
  final int? androidTestTimeoutMs;

  /// The revision of build inputs outside the checkout ([ltInputsRevisionEnv]); a different one needs a rebuild.
  final String? inputsRevision;

  /// Whether the build bakes in `COVERAGE_ENABLED`; a build without it cannot be reused for a coverage run.
  final bool coverage;

  bool get supportsAutomaticReuse =>
      (variant == ItVariant.iosLocal || variant == ItVariant.androidLocal) &&
      (variant == ItVariant.androidLocal || (targetRegex == null && sdk == null));

  String get deviceClass {
    switch (variant) {
      case ItVariant.androidLocal:
        return deviceId.startsWith('emulator-') ? 'android-emulator' : 'android-device';
      case ItVariant.iosLocal:
        return _looksLikeIosSimulatorId(deviceId) ? 'ios-simulator' : 'ios-device';
      case ItVariant.ltAndroid:
        return 'lt-android';
      case ItVariant.ltIos:
        return 'lt-ios';
    }
  }

  Map<String, Object?> identityJson() => {
        'schema': _schemaVersion,
        'variant': variant.id,
        'deviceClass': deviceClass,
        'tenant': tenant,
        'environment': environment,
        'target': target,
        'targetRegex': targetRegex,
        'sdk': sdk,
        if (coverage) 'coverage': true,
      };
}

/// Result of comparing the current local run inputs with the saved metadata.
class LocalReuseDecision {
  const LocalReuseDecision({
    required this.reuseLast,
    required this.reason,
    required this.cacheKey,
    required this.fingerprint,
  });

  final bool reuseLast;
  final String reason;
  final String cacheKey;
  final String fingerprint;
}

/// Reads and writes the local integration-test reuse metadata file.
class LocalReuseMetadataStore {
  const LocalReuseMetadataStore();

  LocalReuseDecision evaluate({
    required String repo,
    required LocalReuseRequest request,
    bool explicit = false,
  }) {
    final fingerprint = _fingerprint(repo, request);
    final cacheKey = _cacheKey(request);
    if (!request.supportsAutomaticReuse && !explicit) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: '${request.variant.id} does not support automatic reuse',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    if (request.variant == ItVariant.androidLocal && !_hasAndroidReuseArtifacts(repo)) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'cached Android app/test APKs are missing',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    final patrolRoot = Directory(p.join(repo, '.mplatrol', 'patched_packages', 'patrol'));
    if ((request.variant == ItVariant.iosLocal || request.variant == ItVariant.ltIos) &&
        patrolRoot.existsSync() &&
        !hasPatrolIosTextInputPatch(patrolRoot)) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'generated Patrol native input patch is missing or stale; rerun prepare',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    if (patrolRoot.existsSync() && !hasPatrolRuntimeSkipPatch(patrolRoot)) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'generated Patrol runtime skip patch is missing or stale; rerun prepare',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    if (patrolRoot.existsSync() && !hasPatrolSafeFailureReportPatch(patrolRoot)) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'generated Patrol safe failure report patch is missing or stale; rerun prepare',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    final storedEntry = _storedEntry(repo, cacheKey);
    final value = storedEntry?['fingerprint'];
    final stored = value is String ? value : null;
    if (stored == null) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: explicit ? 'no previous matching local reuse metadata' : 'no previous local reuse metadata',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    if (storedEntry?['nativeGenerator'] != _nativeGeneratorIdentity(request)) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'native Patrol generator identity is missing or changed; rebuild',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    final storedRevision = storedEntry?['inputsRevision'];
    if (storedRevision != request.inputsRevision) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'build inputs revision changed (${_shortOrNone(storedRevision)} -> '
            '${_shortOrNone(request.inputsRevision)}); rebuild',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    if (stored != fingerprint) {
      return LocalReuseDecision(
        reuseLast: false,
        reason: 'local reuse fingerprint changed',
        cacheKey: cacheKey,
        fingerprint: fingerprint,
      );
    }
    return LocalReuseDecision(
      reuseLast: true,
      reason: 'local reuse fingerprint matched',
      cacheKey: cacheKey,
      fingerprint: fingerprint,
    );
  }

  /// Invalidates saved owners before a fresh build can replace shared outputs.
  ///
  /// Other platforms remain reusable even if this build fails or is interrupted.
  void invalidateForBuild({
    required String repo,
    required ItVariant variant,
  }) {
    final file = _metadataFile(repo);
    if (!file.existsSync()) {
      return;
    }
    final store = _readStore(file);
    final entries = _entries(store);
    final artifactVariants = switch (variant) {
      ItVariant.androidLocal || ItVariant.ltAndroid => [ItVariant.androidLocal.id, ItVariant.ltAndroid.id],
      ItVariant.iosLocal || ItVariant.ltIos => [ItVariant.iosLocal.id, ItVariant.ltIos.id],
    };
    entries.removeWhere((_, entry) => entry is Map && artifactVariants.contains(entry['variant']));
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(store)}\n',
    );
  }

  void recordSuccessfulRun({
    required String repo,
    required LocalReuseRequest request,
  }) {
    if (request.variant == ItVariant.androidLocal && !_hasAndroidReuseArtifacts(repo)) {
      return;
    }
    final file = _metadataFile(repo);
    final store = _readStore(file);
    final entries = _entries(store);
    final cacheKey = _cacheKey(request);
    final artifactVariants = switch (request.variant) {
      ItVariant.androidLocal || ItVariant.ltAndroid => [ItVariant.androidLocal.id, ItVariant.ltAndroid.id],
      ItVariant.iosLocal || ItVariant.ltIos => [ItVariant.iosLocal.id, ItVariant.ltIos.id],
    };
    // Each platform's build outputs are shared across run identities.
    entries.removeWhere((_, entry) => entry is Map && artifactVariants.contains(entry['variant']));
    entries[cacheKey] = {
      'fingerprint': _fingerprint(repo, request),
      'nativeGenerator': _nativeGeneratorIdentity(request),
      'inputsRevision': request.inputsRevision,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      ...request.identityJson(),
    };
    store['schema'] = _schemaVersion;
    store['entries'] = entries;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(store)}\n',
    );
  }

  File _metadataFile(String repo) => File(
        p.join(repo, '.mplatrol', 'integration_test', 'local_reuse_metadata.json'),
      );

  Map<String, dynamic>? _storedEntry(String repo, String cacheKey) {
    final store = _readStore(_metadataFile(repo));
    final entry = _entries(store)[cacheKey];
    if (entry is! Map<String, dynamic>) {
      return null;
    }
    return entry;
  }

  Map<String, dynamic> _readStore(File file) {
    if (!file.existsSync()) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _entries(Map<String, dynamic> store) {
    final entries = store['entries'];
    if (entries is Map<String, dynamic>) {
      return entries;
    }
    final next = <String, dynamic>{};
    store['entries'] = next;
    return next;
  }
}

String _shortOrNone(Object? sha) =>
    sha is String && sha.isNotEmpty ? (sha.length > 12 ? sha.substring(0, 12) : sha) : 'none recorded';

String _cacheKey(LocalReuseRequest request) {
  final builder = FingerprintBuilder()..addString('cache-key');
  for (final entry in request.identityJson().entries) {
    builder
      ..addString(entry.key)
      ..addString('${entry.value ?? ''}');
  }
  return builder.finish();
}

String _fingerprint(String repo, LocalReuseRequest request) {
  final builder = FingerprintBuilder()
    ..addString('schema:$_schemaVersion')
    ..addString(_nativeGeneratorIdentity(request))
    ..addString(jsonEncode(request.identityJson()));
  for (final input in _inputFiles(repo, request)) {
    builder
      ..addString(p.relative(input.path, from: repo).replaceAll('\\', '/'))
      ..addBytes(input.readAsBytesSync());
  }
  return builder.finish();
}

String _nativeGeneratorIdentity(LocalReuseRequest request) =>
    request.variant == ItVariant.androidLocal || request.variant == ItVariant.ltAndroid
        ? androidPatrolGeneratorIdentity(env: {
            e2eTestTimeoutMsEnv: '${request.androidTestTimeoutMs ?? ''}',
          })
        : iosPatrolGeneratorIdentity();

List<File> _inputFiles(String repo, LocalReuseRequest request) {
  final files = <File>[];
  for (final path in _inputFilePaths(repo, request)) {
    final file = File(path);
    if (file.existsSync() && _includeFile(repo, file, request)) {
      files.add(file);
    }
  }
  for (final path in _inputDirectoryPaths(repo, request)) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      continue;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File && _includeFile(repo, entity, request)) {
        files.add(entity);
      }
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

List<String> _inputFilePaths(String repo, LocalReuseRequest request) => [
      'analysis_options.yaml',
      'build.yaml',
      'Makefile',
      'melos.yaml',
      'mplatrol.yaml',
      'pubspec.lock',
      'pubspec.yaml',
      'pubspec_overrides.yaml',
      ...patrolRuntimeSkipMobileInputs,
      if (request.variant == ItVariant.iosLocal || request.variant == ItVariant.ltIos) _patrolNativeInput,
      p.join('.fvm', 'fvm_config.json'),
    ].map((path) => p.join(repo, path)).toList(growable: false);

List<String> _inputDirectoryPaths(String repo, LocalReuseRequest request) => [
      'integration_test',
      'patrol_test',
      'lib',
      if (request.variant == ItVariant.androidLocal || request.variant == ItVariant.ltAndroid) 'android',
      if (request.variant == ItVariant.iosLocal || request.variant == ItVariant.ltIos) 'ios',
      'assets',
      if (request.tenant.trim().isNotEmpty) p.join('tenants', request.tenant),
    ].map((path) => p.join(repo, path)).toList(growable: false);

bool _includeFile(String repo, File file, LocalReuseRequest request) {
  final relative = p.relative(file.path, from: repo).replaceAll('\\', '/');
  if (relative == _patrolNativeInput || patrolRuntimeSkipMobileInputs.contains(relative)) {
    return true;
  }
  if (relative == defaultE2eDartDefineFile ||
      relative == runtimeE2eAssetConfigFile ||
      relative == 'patrol_test/test_bundle.dart' ||
      relative == 'integration_test/test_bundle.dart' ||
      relative == 'patrol_test/$iosPatrolTestBundleFile' ||
      relative == 'integration_test/$iosPatrolTestBundleFile' ||
      _isAndroidWrapperForIos(relative, request) ||
      // Flutter rewrites these from the build invocation after onBuildStarted.
      // Their source inputs remain fingerprinted (request, Dart, pubspec, and
      // native project/configuration files), not these derived copies.
      relative == 'ios/Flutter/Generated.xcconfig' ||
      relative == 'ios/Flutter/flutter_export_environment.sh') {
    return false;
  }
  final parts = p.split(relative);
  return !parts.any(
    (part) =>
        part == '.dart_tool' ||
        part == '.git' ||
        part == '.mplatrol' ||
        part == 'build' ||
        part == 'DerivedData' ||
        part == 'Pods',
  );
}

/// iOS compiles its own [iosPatrolTestBundleFile], never Android's filtered
/// wrapper, which a concurrent `mplatrol run all` Android arm rewrites or
/// deletes during the iOS build.
bool _isAndroidWrapperForIos(String relative, LocalReuseRequest request) =>
    (request.variant == ItVariant.iosLocal || request.variant == ItVariant.ltIos) &&
    (relative == 'patrol_test/mplatrol_filtered_test.dart' ||
        relative == 'integration_test/mplatrol_filtered_test.dart');

bool _hasAndroidReuseArtifacts(String repo) {
  const artifacts = [
    'build/app/outputs/apk/debug/app-debug.apk',
    'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk',
  ];
  return artifacts.every((path) => File(p.join(repo, path)).existsSync());
}

bool _looksLikeIosSimulatorId(String deviceId) {
  if (deviceId.startsWith('SIM-')) {
    return true;
  }
  return RegExp(
    '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    '[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\$',
  ).hasMatch(deviceId);
}
