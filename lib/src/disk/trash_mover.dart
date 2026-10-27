import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/disk/disk_space.dart';

/// What one [TrashMover.move] did: how many paths went to the Trash, their size, and the paths
/// `trash` refused.
class TrashOutcome {
  /// Creates an outcome.
  const TrashOutcome({required this.moved, required this.gb, required this.failed});

  /// Paths moved (or, in a dry run, that would be moved).
  final int moved;

  /// Their total size in GB, measured before the move.
  final double gb;

  /// Paths `trash` could not move; they are left where they are.
  final List<String> failed;
}

/// Moves paths to the user's Trash with macOS `trash`, never deleting them: the user empties the
/// Trash when they decide to.
class TrashMover {
  /// How many paths go into one `du` or `trash` call, well under the argument-length limit.
  static const batchSize = 200;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  DiskSpace get _disk => getDep<DiskSpace>();

  /// Whether the `trash` command is on PATH (macOS 15 and later ship `/usr/bin/trash`).
  bool get available => _shell.whichSync('trash') != null;

  /// Measures [paths] and, unless [dryRun], moves them to the Trash. Without a `trash` command
  /// nothing moves and every path is reported as failed.
  Future<TrashOutcome> move(List<String> paths, {required bool dryRun}) async {
    if (paths.isEmpty) {
      return const TrashOutcome(moved: 0, gb: 0, failed: []);
    }
    var gb = 0.0;
    final failed = <String>[];
    final canMove = dryRun || available;
    if (!canMove) {
      _logger.warn('No `trash` command on PATH (macOS 15+ ships /usr/bin/trash); nothing was moved.');
    }
    for (var start = 0; start < paths.length; start += batchSize) {
      final batch = paths.sublist(start, (start + batchSize).clamp(0, paths.length));
      gb += await _disk.sizeGb(batch) ?? 0;
      if (!canMove) {
        failed.addAll(batch);
      } else if (!dryRun) {
        failed.addAll(await _trash(batch));
      }
    }
    return TrashOutcome(moved: paths.length - failed.length, gb: gb, failed: failed);
  }

  /// Moves [batch] to the Trash; on failure retries one path at a time and returns those that
  /// still failed.
  Future<List<String>> _trash(List<String> batch) async {
    final result = await _shell.runArgs('trash', batch, throwOnError: false, silent: true);
    if (result.exitCode == 0) {
      return const [];
    }
    final failed = <String>[];
    for (final path in batch) {
      final single = await _shell.runArgs('trash', [path], throwOnError: false, silent: true);
      if (single.exitCode != 0) {
        _logger.warn('Could not move $path to the Trash: ${single.errText.trim()}');
        failed.add(path);
      }
    }
    return failed;
  }
}
