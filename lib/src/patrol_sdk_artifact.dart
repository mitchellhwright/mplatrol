import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;

const patrolSdkArtifactAsset = 'mplatrol-sdk-selection.json';
const _assetEntry = 'assets/$patrolSdkArtifactAsset';

/// Provenance for one immutable uploaded app/test pair, not a native verdict.
class PatrolSdkArtifactReceipt {
  PatrolSdkArtifactReceipt._(this._data);

  /// Decodes a receipt and rejects unknown, incomplete or damaged provenance.
  factory PatrolSdkArtifactReceipt.fromJson(Object? value) {
    final data = _object(value, 'SDK artifact receipt');
    _validateReceiptShape(data);
    final payload = Map<String, dynamic>.from(data)..remove('receiptDigest');
    if (data['receiptDigest'] != _digest(payload)) {
      throw StateError('SDK artifact receipt changed; rebuild and upload before reuse.');
    }
    return PatrolSdkArtifactReceipt._(jsonDecode(jsonEncode(data)) as Map<String, dynamic>);
  }

  final Map<String, dynamic> _data;

  /// Returns a detached copy suitable for the uploaded-ID cache.
  Map<String, dynamic> toJson() => jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;

  /// Checks selection, build/generator identity and both uploaded artifact IDs.
  void validate(
      {required PatrolSelectionPlan selection,
      required String buildIdentity,
      required String nativeGeneratorIdentity,
      required String appId,
      required String testId}) {
    final expected = _compiledManifest(selection, buildIdentity, nativeGeneratorIdentity);
    if (_digest(_data['manifest']) != _digest(expected)) {
      throw StateError('Cached SDK selection/build identity differs; rebuild and upload.');
    }
    final app = _object(_data['app'], 'uploaded SDK app');
    final test = _object(_data['test'], 'uploaded SDK test');
    if (app['id'] != appId || test['id'] != testId) {
      throw StateError('SDK receipt belongs to another uploaded app/test pair; rebuild and upload.');
    }
  }
}

/// Writes Android build assets before compilation; no runner is activated here.
///
/// Args:
///   selection: Validated prepared-source plan consumed by both generators.
///   buildIdentity: Upstream identity of all build/variant/environment inputs.
///   nativeGeneratorIdentity: Identity of the exact native generator implementation.
void prepareAndroidPatrolSdkAssets(
  PatrolSelectionPlan selection, {
  required String buildIdentity,
  required String nativeGeneratorIdentity,
}) {
  final manifest = _compiledManifest(selection, buildIdentity, nativeGeneratorIdentity);
  for (final sourceSet in ['main', 'androidTest']) {
    final file = File(p.join(selection.repo, 'android', 'app', 'src', sourceSet, 'assets', patrolSdkArtifactAsset));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(manifest));
  }
}

/// Uploads only compiled APKs carrying this plan, then binds returned IDs.
///
/// Args:
///   selection: Prepared plan used by the completed build.
///   buildIdentity: Upstream complete build identity, not just SDK capabilities.
///   nativeGeneratorIdentity: Native generator identity used during compilation.
///   appApk: Compiled app APK path.
///   testApk: Compiled instrumentation APK path.
///   upload: Existing upload boundary, invoked once after artifact validation.
///
/// Returns a receipt only if source inputs and both binary files remain unchanged.
Future<PatrolSdkArtifactReceipt> uploadPatrolSdkArtifacts({
  required PatrolSelectionPlan selection,
  required String buildIdentity,
  required String nativeGeneratorIdentity,
  required String appApk,
  required String testApk,
  required Future<({String appId, String testId})> Function() upload,
}) async {
  final manifest = _compiledManifest(selection, buildIdentity, nativeGeneratorIdentity);
  final app = _readCompiledArtifact(appApk, manifest);
  final test = _readCompiledArtifact(testApk, manifest);
  final ids = await upload();
  _text(ids.appId, 'uploaded app ID');
  _text(ids.testId, 'uploaded test ID');
  selection.validate(selection.repo, target: selection.target, targetRegex: selection.targetRegex, sdk: selection.sdk);
  _requireUnchangedArtifact(appApk, app);
  _requireUnchangedArtifact(testApk, test);
  final data = <String, dynamic>{
    'schema': 1,
    'manifest': manifest,
    'app': {...app, 'id': ids.appId},
    'test': {...test, 'id': ids.testId},
  };
  data['receiptDigest'] = _digest(data);
  return PatrolSdkArtifactReceipt.fromJson(data);
}

Map<String, Object?> _compiledManifest(
    PatrolSelectionPlan selection, String buildIdentity, String nativeGeneratorIdentity) {
  selection.validate(selection.repo, target: selection.target, targetRegex: selection.targetRegex, sdk: selection.sdk);
  _text(buildIdentity, 'complete SDK build identity');
  _text(nativeGeneratorIdentity, 'SDK native generator identity');
  if (selection.platform != 'android') {
    throw StateError('SDK artifact producer is not implemented for ${selection.platform}; '
        'do not activate selection or reuse for this platform.');
  }
  if (selection.selectedCount == 0) {
    throw StateError('SDK selection contains no eligible native tests; do not upload an empty suite.');
  }
  return {
    'schema': 1,
    'platform': selection.platform,
    'buildIdentity': buildIdentity,
    'nativeGenerator': nativeGeneratorIdentity,
    'selectionDigest': selection.selectionDigest,
    'selection': selection.toJson(),
  };
}

Map<String, Object?> _readCompiledArtifact(String path, Map<String, Object?> expected) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Compiled SDK APK is missing; build before uploading.');
  }
  final bytes = file.readAsBytesSync();
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeBytes(bytes, verify: true);
    final headers = decoder.directory.fileHeaders.where((header) => header.filename == _assetEntry).toList();
    if (headers.length != 1 || headers.single.file?.filename != _assetEntry) {
      throw StateError('Compiled APK has missing or duplicate SDK selection entries; rebuild.');
    }
    final entries = archive.where((entry) => entry.name == _assetEntry).toList();
    // Unreachable with package:archive 4.x: the header check above admits one
    // slash-free entry, which the decoder always maps to exactly one file.
    // Kept to fail closed if a decoder upgrade changes that mapping.
    // coverage:ignore-start
    if (entries.length != 1 || !entries.single.isFile) {
      throw StateError('Compiled APK lacks one SDK selection asset; rebuild with the selected plan.');
    }
    // coverage:ignore-end
    final manifest = jsonDecode(utf8.decode(entries.single.content));
    if (_digest(manifest) != _digest(expected)) {
      throw StateError('Compiled APK carries another SDK/build selection; rebuild before uploading.');
    }
  } on FormatException {
    throw StateError('Compiled SDK APK metadata is malformed; rebuild before uploading.');
  }
  return {'digest': (FingerprintBuilder()..addBytes(bytes)).finish(), 'size': bytes.length};
}

void _requireUnchangedArtifact(String path, Map<String, Object?> expected) {
  final file = File(path);
  if (!file.existsSync() || (FingerprintBuilder()..addBytes(file.readAsBytesSync())).finish() != expected['digest']) {
    throw StateError('SDK binary changed during upload; receipt not recorded. Rebuild before retrying.');
  }
}

void _validateReceiptShape(Map<String, dynamic> data) {
  if (data['schema'] != 1) {
    throw StateError('Unknown SDK artifact receipt version; rebuild and upload.');
  }
  final manifest = _object(data['manifest'], 'compiled SDK manifest');
  if (manifest['schema'] != 1 || manifest['platform'] != 'android') {
    throw StateError('Unsupported compiled SDK manifest; do not reuse this artifact.');
  }
  _text(manifest['buildIdentity'], 'SDK build identity');
  _text(manifest['nativeGenerator'], 'SDK generator identity');
  _digestText(manifest['selectionDigest']);
  _object(manifest['selection'], 'SDK selection report');
  _validateArtifactIdentity(data['app']);
  _validateArtifactIdentity(data['test']);
  _digestText(data['receiptDigest']);
}

void _validateArtifactIdentity(Object? value) {
  final artifact = _object(value, 'SDK binary identity');
  _text(artifact['id'], 'SDK upload ID');
  _digestText(artifact['digest']);
  final size = artifact['size'];
  if (size is! int || size <= 0) {
    throw StateError('Unknown SDK binary size; rebuild and upload.');
  }
}

String _digest(Object? value) => (FingerprintBuilder()..addString(jsonEncode(_canonical(value)))).finish();

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) {
    return value.map(_canonical).toList();
  }
  return value;
}

Map<String, dynamic> _object(Object? value, String context) {
  if (value is! Map<String, dynamic>) {
    throw StateError('Missing or invalid $context; rebuild SDK artifacts before reuse.');
  }
  return value;
}

String _text(Object? value, String context) {
  if (value is! String || value.trim().isEmpty) {
    throw StateError('Missing $context; do not activate SDK artifact reuse.');
  }
  return value;
}

void _digestText(Object? value) {
  if (value is! String ||
      value.length < 16 ||
      value.length > 17 ||
      !RegExp(r'^(?:[0-9a-f]{16}|0*-[0-9a-f]{1,16})$').hasMatch(value)) {
    throw StateError('Unknown SDK artifact digest; rebuild and upload.');
  }
}
