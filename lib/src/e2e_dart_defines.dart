import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/upgrade/upgrade_leg.dart';
import 'package:path/path.dart' as p;

/// Env var: the backend environment a run tests against; the app receives it as the `E2E_ENVIRONMENT` define.
const e2eEnvironmentEnv = 'MPLATROL_E2E_ENVIRONMENT';

/// Env var: the tenant a run tests; the app receives it as the `E2E_TENANT` define.
const e2eTenantEnv = 'MPLATROL_E2E_TENANT';

const e2eDartDefineFileEnv = 'MPLATROL_E2E_DART_DEFINE_FILE';

const e2eDartDefineFileFallbackEnv = 'E2E_DART_DEFINE_FROM_FILE';

const e2eCredentialsUrlEnv = 'MPLATROL_E2E_CREDENTIALS_URL';

const e2eCredentialsUrlFallbackEnv = 'E2E_CREDENTIALS_URL';

/// Set by `AndroidDeviceEgress` while a USB phone's traffic is routed through
/// this Mac; the build then enables the app's Developer Tools proxy so the
/// app's own API calls use the phone's system proxy too.
const e2eDeviceProxyEnv = 'MPLATROL_E2E_DEVICE_PROXY';

const defaultE2eDartDefineFile = 'integration_test/e2e_credentials.local.json';

const runtimeE2eAssetConfigFile = 'assets/mplatrol/e2e_runtime_config.json';

/// Returns exact `--dart-define` args for E2E runtime wiring.
///
/// Patrol's iOS and HyperExecute build paths do not reliably propagate
/// `--dart-define-from-file`, so runners use explicit non-secret defines.
/// Direct args intentionally do not write the shared runtime define file: the
/// four E2E variants can build in the same checkout, and a shared file would let
/// one lane publish another lane's runtime credential URL.
List<String> e2eDartDefineArgs(String repo, Map<String, String> env) {
  final defines = e2eRuntimeDartDefines(repo, env);
  if (defines.isEmpty) {
    return const [];
  }
  return defines.entries.map((entry) => '--dart-define=${entry.key}=${entry.value}').toList(growable: false);
}

/// Returns shell-safe `--dart-define` flags for E2E runtime wiring.
String e2eDartDefineFlags(String repo, Map<String, String> env) {
  final args = e2eDartDefineArgs(repo, env);
  if (args.isEmpty) {
    return '';
  }
  return args.map((arg) => ' ${_shellQuote(arg)}').join();
}

Map<String, String> e2eRuntimeDartDefines(String repo, Map<String, String> env) {
  final defines = <String, String>{};
  final credentials = readE2eCredentialsFile(repo, env);
  final environment =
      (credentials?['E2E_ENVIRONMENT'] ?? env[e2eEnvironmentEnv] ?? env['E2E_ENVIRONMENT'] ?? '').toString().trim();
  if (environment.isNotEmpty) {
    defines['E2E_ENVIRONMENT'] = environment;
  }
  final tenant = (env[e2eTenantEnv] ?? '').trim();
  if (tenant.isNotEmpty) {
    defines['E2E_TENANT'] = tenant;
  }
  final credentialsUrl = (env[e2eCredentialsUrlEnv] ?? env[e2eCredentialsUrlFallbackEnv] ?? '').trim();
  if (credentialsUrl.isNotEmpty) {
    defines['E2E_CREDENTIALS_URL'] = credentialsUrl;
  }
  if (env[e2eDeviceProxyEnv] == 'true') {
    defines['E2E_ENABLE_DEVELOPER_PROXY'] = 'true';
  }
  final upgradeLeg = UpgradeLeg.fromEnv(env);
  if (upgradeLeg != null) {
    defines[e2eUpgradeLegDefine] = upgradeLeg.name;
  }
  return defines;
}

/// Writes the bundled runtime config asset every E2E build ships.
///
/// The asset is one file in the shared working tree, and `mplatrol run all` builds
/// variants with different callback hosts concurrently, so it never carries
/// `E2E_CREDENTIALS_URL`: each build gets its own URL as a compile-time define.
/// Only `--reuse-last` writes a URL, into the already-built app's copy of this
/// asset, where it overrides the stale compile-time value.
String? writeE2eRuntimeAssetConfig(String repo, Map<String, String> env) {
  final defines = e2eRuntimeDartDefines(repo, env);
  final path = p.join(repo, runtimeE2eAssetConfigFile);
  if (defines.isEmpty) {
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
    return null;
  }
  defines.remove('E2E_CREDENTIALS_URL');
  Directory(p.dirname(path)).createSync(recursive: true);
  _writeIfBytesChanged(File(path), '${_encodeJson(defines)}\n');
  return path;
}

void writeIosDartDefines(String repo, List<String> defines) {
  final encodedDefines = defines.map(_encodeDartDefine).join(',');
  final iosFlutterDir = Directory(p.join(repo, 'ios', 'Flutter'))..createSync(recursive: true);
  for (final name in ['Debug.xcconfig', 'Profile.xcconfig', 'Release.xcconfig']) {
    final file = File(p.join(iosFlutterDir.path, name));
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final replacement = 'DART_DEFINES=$encodedDefines';
    final next = existing.contains(RegExp('^DART_DEFINES=', multiLine: true))
        ? existing.replaceFirst(RegExp('^DART_DEFINES=.*\$', multiLine: true), replacement)
        : [existing.trimRight(), replacement].where((line) => line.isNotEmpty).join('\n');
    _writeIfBytesChanged(file, next.endsWith('\n') ? next : '$next\n');
  }
}

void _writeIfBytesChanged(File file, String content) {
  final bytes = utf8.encode(content);
  if (file.existsSync()) {
    final existing = file.readAsBytesSync();
    if (_sameBytes(existing, bytes)) {
      return;
    }
  }
  file.writeAsStringSync(content);
}

bool _sameBytes(List<int> existing, List<int> expected) {
  if (existing.length != expected.length) {
    return false;
  }
  for (var index = 0; index < existing.length; index++) {
    if (existing[index] != expected[index]) {
      return false;
    }
  }
  return true;
}

Map<String, dynamic>? readE2eCredentialsFile(String repo, Map<String, String> env) {
  final path = e2eCredentialsFilePath(repo, env);
  if (path == null) {
    return null;
  }
  final file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  try {
    return _decodeJsonObject(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}

String? e2eCredentialsFilePath(String repo, Map<String, String> env) {
  final explicit = (env[e2eDartDefineFileEnv] ?? env[e2eDartDefineFileFallbackEnv] ?? '').trim();
  final rawPath = explicit.isEmpty ? defaultE2eDartDefineFile : explicit;
  final path = p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(repo, rawPath));
  if (explicit.isEmpty && !File(path).existsSync()) {
    return null;
  }
  return path;
}

String _encodeDartDefine(String define) => base64.encode(utf8.encode(define));

Map<String, dynamic>? _decodeJsonObject(String content) {
  final decoded = jsonDecode(content);
  return decoded is Map<String, dynamic> ? decoded : null;
}

String _encodeJson(Map<String, String> value) => const JsonEncoder.withIndent('  ').convert(value);

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
