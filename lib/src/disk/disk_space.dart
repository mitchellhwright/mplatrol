import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:path/path.dart' as p;

/// Env var: the free disk space, in GB, below which `mplatrol run` and `mplatrol build` warn
/// before they start (default [DiskSpace.defaultMinFreeGb]).
const itMinFreeGbEnv = 'MPLATROL_IT_MIN_FREE_GB';

/// Free disk space and the size of the user's Trash, read with `df` and `du`.
///
/// `mplatrol clean --disk` moves what it prunes to the Trash, so the space comes back only when the
/// user empties it; every disk message therefore says how much the Trash holds.
class DiskSpace {
  /// Free space below which `mplatrol run` and `mplatrol build` warn, unless [itMinFreeGbEnv] says otherwise.
  static const defaultMinFreeGb = 40;

  /// Trash size above which `mplatrol clean --disk` and the low-disk warning ask the user to empty it.
  static const trashWarnGb = 20.0;

  static const _kbPerGb = 1024 * 1024;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// The free space threshold: [itMinFreeGbEnv] when it is a positive number, else
  /// [defaultMinFreeGb].
  int get minFreeGb {
    final configured = int.tryParse((_platform.environment[itMinFreeGbEnv] ?? '').trim());
    return configured != null && configured > 0 ? configured : defaultMinFreeGb;
  }

  /// Free GB on the volume that holds [path], or null when `df` gives no answer.
  Future<double?> freeGb(String path) async {
    final result = await _shell.runArgs('df', ['-k', path], throwOnError: false, silent: true);
    final lines = result.outText.trim().split('\n');
    if (result.exitCode != 0 || lines.length < 2) {
      return null;
    }
    final columns = lines.last.trim().split(RegExp(r'\s+'));
    final availableKb = columns.length > 3 ? int.tryParse(columns[3]) : null;
    return availableKb == null ? null : availableKb / _kbPerGb;
  }

  /// GB in the user's Trash (`~/.Trash`), or null when it cannot be read: macOS only lets
  /// processes with Full Disk Access list it.
  Future<double?> trashGb() async {
    final home = _platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }
    return sizeGb([p.join(home, '.Trash')]);
  }

  /// Total GB of [paths] (`du -sk`), or null when `du` cannot read one of them.
  Future<double?> sizeGb(List<String> paths) async {
    if (paths.isEmpty) {
      return 0;
    }
    final result = await _shell.runArgs('du', ['-sk', ...paths], throwOnError: false, silent: true);
    if (result.exitCode != 0) {
      return null;
    }
    var kb = 0;
    for (final line in result.outText.trim().split('\n')) {
      kb += int.tryParse(line.split('\t').first.trim()) ?? 0;
    }
    return kb / _kbPerGb;
  }

  /// One line for `mplatrol doctor` and `mplatrol clean --disk`: the free space on [path]'s volume and
  /// what the Trash holds.
  Future<String> summary(String path) async {
    final free = await freeGb(path);
    final freeText = free == null ? 'free space unknown' : '${gb(free)} free';
    return 'Disk: $freeText; ${trashText(await trashGb())}';
  }

  /// A warning when the volume holding [path] has less than [minFreeGb] free, else null.
  Future<String?> lowDiskWarning(String path) async {
    final free = await freeGb(path);
    if (free == null || free >= minFreeGb) {
      return null;
    }
    return 'Only ${gb(free)} free on the disk (below $minFreeGb GB; builds stall when it runs out). '
        '${trashText(await trashGb())}. Run `mplatrol clean --disk` to move old build outputs and caches to '
        'the Trash, then empty it.';
  }

  /// What the Trash holds, phrased for the user: an "empty it" nudge when it is large.
  static String trashText(double? trash) {
    if (trash == null) {
      return 'the Trash size is unreadable here (Finder shows it)';
    }
    if (trash > trashWarnGb) {
      return 'the Trash holds ${gb(trash)}: empty the Trash to reclaim ${gb(trash)}';
    }
    return 'the Trash holds ${gb(trash)}';
  }

  /// [value] GB with one decimal, e.g. `12.5 GB`.
  static String gb(double value) => '${value.toStringAsFixed(1)} GB';
}
