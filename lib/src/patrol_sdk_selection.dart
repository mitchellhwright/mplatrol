import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;

const patrolSdkRequirementsPath = 'patrol_test/sdk_requirements.json';

/// Record of the runtime configuration bundle the prepared E2E app uses,
/// written by the prepare step: `{"schemaVersion": 1, "bundle": <repo path>}`.
const e2eRuntimeConfigRecordPath = '.mplatrol/e2e_runtime_config.json';

/// Optional SDK capability field: per native platform, the dot paths in the
/// tenant's runtime configuration that must be `true` or a non-empty string for
/// the SDK journey to run (for example a wallet the tenant has not enabled).
const runtimeConfigKey = 'runtimeConfig';

/// Why an SDK journey can or cannot run on the prepared app. [notRegisteredByTenant]: the SDK is built but
/// the tenant's prepare step left its tagged registration ([_tagBody]) commented out; [missingJourneyWiring]:
/// the app does not register it at all.
enum _SdkEligibility { available, notBuilt, notRegisteredByTenant, missingJourneyWiring, notEnabled }

/// Manifest flag marking a Patrol test file that drives real OS permission
/// dialogs, so the native runner must not pre-grant permissions for it.
const realPermissionDialogsKey = 'realPermissionDialogs';

/// Returns the basenames of Patrol test files whose manifest entry sets
/// [realPermissionDialogsKey] to `true`.
///
/// A repo without `patrol_test/sdk_requirements.json` has no exemptions. A
/// present manifest with a non-boolean flag fails closed.
Set<String> patrolRealPermissionDialogFiles(String repo) {
  final file = File(p.join(repo, patrolSdkRequirementsPath));
  if (!file.existsSync()) {
    return const {};
  }
  final manifest = jsonDecode(file.readAsStringSync());
  final declarations = _objects(_object(manifest, 'SDK requirements')['tests'], 'test requirements');
  return {
    for (final declaration in declarations)
      if (_realPermissionDialogs(declaration)) p.basenameWithoutExtension(_text(declaration['file'], 'test file')),
  };
}

/// Manifest key listing the SDKs that pin their servers' certificates, so a LambdaTest job whose tests need one
/// runs without LambdaTest's network capture (its TLS-intercepting proxy breaks pinned connections).
const certificatePinningSdksKey = 'certificatePinningSdks';

/// Returns the basenames of Patrol test files whose manifest entry requires one of the SDKs the manifest lists
/// under [certificatePinningSdksKey].
///
/// A repo without `patrol_test/sdk_requirements.json` has none.
Set<String> patrolCertificatePinningFiles(String repo) {
  final file = File(p.join(repo, patrolSdkRequirementsPath));
  if (!file.existsSync()) {
    return const {};
  }
  final manifest = _object(jsonDecode(file.readAsStringSync()), 'SDK requirements');
  final pinning = manifest[certificatePinningSdksKey] == null
      ? const <String>{}
      : _strings(manifest[certificatePinningSdksKey], 'certificate pinning SDKs').toSet();
  final declarations = _objects(manifest['tests'], 'test requirements');
  return {
    for (final declaration in declarations)
      if (declaration['requires'] is List &&
          (declaration['requires'] as List).any((group) => _strings(group, 'SDK alternatives').any(pinning.contains)))
        p.basenameWithoutExtension(_text(declaration['file'], 'test file')),
  };
}

/// Manifest flag marking a Patrol test file that only runs on local devices
/// (for example a chain that needs the app data an earlier test left behind),
/// so LambdaTest selection excludes it instead of scheduling a certain skip.
const localOnlyKey = 'localOnly';

bool _realPermissionDialogs(Map<String, dynamic> declaration) => _flag(declaration, realPermissionDialogsKey);

bool _flag(Map<String, dynamic> declaration, String key) {
  final value = declaration[key] ?? false;
  if (value is! bool) {
    throw StateError('"$key" for "${declaration['file']}" must be true or false.');
  }
  return value;
}

/// Selects existing journeys from explicit requirements and prepared SDK evidence.
///
/// This is the LambdaTest selection, so a [localOnlyKey] file is excluded, and
/// so is a file that could only skip itself on a LambdaTest leg for [tenant] (see
/// [ltNotSelectedReason]). Unknown declarations or incomplete metadata fail
/// closed. This plan describes prepared sources, not an already uploaded or
/// cached native artifact.
PatrolSelectionPlan planPatrolSdkSelection(
  String repo, {
  required String platform,
  String? target,
  String? targetRegex,
  String? sdk,
  String? tenant,
}) {
  if (!const ['android', 'ios', 'ios-simulator'].contains(platform)) {
    throw StateError('Unknown SDK selection platform "$platform".');
  }
  final nativePlatform = platform == 'ios-simulator' ? 'ios' : platform;
  final evidence = _PreparedEvidence(repo, nativePlatform);
  final manifest = evidence.json(p.join(repo, patrolSdkRequirementsPath));
  if (manifest['schema'] != 1) {
    throw StateError('Unsupported SDK requirements schema; update the manifest.');
  }
  final declarations = _objects(manifest['tests'], 'test requirements');
  final all = discoverPatrolTestFiles(repo, everyTest: true);
  final capabilities = _object(manifest['capabilities'], 'SDK capabilities');
  _validateDeclarations(repo, all, declarations, capabilities);
  final available = _availableCapabilities(evidence, capabilities, nativePlatform);
  _rejectUnresolvedRegistrations(evidence, manifest['unresolvedRegistrations']);
  final requested = discoverPatrolTestFiles(repo, target: target, targetRegex: targetRegex);
  final sdkFilter = sdk?.trim();
  if (sdkFilter != null && !capabilities.containsKey(sdkFilter)) {
    throw StateError('Unknown explicit SDK requirement "$sdkFilter".');
  }
  final result = _selectFiles(requested, all, declarations, capabilities, available,
      platform: platform,
      sdk: sdkFilter,
      ltReason: (file) => ltNotSelectedReason(
          evidence.read(p.join(patrolTestDirectoryPath(repo), '${file.basename}.dart')),
          tenant: tenant));
  for (final file in patrolTestSourceFiles(repo)) {
    evidence.read(file.path);
  }
  return PatrolSelectionPlan(
    repo: repo,
    platform: platform,
    files: result.files,
    excluded: result.excluded,
    requirementsDigest: evidence.digests[p.join(repo, patrolSdkRequirementsPath)]!,
    capabilityDigest: evidence.digest(),
    sourceDigests: evidence.digests,
    coverage: result.coverage,
    target: target,
    targetRegex: targetRegex,
    sdk: sdk,
  );
}

({
  List<PatrolTestFile> files,
  List<({String file, String description, String reason})> excluded,
  Map<String, String> coverage
}) _selectFiles(List<PatrolTestFile> requested, List<PatrolTestFile> all, List<Map<String, dynamic>> declarations,
    Map<String, dynamic> capabilities, Map<String, _SdkEligibility> available,
    {required String platform, required String? sdk, required String? Function(PatrolTestFile file) ltReason}) {
  final selected = <PatrolTestFile>[];
  final excluded = <({String file, String description, String reason})>[];
  final coverage = <String, String>{};
  for (final file in requested) {
    final declaration =
        declarations.singleWhere((entry) => p.basenameWithoutExtension(entry['file'] as String) == file.basename);
    final groups = _requirementGroups(declaration, capabilities);
    if (sdk != null && !groups.any((group) => group.contains(sdk))) {
      continue;
    }
    final reason = _exclusionReason(declaration, groups, available, platform) ?? ltReason(file);
    if (reason == null) {
      _requireWholeFile(file, all);
      selected.add(file);
      coverage[file.basename] = declaration['coverage'] as String;
    } else {
      for (final test in file.tests) {
        excluded.add((file: file.basename, description: test.description, reason: reason));
      }
    }
  }
  return (files: selected, excluded: excluded, coverage: coverage);
}

Map<String, _SdkEligibility> _availableCapabilities(
    _PreparedEvidence evidence, Map<String, dynamic> definitions, String platform) {
  final available = <String, _SdkEligibility>{};
  for (final entry in definitions.entries) {
    final definition = _object(entry.value, 'SDK ${entry.key}');
    available[entry.key] = evidence.capability(definition, platform);
  }
  return available;
}

void _rejectUnresolvedRegistrations(_PreparedEvidence evidence, Object? value) {
  for (final registration in _objects(value, 'unresolved registrations')) {
    if (evidence.registrationActive(registration)) {
      throw StateError('Active SDK registration has unknown requirements: '
          '${_text(registration['reason'], 'unresolved registration reason')}');
    }
  }
}

void _validateDeclarations(String repo, List<PatrolTestFile> files, List<Map<String, dynamic>> declarations,
    Map<String, dynamic> capabilities) {
  final names = <String>{};
  for (final declaration in declarations) {
    final name = _text(declaration['file'], 'test file');
    if (!names.add(name)) {
      throw StateError('Duplicate SDK test requirement "$name".');
    }
    _validateDeclarationSource(repo, files, declaration);
    _validateTestMetadata(declaration);
    _requirementGroups(declaration, capabilities);
  }
  if (files.length != declarations.length || patrolTestSourceFiles(repo).length != files.length) {
    throw StateError('Discovered Patrol tests lack explicit SDK requirements; update the manifest.');
  }
}

void _validateDeclarationSource(String repo, List<PatrolTestFile> files, Map<String, dynamic> declaration) {
  final name = declaration['file'] as String;
  final absolute = p.normalize(p.join(repo, name));
  if (p.isAbsolute(name) || p.dirname(absolute) != patrolTestDirectoryPath(repo)) {
    throw StateError('SDK test requirement must be inside the Patrol source directory.');
  }
  final matching = files.where((file) => '${file.basename}.dart' == p.basename(name));
  if (matching.length != 1) {
    throw StateError('SDK requirement "$name" has no discovered Patrol registration.');
  }
  final expected = _strings(declaration['descriptions'], 'Patrol descriptions').toSet();
  final actual = matching.single.tests.map((test) => test.description).toSet();
  if (expected.length != actual.length ||
      actual.length != matching.single.tests.length ||
      !expected.containsAll(actual)) {
    throw StateError('SDK descriptions changed in "$name"; update its explicit requirements.');
  }
}

void _validateTestMetadata(Map<String, dynamic> declaration) {
  final platforms = _strings(declaration['platforms'], 'supported platforms');
  if (platforms.isEmpty || platforms.any((value) => !const ['android', 'ios', 'ios-simulator'].contains(value))) {
    throw StateError('Invalid explicit Patrol platform requirements.');
  }
  if (!const ['journey', 'aggregate-smoke'].contains(declaration['coverage'])) {
    throw StateError('Unknown Patrol coverage classification.');
  }
  _realPermissionDialogs(declaration);
  _flag(declaration, localOnlyKey);
}

List<List<String>> _requirementGroups(Map<String, dynamic> declaration, Map<String, dynamic> definitions) {
  final value = declaration['requires'];
  if (value is! List) {
    throw StateError('Missing explicit SDK requirement groups.');
  }
  final result = <List<String>>[];
  for (final group in value) {
    final alternatives = _strings(group, 'SDK alternatives');
    if (alternatives.isEmpty || alternatives.any((sdk) => !definitions.containsKey(sdk))) {
      throw StateError('Unknown or empty SDK requirement alternative.');
    }
    result.add(alternatives);
  }
  return result;
}

String? _exclusionReason(Map<String, dynamic> declaration, List<List<String>> groups,
    Map<String, _SdkEligibility> available, String platform) {
  if (!(declaration['platforms'] as List).contains(platform)) {
    return 'unsupported platform: $platform';
  }
  if (_flag(declaration, localOnlyKey)) {
    return 'local-only (not scheduled on LambdaTest)';
  }
  for (final group in groups) {
    if (!group.any((sdk) => available[sdk] == _SdkEligibility.available)) {
      return '${_ineligibleReason(group, available)}: ${group.join(' or ')}';
    }
  }
  return null;
}

/// Why a LambdaTest leg for [tenant] does not select a Patrol test file whose [source] could only skip itself there,
/// from the skip markers the suite's tests carry; null when it can run. A mock belongs to one tenant
/// (`MockTarget(..., tenant: '<tenant>')`), so another tenant's leg skips it (`MOCK_TENANT_MISMATCH`); a test that
/// needs a mock run
/// (`mock_required`) skips without one, and `mplatrol run` has none; LambdaTest devices have no enrolled
/// biometrics (`no_enrolled_biometrics`) and are never set to Spanish (`device_locale_not_spanish`). LambdaTest
/// does take a `language`/`locale` job argument, but it is applied through the app's launch arguments, which
/// Patrol's runner does not forward, so the Spanish test is not run in a Spanish job.
String? ltNotSelectedReason(String source, {required String? tenant}) {
  final mockTenants = {for (final match in _mockTenant.allMatches(source)) match[1]!.toLowerCase()};
  final legTenant = tenant?.trim().toLowerCase();
  final otherTenants = mockTenants.where((mockTenant) => mockTenant != legTenant).toList()..sort();
  if (legTenant != null && legTenant.isNotEmpty && otherTenants.isNotEmpty) {
    return 'mock data belongs to ${otherTenants.join(' and ')}, not the leg tenant $legTenant (MOCK_TENANT_MISMATCH)';
  }
  if (source.contains(RegExp(r'\bmock_required\b'))) {
    return 'needs a mock run (mock_required); mplatrol run configures no mock (MOCK_NOT_CONFIGURED)';
  }
  if (source.contains(RegExp(r'\bno_enrolled_biometrics\b'))) {
    return 'LambdaTest devices have no enrolled biometrics (DEVICE_NO_BIOMETRICS)';
  }
  if (source.contains(RegExp(r'\bdevice_locale_not_spanish\b'))) {
    return 'LambdaTest devices are never set to Spanish (DEVICE_LOCALE_MISMATCH)';
  }
  return null;
}

final _mockTenant = RegExp(r'''MockTarget\([^;]*?\btenant:\s*['"]([A-Za-z0-9_-]+)['"]''');

String _ineligibleReason(List<String> group, Map<String, _SdkEligibility> available) {
  if (group.any((sdk) => available[sdk] == _SdkEligibility.notRegisteredByTenant)) {
    return 'SDK not registered by the tenant build';
  }
  if (group.any((sdk) => available[sdk] == _SdkEligibility.missingJourneyWiring)) {
    return 'SDK journey wiring missing';
  }
  if (group.any((sdk) => available[sdk] == _SdkEligibility.notEnabled)) {
    return 'SDK not enabled in the tenant runtime configuration';
  }
  return 'SDK not built';
}

void _requireWholeFile(PatrolTestFile selected, List<PatrolTestFile> all) {
  final original = all.singleWhere((file) => file.basename == selected.basename);
  if (selected.tests.length != original.tests.length) {
    throw StateError('Partial-file SDK selection cannot register an identical Dart/native suite; '
        'select a whole file until explicit per-test registration is available.');
  }
}

class _PreparedEvidence {
  _PreparedEvidence(this.repo, String platform) {
    final configuration = json(p.join(repo, '.dart_tool/package_config.json'));
    if (configuration['configVersion'] != 2) {
      throw StateError('Unknown prepared package metadata version; resolve dependencies.');
    }
    for (final package in _objects(configuration['packages'], 'resolved packages')) {
      final name = _text(package['name'], 'package name');
      _text(package['rootUri'], 'package root URI');
      _text(package['packageUri'], 'package library URI');
      if (_packages.containsKey(name)) {
        throw StateError('Duplicate resolved package "$name".');
      }
      _packages[name] = package;
    }
    final plugins = json(p.join(repo, '.flutter-plugins-dependencies'));
    _plugins = _object(plugins['plugins'], 'native platform plugins');
    _nativePluginsBuilt(platform, const []);
    read(p.join(repo, 'pubspec.lock'));
  }

  final String repo;
  final Map<String, Map<String, dynamic>> _packages = {};
  final Map<String, String> _contents = {};
  final Map<String, String> digests = {};
  late final Map<String, dynamic> _plugins;

  String read(String path) {
    return _contents.putIfAbsent(path, () {
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError('SDK selection metadata is missing: ${p.basename(path)}; prepare first.');
      }
      final contents = file.readAsStringSync();
      digests[path] = (FingerprintBuilder()..addBytes(utf8.encode(contents))).finish();
      return contents;
    });
  }

  Map<String, dynamic> json(String path) {
    try {
      return _object(jsonDecode(read(path)), p.basename(path));
    } on FormatException {
      throw StateError('Malformed SDK selection metadata: ${p.basename(path)}; prepare first.');
    }
  }

  String digest() {
    final fingerprint = FingerprintBuilder();
    final paths = digests.keys.toList()..sort();
    for (final path in paths) {
      fingerprint.addString(p.relative(path, from: repo));
      fingerprint.addString(digests[path]!);
    }
    return fingerprint.finish();
  }

  _SdkEligibility capability(Map<String, dynamic> definition, String platform) {
    final packages = _strings(definition['packages'], 'SDK packages');
    final native = _object(definition['nativePlugins'], 'SDK native requirements');
    final requiredPlugins = _strings(native[platform], 'SDK platform plugins');
    final registrations = _objects(definition['registrations'], 'SDK registrations');
    if (packages.isEmpty || registrations.isEmpty) {
      throw StateError('SDK capability lacks package or active registration evidence.');
    }
    final active = registrations.map(registrationActive).toList();
    if (packages.any((name) => !_packages.containsKey(name))) {
      if (active.contains(false)) {
        return _SdkEligibility.notBuilt;
      }
      throw StateError('Active SDK registration lacks resolved package evidence; prepare again.');
    }
    if (!_nativePluginsBuilt(platform, requiredPlugins)) {
      return _SdkEligibility.notBuilt;
    }
    if (active.contains(false)) {
      final tagged = [
        for (var index = 0; index < registrations.length; index++)
          if (!active[index] && registrations[index]['tag'] != null) index,
      ];
      return tagged.isEmpty ? _SdkEligibility.missingJourneyWiring : _SdkEligibility.notRegisteredByTenant;
    }
    return _runtimeConfigEnables(definition, platform) ? _SdkEligibility.available : _SdkEligibility.notEnabled;
  }

  /// Whether the selected runtime configuration sets every [runtimeConfigKey]
  /// path [definition] lists for [platform].
  bool _runtimeConfigEnables(Map<String, dynamic> definition, String platform) {
    final requirements = definition[runtimeConfigKey];
    if (requirements == null) {
      return true;
    }
    final byPlatform = _object(requirements, 'SDK runtime configuration requirements');
    if (byPlatform.keys.any((key) => !const ['android', 'ios'].contains(key))) {
      throw StateError('Unknown platform in SDK runtime configuration requirements.');
    }
    final paths = byPlatform[platform] == null
        ? const <String>[]
        : _strings(byPlatform[platform], 'SDK runtime configuration paths');
    if (paths.isEmpty) {
      return true;
    }
    final config = _runtimeConfig();
    return paths.every((path) => _enabledValue(config, path));
  }

  Map<String, dynamic> _runtimeConfig() {
    final record = json(p.join(repo, e2eRuntimeConfigRecordPath));
    final bundle = record['schemaVersion'] == 1 ? record['bundle'] : null;
    if (bundle is! String ||
        bundle.isEmpty ||
        p.isAbsolute(bundle) ||
        !p.isWithin(repo, p.normalize(p.join(repo, bundle)))) {
      throw StateError('Invalid E2E runtime configuration record; prepare first.');
    }
    return json(p.join(repo, bundle));
  }

  bool _nativePluginsBuilt(String platform, List<String> required) {
    final plugins = _objects(_plugins[platform], 'prepared $platform plugins');
    final built = <String>{};
    final seen = <String>{};
    for (final plugin in plugins) {
      final name = _text(plugin['name'], 'native plugin name');
      if (!seen.add(name) || plugin['native_build'] is! bool) {
        throw StateError('Unknown or duplicate native plugin build evidence; prepare again.');
      }
      if (plugin['native_build'] == true) {
        built.add(name);
      }
    }
    return built.containsAll(required);
  }

  bool registrationActive(Map<String, dynamic> registration) {
    final source = _registrationSource(_text(registration['source'], 'registration source'));
    final tag = registration['tag'];
    final body = tag == null ? source : _tagBody(source, _text(tag, 'registration tag'));
    final symbol = _text(registration['symbol'], 'registration symbol');
    final code = _codeWithoutCommentsOrStrings(body).replaceAll(RegExp(r'\s+'), '');
    return code.contains(symbol.replaceAll(RegExp(r'\s+'), ''));
  }

  String _registrationSource(String source) {
    if (source.startsWith('package:')) {
      final uri = Uri.parse(source);
      final segments = uri.pathSegments;
      if (segments.length < 2 || segments.contains('..')) {
        throw StateError('Invalid SDK registration package source.');
      }
      final package = _packages[segments.first];
      if (package == null) {
        throw StateError('Unknown SDK registration package; resolve dependencies.');
      }
      final config = Uri.file(p.join(repo, '.dart_tool/package_config.json'));
      final root = config.resolve(_text(package['rootUri'], 'package root URI'));
      final lib = Uri.directory(root.toFilePath()).resolve(_text(package['packageUri'], 'package library URI'));
      return read(Uri.directory(lib.toFilePath()).resolve(segments.skip(1).join('/')).toFilePath());
    }
    final path = p.normalize(p.join(repo, source));
    if (!p.isWithin(repo, path)) {
      throw StateError('SDK registration source escapes the app checkout.');
    }
    return read(path);
  }
}

bool _enabledValue(Map<String, dynamic> config, String path) {
  Object? value = config;
  for (final key in path.split('.')) {
    value = value is Map ? value[key] : null;
  }
  return value == true || (value is String && value.trim().isNotEmpty);
}

String _tagBody(String source, String tag) {
  final marker = RegExp.escape(tag);
  final blocks = RegExp('// BEGIN MPLATROL TAG: $marker\\b'
          r'([\s\S]*?)'
          '// END MPLATROL TAG: $marker\\b')
      .allMatches(source)
      .toList();
  if (blocks.length != 1) {
    throw StateError('Missing or ambiguous SDK registration tag "$tag"; prepare again.');
  }
  return blocks.single.group(1)!;
}

String _codeWithoutCommentsOrStrings(String source) =>
    source.replaceAll(RegExp(r'''/\*[\s\S]*?\*/|//[^\n]*|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"'''), '');

Map<String, dynamic> _object(Object? value, String context) {
  if (value is! Map<String, dynamic>) {
    throw StateError('Missing or invalid $context in SDK metadata.');
  }
  return value;
}

List<Map<String, dynamic>> _objects(Object? value, String context) {
  if (value is! List) {
    throw StateError('Missing or invalid $context in SDK metadata.');
  }
  return value.map((entry) => _object(entry, context)).toList();
}

String _text(Object? value, String context) {
  if (value is! String || value.trim().isEmpty) {
    throw StateError('Missing or invalid $context in SDK metadata.');
  }
  return value;
}

List<String> _strings(Object? value, String context) {
  if (value is! List) {
    throw StateError('Missing or invalid $context in SDK metadata.');
  }
  final strings = value.map((entry) => _text(entry, context)).toList();
  if (strings.toSet().length != strings.length) {
    throw StateError('Duplicate $context in SDK metadata.');
  }
  return strings;
}
