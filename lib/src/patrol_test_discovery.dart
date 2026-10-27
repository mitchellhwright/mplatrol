import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/upgrade/upgrade_leg.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const defaultPatrolTestDirectory = 'patrol_test';
const legacyPatrolTestDirectory = 'integration_test';

/// Set by the runner when the cred-finder cannot verify a valid login for the
/// tenant. Discovery still keeps every Patrol test in the generated native runner;
/// credential-dependent test bodies use the missing runtime credential signal
/// to report explicit skips instead of disappearing from the suite.
const e2eSkipHappyLoginTestEnv = 'MPLATROL_E2E_SKIP_HAPPY_LOGIN_TEST';

/// One Patrol test discovered from a dart test file, shared by the Android
/// (Java) and iOS (ObjC) runner generators.
class PatrolTest {
  PatrolTest({required this.method, required this.description});

  /// A readable, valid identifier derived from [description] — the generated
  /// test-method name shown in the LambdaTest/JUnit/XCTest report. Mutable so
  /// two tests in a file that share a description can be disambiguated (see
  /// [_uniquifyMethodNames]).
  String method;

  /// The `patrolTest('<description>')` description, with Dart escapes already
  /// interpreted (so it equals the COMPILED string). The generated runner
  /// resolves the full Patrol test name at RUNTIME by matching this against
  /// `listDartTests()` (the test ends with the description), so an enclosing
  /// `group('...')` in the dart file is handled automatically.
  final String description;
}

/// All Patrol tests in one dart test file — the file the tests are grouped
/// under in the report (the generated test class is named after it).
class PatrolTestFile {
  PatrolTestFile({required this.basename, required this.tests});

  /// Dart file basename without extension (e.g. `login_faults_test`). This is
  /// both the test-bundle group name (the bundle wraps each file's `main()` in
  /// `group('<basename>', ...)`) and the generated test-class name, so the
  /// report groups tests by their source file.
  final String basename;

  /// The file's Patrol tests, sorted by description with unique method names.
  final List<PatrolTest> tests;
}

/// One prepared-source selection shared by Dart and native runner generation.
///
/// This is not proof of a cached artifact's capabilities. Artifact consumers
/// must bind these digests to their successful build before enabling reuse.
class PatrolSelectionPlan {
  PatrolSelectionPlan({
    required this.repo,
    required this.platform,
    required List<PatrolTestFile> files,
    required List<({String file, String description, String reason})> excluded,
    required this.requirementsDigest,
    required this.capabilityDigest,
    required Map<String, String> sourceDigests,
    required Map<String, String> coverage,
    this.target,
    this.targetRegex,
    this.sdk,
  })  : files = List.unmodifiable(files.map((file) => PatrolTestFile(
            basename: file.basename,
            tests: List.unmodifiable(
                file.tests.map((test) => PatrolTest(method: test.method, description: test.description)))))),
        excluded = List.unmodifiable(excluded),
        _sourceDigests = Map.unmodifiable(sourceDigests),
        coverage = Map.unmodifiable(coverage) {
    _expectedSelectionDigest = selectionDigest;
  }

  final String repo;
  final String platform;
  final List<PatrolTestFile> files;
  final List<({String file, String description, String reason})> excluded;
  final String requirementsDigest;
  final String capabilityDigest;
  final Map<String, String> _sourceDigests;
  final Map<String, String> coverage;
  final String? target;
  final String? targetRegex;
  final String? sdk;
  late final String _expectedSelectionDigest;

  int get selectedCount => files.fold(0, (count, file) => count + file.tests.length);
  int get excludedCount => excluded.length;

  /// Returns non-secret selection evidence; aggregate smoke is labeled separately.
  Map<String, Object?> toJson() => {
        'schema': 1,
        'platform': platform,
        'requirementsDigest': requirementsDigest,
        'capabilityDigest': capabilityDigest,
        'selectedCount': selectedCount,
        'excludedCount': excludedCount,
        'selected': [
          for (final file in files)
            {
              'file': file.basename,
              'descriptions': file.tests.map((test) => test.description).toList(),
              'methods': file.tests.map((test) => test.method).toList(),
              'coverage': coverage[file.basename],
            },
        ],
        'excluded': [
          for (final test in excluded) {'file': test.file, 'description': test.description, 'reason': test.reason},
        ],
      };

  String get selectionDigest => (FingerprintBuilder()..addString(jsonEncode(toJson()))).finish();

  /// Rejects a plan used with another request or changed prepared inputs.
  void validate(String requestedRepo, {String? target, String? targetRegex, String? sdk}) {
    _validateRequest(requestedRepo, target: target, targetRegex: targetRegex, sdk: sdk);
    if (selectionDigest != _expectedSelectionDigest) {
      throw StateError('SDK selection was mutated; rediscover before building.');
    }
    _validateTestInventory();
    for (final entry in _sourceDigests.entries) {
      final file = File(entry.key);
      if (!file.existsSync() || (FingerprintBuilder()..addBytes(file.readAsBytesSync())).finish() != entry.value) {
        throw StateError('SDK selection inputs changed; prepare and rediscover before building.');
      }
    }
  }

  void _validateRequest(String requestedRepo, {String? target, String? targetRegex, String? sdk}) {
    if (p.normalize(requestedRepo) != p.normalize(repo) ||
        target != this.target ||
        targetRegex != this.targetRegex ||
        sdk != this.sdk) {
      throw StateError('SDK selection request changed; rediscover before building.');
    }
  }

  void _validateTestInventory() {
    final directory = patrolTestDirectoryPath(repo);
    final expected =
        _sourceDigests.keys.where((path) => p.dirname(path) == directory && path.endsWith('_test.dart')).toSet();
    final actual = patrolTestSourceFiles(repo).map((file) => file.path).toSet();
    if (expected.length != actual.length || !expected.containsAll(actual)) {
      throw StateError('Patrol source inventory changed; rediscover before building.');
    }
  }
}

/// The Patrol test directory configured in `pubspec.yaml`.
///
/// Patrol's standard directory is `patrol_test/`. Older the app branches
/// used `integration_test/`, so fall back to that when no Patrol config exists.
String patrolTestDirectory(String repo) {
  final configured = _configuredPatrolTestDirectory(repo);
  if (configured != null) {
    return configured;
  }
  if (Directory(p.join(repo, defaultPatrolTestDirectory)).existsSync()) {
    return defaultPatrolTestDirectory;
  }
  return legacyPatrolTestDirectory;
}

String patrolTestDirectoryPath(String repo) {
  final directory = patrolTestDirectory(repo);
  return p.normalize(p.isAbsolute(directory) ? directory : p.join(repo, directory));
}

String? _configuredPatrolTestDirectory(String repo) {
  final pubspec = File(p.join(repo, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return null;
  }
  try {
    final doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) {
      return null;
    }
    final patrol = doc['patrol'];
    if (patrol is! YamlMap) {
      return null;
    }
    final testDirectory = patrol['test_directory']?.toString().trim() ?? '';
    return testDirectory.isEmpty ? null : testDirectory;
  } catch (_) {
    return null;
  }
}

/// Every selected Patrol `*_test.dart` file that declares one or more
/// `patrolTest(...)`, each with its tests - sorted deterministically (files by
/// name, tests by description) with method names uniquified within each file.
/// Files with no `patrolTest` are skipped.
///
/// When [target] is set, discovery is restricted to that one file so the
/// generated native runner matches the `patrol build/test --target` bundle.
/// That exact-file behavior is preserved even when regex/SDK filtering is not
/// used.
///
/// [targetRegex] filters by source file path/basename OR Patrol description.
/// A file match keeps every Patrol test in that file; otherwise only matching
/// descriptions remain. [sdk] is the same kind of filter, but token-based:
/// `--sdk=videosdk` matches `videosdk_sdk_smoke_test.dart` or descriptions with a
/// `videosdk` token without hardcoding any SDK names.
///
/// [environment] (default: the process environment) names the app-upgrade leg in [e2eUpgradeLegEnv].
/// Outside a leg, a run without [target] leaves out the files that declare [upgradeFromMarker]; inside one it
/// discovers only those files, with only the tests that leg runs ([UpgradeLeg.runs]). [everyTest] turns that
/// off, for checks that cover every registered test (the SDK manifest). Credential-required
/// tests are not removed from discovery because each variant should expose the
/// same generated test list and let runtime credential handling mark skips.
List<PatrolTestFile> discoverPatrolTestFiles(String repo,
    {String? target,
    String? targetRegex,
    String? sdk,
    PatrolSelectionPlan? selection,
    Map<String, String>? environment,
    bool everyTest = false}) {
  if (selection != null) {
    selection.validate(repo, target: target, targetRegex: targetRegex, sdk: sdk);
    return selection.files;
  }
  final dir = Directory(patrolTestDirectoryPath(repo));
  if (!dir.existsSync()) {
    throw StateError('No Patrol test directory at ${dir.path} — nothing to discover.');
  }
  final files = _selectedTestFiles(repo, dir, target);
  final compiledTargetRegex = _compileTargetRegex(targetRegex);
  final sdkFilter = sdk?.trim();
  final upgradeLeg = everyTest ? null : UpgradeLeg.fromEnv(environment ?? Platform.environment);
  final result = <PatrolTestFile>[];
  for (final file in files) {
    final upgradeOnly = declaresUpgradeFrom(file.readAsStringSync());
    if (!everyTest && target == null && upgradeOnly != (upgradeLeg != null)) {
      continue;
    }
    final tests = _filterPatrolTests(
      repo: repo,
      file: file,
      tests: [
        for (final test in _parsePatrolTests(file))
          if (!upgradeOnly || upgradeLeg == null || upgradeLeg.runs(test.description)) test,
      ],
      targetRegex: compiledTargetRegex,
      sdk: sdkFilter == null || sdkFilter.isEmpty ? null : sdkFilter,
    );
    if (tests.isEmpty) {
      continue;
    }
    final basename = p.basenameWithoutExtension(file.path);
    if (!_identifierPattern.hasMatch(basename)) {
      throw StateError(
        'Test file "${p.basename(file.path)}" has a name that is not a valid '
        'class identifier ("$basename"); the generated Java/ObjC test class is '
        'named after it. Rename it to match ^[A-Za-z_][A-Za-z0-9_]*\$ (e.g. no '
        'leading digit or dashes).',
      );
    }
    _uniquifyMethodNames(tests);
    result.add(PatrolTestFile(basename: basename, tests: tests));
  }
  return result;
}

List<File> _selectedTestFiles(String repo, Directory dir, String? target) {
  if (target == null) {
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('_test.dart') && !_isGeneratedBundle(file))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  final targetPath = p.normalize(p.isAbsolute(target) ? target : p.join(repo, target));
  final integrationPath = p.normalize(dir.path);
  if (!p.isWithin(integrationPath, targetPath)) {
    throw StateError('Patrol target "$target" must be inside ${dir.path}.');
  }
  if (!targetPath.endsWith('_test.dart')) {
    throw StateError('Patrol target "$target" must be a *_test.dart file.');
  }
  final file = File(targetPath);
  if (!file.existsSync()) {
    throw StateError('Patrol target "$target" does not exist at ${file.path}.');
  }
  return [file];
}

/// Returns raw Patrol source targets, excluding generated bundle files.
List<File> patrolTestSourceFiles(String repo) =>
    _selectedTestFiles(repo, Directory(patrolTestDirectoryPath(repo)), null);

bool _isGeneratedBundle(File file) {
  final basename = p.basename(file.path);
  return basename == 'test_bundle.dart' ||
      basename == 'test_bundle_test.dart' ||
      basename == 'mplatrol_filtered_test.dart' ||
      basename == 'mplatrol_filtered_test_bundle_test.dart';
}

RegExp? _compileTargetRegex(String? source) {
  final trimmed = source?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  try {
    return RegExp(trimmed);
  } on FormatException catch (error) {
    throw StateError('Invalid Patrol target regex "$trimmed": ${error.message}');
  }
}

List<PatrolTest> _filterPatrolTests({
  required String repo,
  required File file,
  required List<PatrolTest> tests,
  required RegExp? targetRegex,
  required String? sdk,
}) {
  var filtered = tests;
  if (targetRegex != null) {
    filtered = _filterByRegex(repo: repo, file: file, tests: filtered, regex: targetRegex);
  }
  if (sdk != null) {
    filtered = _filterBySdk(repo: repo, file: file, tests: filtered, sdk: sdk);
  }
  return filtered;
}

List<PatrolTest> _filterByRegex({
  required String repo,
  required File file,
  required List<PatrolTest> tests,
  required RegExp regex,
}) {
  if (_fileMatches(repo: repo, file: file, matches: regex.hasMatch)) {
    return tests;
  }
  return tests.where((test) => regex.hasMatch(test.description)).toList();
}

List<PatrolTest> _filterBySdk({
  required String repo,
  required File file,
  required List<PatrolTest> tests,
  required String sdk,
}) {
  if (_fileMatches(repo: repo, file: file, matches: (value) => _sdkMatches(value, sdk))) {
    return tests;
  }
  return tests.where((test) => _sdkMatches(test.description, sdk)).toList();
}

bool _fileMatches({
  required String repo,
  required File file,
  required bool Function(String value) matches,
}) {
  final relative = p.relative(file.path, from: repo).replaceAll('\\', '/');
  final basename = p.basename(file.path);
  // Match only repo-relative names: the absolute path would let directories
  // outside the repo (checkout location, temp dir, user name) select tests.
  return matches(relative) || matches(basename) || matches(p.basenameWithoutExtension(basename));
}

bool _sdkMatches(String value, String sdk) {
  final sdkTokens = _selectionTokens(sdk);
  if (sdkTokens.isEmpty) {
    return false;
  }
  final valueTokens = _selectionTokens(value);
  for (var index = 0; index <= valueTokens.length - sdkTokens.length; index++) {
    if (_tokensEqualAt(valueTokens, sdkTokens, index)) {
      return true;
    }
  }
  return valueTokens.join().contains(sdkTokens.join());
}

bool _tokensEqualAt(List<String> valueTokens, List<String> sdkTokens, int offset) {
  for (var index = 0; index < sdkTokens.length; index++) {
    if (valueTokens[offset + index] != sdkTokens[index]) {
      return false;
    }
  }
  return true;
}

List<String> _selectionTokens(String value) {
  final separatedCamelCase = value.replaceAllMapped(
    RegExp('([a-z0-9])([A-Z])'),
    (match) => '${match.group(1)}_${match.group(2)}',
  );
  return separatedCamelCase.toLowerCase().split(RegExp('[^a-z0-9]+')).where((token) => token.isNotEmpty).toList();
}

/// A valid Java/Obj-C class identifier (the generated class is named after the
/// dart file basename).
final _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// One Dart string literal: the text between matching quotes. `(?:\\.|(?!\1).)*` consumes escaped characters (e.g.
/// `\'` inside a single-quoted string) instead of stopping at them, so apostrophes/escapes do not truncate it.
final _literalPattern = RegExp(r'''(['"])((?:\\.|(?!\1).)*)\1''');

/// `patrolTest('<description>', ...)`: captures the description, which may be adjacent literals that Dart
/// concatenates (`'first part ' 'second part'`, as long names are wrapped); [_joinedLiterals] joins them.
/// `(?<![A-Za-z0-9_$])` is a leading boundary so `myPatrolTest(` is not matched.
final _patrolTestPattern = RegExp(r'''(?<![A-Za-z0-9_$])patrolTest\(\s*((?:(['"])(?:\\.|(?!\2).)*\2\s*)+)''');

final _groupNamePattern = RegExp(r'''(?<![A-Za-z0-9_$])group\(\s*((?:(['"])(?:\\.|(?!\2).)*\2\s*)+)''');

/// The compiled string of the adjacent literals in [source]: a name wrapped over two literals is one name, not
/// its first literal.
String _joinedLiterals(String source) =>
    _literalPattern.allMatches(source).map((literal) => _unescapeDart(literal.group(2)!)).join();

List<PatrolTest> _parsePatrolTests(File file) {
  final source = _stripComments(file.readAsStringSync());
  _validatePatrolNames(file, source);
  return _patrolTestPattern.allMatches(source).map((match) {
    final description = _joinedLiterals(match.group(1)!);
    return PatrolTest(method: _sanitizeMethodName(description), description: description);
  }).toList()
    ..sort((a, b) => a.description.compareTo(b.description));
}

void _validatePatrolNames(File file, String source) {
  for (final pattern in [_patrolTestPattern, _groupNamePattern]) {
    for (final match in pattern.allMatches(source)) {
      final name = _joinedLiterals(match.group(1)!);
      if (name.contains('/')) {
        throw StateError(
          'Unsupported Patrol name ${jsonEncode(name)} in "${file.path}". '
          'Patrol listDartTests rejects "/" in test descriptions and enclosing '
          'group names. Replace "/" in the patrolTest() or group() name before '
          'building or uploading.',
        );
      }
    }
  }
}

/// Removes `/* */` block and `//` line comments so a commented-out
/// `patrolTest(...)` is not discovered as a phantom test (which would generate a
/// concrete @Test/-[test_*] that always fails at runtime and burns an LT device
/// session). Quoted strings preserve comment-like text in registered names.
String _stripComments(String source) => source.replaceAllMapped(
      RegExp(r'''(['"])(?:\\.|(?!\1).)*\1|/\*.*?\*/|//[^\n]*''', dotAll: true),
      (match) => match.group(1) == null ? ' ' : match.group(0)!,
    );

/// Interprets the Dart string escapes in a captured description so it equals the
/// COMPILED string patrol registers the test under (the runtime match compares
/// against that). Handles the common escapes plus `\uXXXX` / `\u{...}`.
String _unescapeDart(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    if (value[i] != r'\' || i + 1 >= value.length) {
      buffer.write(value[i]);
      continue;
    }
    final next = value[++i];
    switch (next) {
      case 'n':
        buffer.write('\n');
      case 't':
        buffer.write('\t');
      case 'r':
        buffer.write('\r');
      case 'b':
        buffer.write('\b');
      case 'f':
        buffer.write('\f');
      case 'v':
        buffer.write('\v');
      case 'u':
        i = _appendUnicodeEscape(value, i, buffer);
      default:
        buffer.write(next); // \\, \', \", \$ and any other → the literal char
    }
  }
  return buffer.toString();
}

/// Appends the rune for a `\u` escape starting after index [i] (`\uXXXX` or
/// `\u{X..}`) to [buffer], returning the index of the escape's last consumed
/// character. Falls back to a literal `u` if the escape is malformed.
int _appendUnicodeEscape(String value, int i, StringBuffer buffer) {
  if (i + 1 < value.length && value[i + 1] == '{') {
    final close = value.indexOf('}', i + 2);
    if (close > 0) {
      final code = int.tryParse(value.substring(i + 2, close), radix: 16);
      if (code != null) {
        buffer.writeCharCode(code);
        return close;
      }
    }
  } else if (i + 4 < value.length) {
    final code = int.tryParse(value.substring(i + 1, i + 5), radix: 16);
    if (code != null) {
      buffer.writeCharCode(code);
      return i + 4;
    }
  }
  buffer.write('u');
  return i;
}

/// A readable, valid identifier from a test description (non-alphanumerics → _).
String _sanitizeMethodName(String description) {
  final name = description
      .replaceAll(RegExp('[^A-Za-z0-9_]'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (name.isEmpty) {
    return 'patrolTest';
  }
  return RegExp('^[0-9]').hasMatch(name) ? 't_$name' : name;
}

/// Disambiguates duplicate method names (two tests in a file sharing a
/// description) by appending an index, so the generated source compiles.
void _uniquifyMethodNames(List<PatrolTest> tests) {
  final seen = <String>{};
  for (final test in tests) {
    if (seen.add(test.method)) {
      continue;
    }
    var index = 2;
    while (!seen.add('${test.method}_$index')) {
      index++;
    }
    test.method = '${test.method}_$index';
  }
}
