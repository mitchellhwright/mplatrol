import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/disk/disk_space.dart';
import 'package:mplatrol/src/disk/janitor_planner.dart';
import 'package:mplatrol/src/disk/trash_mover.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:path/path.dart' as p;

/// Env var: `off` skips the prune `mplatrol run` does after every run.
const itAutoCleanEnv = 'MPLATROL_IT_AUTO_CLEAN';

/// What `mplatrol clean --disk` looks at.
class DiskCleanOptions {
  /// Creates the options.
  const DiskCleanOptions({
    required this.dryRun,
    required this.aggressive,
    required this.checkout,
    required this.roots,
    required this.keep,
    required this.logDirs,
    required this.videoDirs,
  });

  /// List what would move without moving it.
  final bool dryRun;

  /// Also move pub state and CocoaPods of idle checkouts.
  final bool aggressive;

  /// The app checkout the command runs in; it is never pruned. Null outside one.
  final String? checkout;

  /// Directories whose checkouts (and workspaces of checkouts) are scanned for idle build outputs.
  final List<String> roots;

  /// Path fragments of checkouts never to touch (running matrix lanes, other people's work).
  final List<String> keep;

  /// Log directories whose entries are kept for [DiskJanitor.logRetention].
  final List<String> logDirs;

  /// Directories whose videos are kept for [DiskJanitor.videoRetention].
  final List<String> videoDirs;
}

/// Prunes mplatrol's disk footprint, and the shared caches its builds create, into the Trash.
class DiskJanitor {
  /// How long a checkout may sit unbuilt before its build outputs go.
  static const checkoutIdle = Duration(days: 3);

  /// How long Xcode DerivedData folders are kept after their last build.
  static const derivedDataRetention = Duration(days: 3);

  /// How long run reports, matrix logs and `.xcresult` evidence are kept.
  static const logRetention = Duration(days: 30);

  /// How long scratch videos are kept (the ones that matter are attached to tickets by then).
  static const videoRetention = Duration(days: 7);

  /// How long after a HyperExecute job's last log line its tool copies may go.
  static const jobToolIdle = Duration(hours: 1);

  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  MplatrolShell get _shell => getDep<MplatrolShell>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();
  DiskSpace get _disk => getDep<DiskSpace>();
  TrashMover get _trash => getDep<TrashMover>();

  String get _home => _platform.environment['HOME'] ?? '';

  /// Runs every prune [options] covers, printing free space and the Trash before and after, and
  /// returns the GB moved to the Trash (or that would move, in a dry run).
  Future<double> clean(DiskCleanOptions options) async {
    final volume = options.checkout ?? (_home.isEmpty ? '/' : _home);
    _logger.info('Before: ${await _disk.summary(volume)}');
    final planner = JanitorPlanner(now: DateTime.now());
    var gb = 0.0;
    for (final (label, paths) in _plan(planner, options)) {
      gb += await _apply(label, paths, dryRun: options.dryRun);
    }
    if (_platform.isMac) {
      await _deleteUnavailableSimulators(dryRun: options.dryRun);
    }
    final verb = options.dryRun ? 'Would move' : 'Moved';
    _logger.info('$verb ${DiskSpace.gb(gb)} to the Trash.');
    _logger.info('After: ${await _disk.summary(volume)}');
    await _warnAboutTrash(movedGb: options.dryRun ? 0 : gb);
    return gb;
  }

  Iterable<(String, List<String>)> _plan(JanitorPlanner planner, DiskCleanOptions options) sync* {
    final checkouts = planner.checkouts(options.roots);
    yield (
      'build outputs of checkouts idle for ${checkoutIdle.inDays}+ days (keeping the newest)',
      planner.staleCheckoutOutputs(checkouts,
          current: options.checkout,
          keep: options.keep,
          maxIdle: checkoutIdle,
          evidenceMaxAge: logRetention,
          aggressive: options.aggressive),
    );
    if (options.checkout != null) {
      yield (
        "this checkout's HyperExecute tool copies and old .xcresult bundles",
        _ownOutputs(planner, options.checkout!)
      );
    }
    final xcode = p.join(_home, 'Library', 'Developer', 'Xcode');
    if (_platform.isMac && _home.isNotEmpty) {
      yield (
        'Xcode DerivedData unused for ${derivedDataRetention.inDays}+ days',
        planner.olderThan(p.join(xcode, 'DerivedData'), derivedDataRetention,
            except: const {'ModuleCache.noindex', 'SDKStatCaches.noindex'}),
      );
      yield (
        'iOS DeviceSupport except the newest 2 iOS versions',
        planner.oldDeviceSupport(p.join(xcode, 'iOS DeviceSupport'))
      );
    }
    if (_home.isNotEmpty) {
      yield (
        'LambdaTest upload records that can no longer be reused',
        planner.ltArtifactRecords(p.join(_home, '.mplatrol', 'lt-artifacts'),
            maxAge: LtRunSupport.sharedArtifactMaxAge),
      );
    }
    yield (
      'run reports and logs older than ${logRetention.inDays} days',
      [
        if (options.checkout != null)
          ...planner.olderThan(p.join(options.checkout!, '.mplatrol', 'reports'), logRetention, files: true),
        for (final dir in options.logDirs) ...planner.olderThan(dir, logRetention, files: true),
      ],
    );
    yield ('videos older than ${videoRetention.inDays} days', planner.oldVideos(options.videoDirs, videoRetention));
  }

  /// The quick prune `mplatrol run` does when it finishes, unless [itAutoCleanEnv] is `off`: the
  /// HyperExecute tool copies of finished jobs in [checkout] and the leg directory [legDir], `.xcresult`
  /// bundles beyond the newest three, and run reports past [logRetention]. Never fails the run.
  ///
  /// When the leg released [checkout] ([checkoutReleased]), the next matrix leg is already preparing
  /// and building in it, so only [legDir] is pruned.
  Future<void> afterRun({required String checkout, String? legDir, bool checkoutReleased = false}) async {
    if ((_platform.environment[itAutoCleanEnv] ?? '').trim().toLowerCase() == 'off') {
      return;
    }
    try {
      final planner = JanitorPlanner(now: DateTime.now());
      final paths = [
        if (!checkoutReleased) ...[
          ..._ownOutputs(planner, checkout),
          ...planner.olderThan(p.join(checkout, '.mplatrol', 'reports'), logRetention, files: true),
        ],
        if (legDir != null)
          for (final platform in ['android', 'ios'])
            ...planner.idleJobTools(p.join(legDir, 'hyperexecute', platform), idle: jobToolIdle),
      ];
      if (paths.isEmpty || !_trash.available) {
        return;
      }
      final outcome = await _trash.move(paths, dryRun: false);
      _logger.info('[auto-clean] moved ${outcome.moved} old run output(s) (${DiskSpace.gb(outcome.gb)}) to the Trash; '
          '$itAutoCleanEnv=off skips this.');
    } catch (error) {
      _logger.warn('[auto-clean] skipped: $error');
    }
  }

  List<String> _ownOutputs(JanitorPlanner planner, String checkout) => [
        ...planner.idleJobTools(checkout, idle: jobToolIdle),
        ...planner.oldXcresults(checkout),
      ];

  Future<double> _apply(String label, List<String> paths, {required bool dryRun}) async {
    if (paths.isEmpty) {
      _logger.info('· $label: nothing to move');
      return 0;
    }
    final outcome = await _trash.move(paths, dryRun: dryRun);
    _logger.info('${dryRun ? '·' : '✓'} $label: ${outcome.moved} item(s), ${DiskSpace.gb(outcome.gb)}'
        '${dryRun ? ' (dry run)' : ''}');
    for (final path in paths) {
      _logger.detail('  $path');
    }
    return outcome.gb;
  }

  /// `xcrun simctl delete unavailable`: Xcode's own cleanup of simulators whose runtime is gone.
  Future<void> _deleteUnavailableSimulators({required bool dryRun}) async {
    if (dryRun) {
      _logger.info('· simulators of uninstalled runtimes: would run `xcrun simctl delete unavailable`');
      return;
    }
    final result =
        await _shell.runArgs('xcrun', ['simctl', 'delete', 'unavailable'], throwOnError: false, silent: true);
    _logger.info(result.exitCode == 0
        ? '✓ simulators of uninstalled runtimes: deleted (xcrun simctl delete unavailable)'
        : '· simulators of uninstalled runtimes: xcrun simctl failed (${result.errText.trim()})');
  }

  Future<void> _warnAboutTrash({required double movedGb}) async {
    final trash = await _disk.trashGb();
    if (trash != null && trash > DiskSpace.trashWarnGb) {
      _logger.warn('The Trash holds ${DiskSpace.gb(trash)}: empty the Trash to reclaim ${DiskSpace.gb(trash)}.');
    } else if (trash == null && movedGb > 0) {
      _logger.warn('Empty the Trash to reclaim the ${DiskSpace.gb(movedGb)} moved there.');
    }
  }
}
