import 'dart:io';

import 'package:path/path.dart' as p;

/// Decides which paths `mplatrol clean --disk` and the post-run prune move to the Trash.
///
/// Pure over the file system: it lists directories and reads modification times, never follows a
/// symbolic link (a workspace links shared checkouts in), and never removes anything.
class JanitorPlanner {
  /// Creates a planner that measures ages against [now].
  JanitorPlanner({required this.now});

  /// The time ages are measured against.
  final DateTime now;

  /// Entries of `build/` that are test evidence rather than build output.
  static const _evidence = {'reports'};

  /// Directories directly under [dir] (or files too, with [files]) last modified more than [maxAge]
  /// ago, except the names in [except]. Empty when [dir] does not exist.
  List<String> olderThan(String dir, Duration maxAge, {Set<String> except = const {}, bool files = false}) => [
        for (final entry in _children(dir))
          if ((files || entry is Directory) && !except.contains(p.basename(entry.path)) && _isOlder(entry, maxAge))
            entry.path,
      ];

  /// iOS DeviceSupport folders (`<model> <version> (<build>)`) except those of the newest [keep] iOS
  /// versions.
  List<String> oldDeviceSupport(String dir, {int keep = 2}) {
    final byVersion = <String, List<String>>{};
    for (final entry in _children(dir).whereType<Directory>()) {
      final version = RegExp(r' (\d+(?:\.\d+)*) \(').firstMatch(p.basename(entry.path))?.group(1);
      if (version != null) {
        byVersion.putIfAbsent(version, () => []).add(entry.path);
      }
    }
    final versions = byVersion.keys.toList()..sort(_compareVersions);
    return [for (final version in versions.reversed.skip(keep)) ...byVersion[version]!];
  }

  /// Flutter app checkouts directly under each of [roots] or one level below (a workspace of
  /// repos), skipping symbolic links.
  List<String> checkouts(List<String> roots) {
    final found = <String>{};
    for (final root in roots) {
      for (final child in _children(root).whereType<Directory>()) {
        if (_isAppCheckout(child.path)) {
          found.add(child.path);
          continue;
        }
        found.addAll([
          for (final grandchild in _children(child.path).whereType<Directory>())
            if (_isAppCheckout(grandchild.path)) grandchild.path,
        ]);
      }
    }
    return found.toList()..sort();
  }

  /// When [checkout] was last built or run: the newest modification time of its build and state
  /// directories and their direct children.
  DateTime lastActivity(String checkout) {
    var newest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final dir in [checkout, ..._activityDirs.map((rel) => p.join(checkout, rel))]) {
      for (final entry in [Directory(dir), ..._children(dir)]) {
        final modified = _modified(entry);
        if (modified != null && modified.isAfter(newest)) {
          newest = modified;
        }
      }
    }
    return newest;
  }

  static final _activityDirs = ['build', p.join('ios', 'build'), '.dart_tool', '.mplatrol'];

  /// The build outputs of [checkouts] idle for more than [maxIdle], except the most recently active
  /// checkout, [current], and any checkout whose path contains one of [keep]. Test evidence in
  /// `build/` (`.xcresult` bundles and `reports`) stays until it is [evidenceMaxAge] old. With
  /// [aggressive], also the pub state and CocoaPods (`.dart_tool`, `ios/Pods`, the patched pub
  /// cache), which the next `mplatrol run` restores.
  List<String> staleCheckoutOutputs(
    List<String> checkouts, {
    required String? current,
    required List<String> keep,
    required Duration maxIdle,
    required Duration evidenceMaxAge,
    bool aggressive = false,
  }) {
    final active = {for (final checkout in checkouts) checkout: lastActivity(checkout)};
    final newest = checkouts.isEmpty ? null : checkouts.reduce((a, b) => active[a]!.isAfter(active[b]!) ? a : b);
    final paths = <String>[];
    for (final checkout in checkouts) {
      final kept = checkout == newest ||
          (current != null && p.equals(checkout, current)) ||
          keep.any((fragment) => fragment.isNotEmpty && checkout.contains(fragment)) ||
          now.difference(active[checkout]!) <= maxIdle;
      if (!kept) {
        paths.addAll(_outputsOf(checkout, evidenceMaxAge: evidenceMaxAge, aggressive: aggressive));
      }
    }
    return paths;
  }

  List<String> _outputsOf(String checkout, {required Duration evidenceMaxAge, required bool aggressive}) {
    final build = p.join(checkout, 'build');
    return [
      for (final entry in _children(build))
        if (!_isEvidence(entry.path) || _isOlder(entry, evidenceMaxAge)) entry.path,
      for (final rel in [
        p.join('ios', 'build'),
        p.join('android', '.gradle'),
        p.join('.mplatrol', 'he-jobs'),
        if (aggressive) ...['.dart_tool', p.join('ios', 'Pods'), p.join('.mplatrol', 'patched_pub_cache')],
      ])
        if (_existsNoLink(p.join(checkout, rel))) p.join(checkout, rel),
    ];
  }

  static bool _isEvidence(String path) => path.endsWith('.xcresult') || _evidence.contains(p.basename(path));

  /// `xcresult` bundles a run leaves in [checkout]'s `build/`, except the newest [keep].
  List<String> oldXcresults(String checkout, {int keep = 3}) {
    final bundles = [
      for (final entry in _children(p.join(checkout, 'build')))
        if (entry.path.endsWith('.xcresult')) entry,
    ]..sort((a, b) => _modified(b)!.compareTo(_modified(a)!));
    return [for (final bundle in bundles.skip(keep)) bundle.path];
  }

  /// The LambdaTest tunnel and HyperExecute CLI copies (`LT`, `.hyperexecute`) in the HyperExecute
  /// job directories under [jobRoot] (the root itself and `.mplatrol/he-jobs/*`) whose job last wrote
  /// its CLI log more than [idle] ago. The runner seeds a fresh `LT` for every job; logs and yaml stay.
  List<String> idleJobTools(String jobRoot, {required Duration idle}) {
    final jobs = [jobRoot, for (final job in _children(p.join(jobRoot, '.mplatrol', 'he-jobs'))) job.path];
    return [
      for (final job in jobs)
        for (final tool in ['LT', '.hyperexecute'])
          if (_existsNoLink(p.join(job, tool)) && _jobIdle(job, p.join(job, tool), idle)) p.join(job, tool),
    ];
  }

  /// Whether the job in [job] stopped more than [idle] ago: its CLI log, or without one [tool]
  /// itself, was last written before then.
  bool _jobIdle(String job, String tool, Duration idle) {
    final log = File(p.join(job, 'hyperexecute-cli.log'));
    return _isOlder(log.existsSync() ? log : File(tool), idle);
  }

  /// The per-user LambdaTest upload records (`<platform>-<identity>[...].json`) that can no longer be
  /// reused ([maxAge]) or are beyond the newest [keepPerPlatform] of their platform, plus temporary
  /// records left by an interrupted write.
  List<String> ltArtifactRecords(String dir, {required Duration maxAge, int keepPerPlatform = 20}) {
    final records = _children(dir).whereType<File>().toList()..sort((a, b) => _modified(b)!.compareTo(_modified(a)!));
    final kept = <String, int>{};
    return [
      for (final record in records)
        if (record.path.endsWith('.tmp')
            ? _isOlder(record, const Duration(days: 1))
            : _isOlder(record, maxAge) || _over(kept, p.basename(record.path).split('-').first, keepPerPlatform))
          record.path,
    ];
  }

  static bool _over(Map<String, int> counts, String key, int limit) {
    counts[key] = (counts[key] ?? 0) + 1;
    return counts[key]! > limit;
  }

  /// Video files (`.mp4`, `.mov`, `.webm`) anywhere under [dirs] older than [maxAge]. Directories
  /// that cannot be listed are skipped.
  List<String> oldVideos(List<String> dirs, Duration maxAge) {
    final videos = <String>[];
    final pending = [...dirs];
    while (pending.isNotEmpty) {
      for (final entry in _children(pending.removeLast())) {
        if (entry is Directory) {
          pending.add(entry.path);
        } else if (_isVideo(entry.path) && _isOlder(entry, maxAge)) {
          videos.add(entry.path);
        }
      }
    }
    return videos;
  }

  static bool _isVideo(String path) => const {'.mp4', '.mov', '.webm'}.contains(p.extension(path).toLowerCase());

  bool _isOlder(FileSystemEntity entry, Duration age) {
    final modified = _modified(entry);
    return modified != null && now.difference(modified) > age;
  }

  static DateTime? _modified(FileSystemEntity entry) {
    final stat = FileStat.statSync(entry.path);
    return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
  }

  static bool _existsNoLink(String path) =>
      !FileSystemEntity.isLinkSync(path) && FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  static bool _isAppCheckout(String dir) =>
      File(p.join(dir, 'pubspec.yaml')).existsSync() &&
      Directory(p.join(dir, 'ios')).existsSync() &&
      Directory(p.join(dir, 'android')).existsSync();

  /// The entries directly in [dir] that are not symbolic links; empty when [dir] is missing, a link
  /// or not readable.
  static List<FileSystemEntity> _children(String dir) {
    if (FileSystemEntity.isLinkSync(dir) || !Directory(dir).existsSync()) {
      return const [];
    }
    try {
      return [
        for (final entry in Directory(dir).listSync(followLinks: false))
          if (entry is! Link) entry,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static int _compareVersions(String a, String b) {
    final left = a.split('.').map(int.parse).toList();
    final right = b.split('.').map(int.parse).toList();
    for (var i = 0; i < left.length || i < right.length; i++) {
      final diff = (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
      if (diff != 0) {
        return diff;
      }
    }
    return 0;
  }
}
