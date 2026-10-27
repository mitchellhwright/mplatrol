import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:path/path.dart' as p;

/// Keeps one local leg's evidence in its own directory, so the next leg on the same lane checkout
/// cannot overwrite it (2026-10-06 regression r8: globex's androidTest results replaced acme's).
///
/// In the leg directory ([ItLegDir.path]) it appends the full Patrol, Gradle or xcodebuild output to
/// `build.log`, copies the Android `androidTest-results` (per-test logcats, `test-result.textproto`)
/// to `android/androidTest-results[-<n>]`, and moves the iOS `.xcresult` bundles of the run to `ios/`.
/// Without a leg directory the build log goes to `<repo>/build/mplatrol/build.log` and the results stay
/// where the build wrote them.
class LocalLegArtifacts {
  ItLegDir get _leg => getDep<ItLegDir>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// The directory the leg's evidence goes to: the leg directory, else `<repo>/build/mplatrol`.
  String directory(String repo) => _leg.path ?? p.join(repo, 'build', 'mplatrol');

  /// Where a local Android leg's video segments go: `video/` in the leg directory, else
  /// `<repo>/build/e2e-videos`.
  String videoDirectory(String repo) =>
      _leg.path == null ? p.join(repo, 'build', 'e2e-videos') : p.join(_leg.path!, 'video');

  /// Appends [output], the full output of the [variant] run, to the leg's `build.log` and returns its path.
  String keepBuildLog(String repo, {required String variant, required String output}) {
    final log = File(p.join(directory(repo), 'build.log'));
    log.parent.createSync(recursive: true);
    log.writeAsStringSync('===== $variant ${DateTime.now().toIso8601String()} =====\n$output\n', mode: FileMode.append);
    _logger.info('[leg-artifacts] full $variant build and test output: ${log.path}');
    return log.path;
  }

  /// Copies [results] (the Android `androidTest-results/connected/debug` directory) into the leg directory
  /// and returns the instrumentation issues its `test-result.textproto` files written since [since] name,
  /// e.g. `INSTRUMENTATION_FAILED: … INSTRUMENTATION_ABORTED: System has crashed.`, each logged.
  List<String> keepAndroidResults(String repo, {required String results, required DateTime since}) {
    final source = Directory(results);
    if (!source.existsSync()) {
      return const [];
    }
    final issues = _instrumentationIssues(source, since);
    issues.forEach(_logger.err);
    if (_leg.path == null) {
      return issues;
    }
    final target = _freshDirectory(p.join(directory(repo), 'android', 'androidTest-results'));
    _copyTree(source, target);
    _logger.info('[leg-artifacts] Android test results (logcats, test-result.textproto): ${target.path}');
    return issues;
  }

  /// Moves the iOS result [bundles] of this run into the leg directory's `ios/`.
  void keepIosResults(String repo, Iterable<String> bundles) {
    if (_leg.path == null) {
      return;
    }
    for (final bundle in bundles) {
      final source = Directory(bundle);
      if (!source.existsSync()) {
        continue;
      }
      final target = _freshDirectory(p.join(directory(repo), 'ios', p.basename(bundle)));
      try {
        source.renameSync(target.path);
        // Only a leg directory on another volume than the checkout reaches this.
        // coverage:ignore-start
      } on FileSystemException {
        _copyTree(source, target);
        source.deleteSync(recursive: true);
      }
      // coverage:ignore-end
      _logger.info('[leg-artifacts] iOS result bundle: ${target.path}');
    }
  }

  /// [path], or `<path>-2`, `<path>-3`, … when an earlier tenant of the leg already kept one there.
  Directory _freshDirectory(String path) {
    var candidate = path;
    for (var index = 2; Directory(candidate).existsSync(); index++) {
      candidate = '$path-$index';
    }
    Directory(candidate).parent.createSync(recursive: true);
    return Directory(candidate);
  }

  void _copyTree(Directory source, Directory target) {
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      final destination = p.join(target.path, p.relative(entity.path, from: source.path));
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        copyEvidenceFile(entity.path, destination, _logger);
      }
    }
  }

  static final _issue = RegExp(r'name: "(INSTRUMENTATION_[A-Z_]+)"\s*message: "((?:\\.|[^"\\])*)"');

  List<String> _instrumentationIssues(Directory results, DateTime since) => [
        for (final file in results.listSync(recursive: true, followLinks: false).whereType<File>())
          // File times may be whole seconds, so a report written in the run's first second still counts.
          if (p.basename(file.path) == 'test-result.textproto' &&
              !file.lastModifiedSync().isBefore(since.subtract(const Duration(seconds: 1))))
            for (final match in _issue.allMatches(file.readAsStringSync()))
              '[android-utp] ${match[1]}: ${match[2]!.replaceAll(r'\"', '"')}',
      ];
}
