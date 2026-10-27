import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The package-name pattern Patrol keeps in the E2E coverage report (`--coverage-package`): [configured]
/// (`coverage.packages` in `mplatrol.yaml`, e.g. `^(my_app|my_shared_.+)$`), else the app's own package from
/// [repo]'s `pubspec.yaml`.
String e2eCoveragePackagePattern(String repo, {String? configured}) {
  final explicit = configured?.trim() ?? '';
  if (explicit.isNotEmpty) {
    return explicit;
  }
  final pubspec = File(p.join(repo, 'pubspec.yaml'));
  final name = pubspec.existsSync()
      ? RegExp(r'^name:\s*([A-Za-z0-9_]+)\s*$', multiLine: true).firstMatch(pubspec.readAsStringSync())?.group(1)
      : null;
  return '^${RegExp.escape(name ?? 'app')}\$';
}

/// Globs Patrol drops from the E2E coverage report (`--coverage-ignore`): generated code and the E2E page objects.
const e2eCoverageIgnoreGlobs = ['**/*.g.dart', '**/*.freezed.dart', '**/lib/e2e/**'];

/// Per-file line hits of an LCOV report: source path to (line number to hit count).
///
/// Only `SF` and `DA` records are read; function and branch records are dropped, since merging is by file and line.
class Lcov {
  Lcov(this.files);

  /// Parses LCOV [text]. Throws a [FormatException] naming the line of a malformed `DA` record.
  factory Lcov.parse(String text) {
    final files = <String, Map<int, int>>{};
    Map<int, int>? current;
    var number = 0;
    for (final line in text.split('\n')) {
      number++;
      if (line.startsWith('SF:')) {
        current = files.putIfAbsent(line.substring(3).trim(), () => {});
      } else if (line.startsWith('DA:')) {
        final parts = line.substring(3).trim().split(',');
        final lineNumber = parts.length < 2 ? null : int.tryParse(parts[0]);
        final hits = parts.length < 2 ? null : int.tryParse(parts[1]);
        if (current == null || lineNumber == null || hits == null) {
          throw FormatException('Malformed LCOV record on line $number: "$line"');
        }
        current[lineNumber] = (current[lineNumber] ?? 0) + hits;
      } else if (line.startsWith('end_of_record')) {
        current = null;
      }
    }
    return Lcov(files);
  }

  /// The union of [reports]: every file and line any report has, with hit counts added up.
  factory Lcov.merge(Iterable<Lcov> reports) {
    final files = <String, Map<int, int>>{};
    for (final report in reports) {
      for (final MapEntry(key: path, value: lines) in report.files.entries) {
        final merged = files.putIfAbsent(path, () => {});
        for (final MapEntry(key: lineNumber, value: hits) in lines.entries) {
          merged[lineNumber] = (merged[lineNumber] ?? 0) + hits;
        }
      }
    }
    return Lcov(files);
  }

  final Map<String, Map<int, int>> files;

  /// The report without generated code, test code and the E2E page objects, and without anything outside a
  /// package's `lib/`.
  Lcov appCodeOnly() => Lcov({
        for (final MapEntry(key: path, value: lines) in files.entries)
          if (isAppCodePath(path)) path: lines,
      });

  /// LCOV text with one record per file, sorted by path.
  String render() {
    final buffer = StringBuffer();
    for (final path in files.keys.toList()..sort()) {
      buffer.writeln('SF:$path');
      final lines = files[path]!;
      for (final number in lines.keys.toList()..sort()) {
        buffer.writeln('DA:$number,${lines[number]}');
      }
      final hit = lines.values.where((hits) => hits > 0).length;
      buffer
        ..writeln('LF:${lines.length}')
        ..writeln('LH:$hit')
        ..writeln('end_of_record');
    }
    return buffer.toString();
  }
}

/// Whether [path] is app code the E2E coverage report counts: under a `lib/`, not generated, not test code and not
/// an E2E page object.
bool isAppCodePath(String path) {
  final normalized = p.posix.normalize(path.replaceAll(r'\', '/'));
  if (!normalized.endsWith('.dart') || normalized.endsWith('.g.dart') || normalized.endsWith('.freezed.dart')) {
    return false;
  }
  final segments = p.posix.split(normalized);
  final lib = segments.lastIndexOf('lib');
  if (lib < 0) {
    return false;
  }
  const testDirs = {'test', 'patrol_test', 'integration_test', 'test_driver'};
  if (segments.any(testDirs.contains)) {
    return false;
  }
  return !(lib + 1 < segments.length && segments[lib + 1] == 'e2e');
}

/// Maps a source path to its package name using the `rootUri`s of a `.dart_tool/package_config.json`, so a path
/// dependency in a differently named checkout (a worktree) still reports its real package name.
class PackageNames {
  const PackageNames([this._roots = const {}]);

  /// Reads the package roots of [packageConfigJson], resolving relative `rootUri`s against [configDirectory] (the
  /// `.dart_tool` directory). Throws a [FormatException] when the JSON is not a package config.
  factory PackageNames.fromPackageConfig(String packageConfigJson, {required String configDirectory}) {
    final decoded = jsonDecode(packageConfigJson);
    final packages = decoded is Map<String, dynamic> ? decoded['packages'] : null;
    if (packages is! List) {
      throw const FormatException('package_config.json has no "packages" list');
    }
    final roots = <String, String>{};
    for (final package in packages) {
      if (package is! Map<String, dynamic>) {
        continue;
      }
      final name = package['name'];
      final rootUri = package['rootUri'];
      if (name is! String || rootUri is! String) {
        continue;
      }
      final uri = Uri.parse(rootUri.endsWith('/') ? rootUri : '$rootUri/');
      final root = uri.hasScheme ? uri.toFilePath() : p.normalize(p.join(configDirectory, uri.toFilePath()));
      roots[p.normalize(root)] = name;
    }
    return PackageNames(roots);
  }

  final Map<String, String> _roots;

  /// The package of [path]: the package whose root is its longest parent, else [packageOf].
  String of(String path) {
    String? best;
    for (final root in _roots.keys) {
      if (p.isWithin(root, path) && (best == null || root.length > best.length)) {
        best = root;
      }
    }
    return best == null ? packageOf(path) : _roots[best]!;
  }
}

/// The package a source [path] belongs to: the directory above its last `lib/`, with a pub-cache version suffix
/// (`shared_core-1.2.3`) and dashes (`my-app`) normalised to the package name.
String packageOf(String path) {
  final segments = p.posix.split(p.posix.normalize(path.replaceAll(r'\', '/')));
  final lib = segments.lastIndexOf('lib');
  if (lib < 1) {
    return 'unknown';
  }
  return segments[lib - 1].replaceFirst(RegExp(r'-\d[\w.+-]*$'), '').replaceAll('-', '_');
}
