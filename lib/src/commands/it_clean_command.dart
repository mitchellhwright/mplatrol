import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:path/path.dart' as p;

/// DEV NOTE* When you create a new command, make sure you add it to the [MplatrolCommandRunner]
///
/// `mplatrol clean` tears down what a login E2E run can leave behind: any
/// running LambdaTest tunnel, and the iOS LambdaTest build/IPA artifacts.
///
/// The runners deliberately never kill stray processes themselves — each run
/// only stops the tunnel it started (via its own process handle). Stopping
/// *other* tunnels is destructive, so it lives here behind an explicit command
/// the user invokes on purpose, not as a side effect of a run.
///
/// `mplatrol clean --disk` instead prunes mplatrol's disk footprint into the
/// Trash (see [DiskJanitor]); it stops no tunnel.
class ItCleanCommand extends BaseCommand {
  ItCleanCommand() {
    argParser
      ..addFlag('disk',
          negatable: false,
          help: 'Move old build outputs, Xcode DerivedData and DeviceSupport, stale caches, logs and videos '
              'to the Trash, and print free space before and after. Stops no tunnel.')
      ..addFlag('dry-run', negatable: false, help: 'With --disk: list what would move, move nothing.')
      ..addFlag('aggressive',
          negatable: false,
          help: 'With --disk: also move .dart_tool, ios/Pods and the patched pub cache of idle checkouts '
              '(the next `mplatrol run` restores them).')
      ..addMultiOption('root',
          valueHelp: 'dir',
          help: 'With --disk: a directory of checkouts or workspaces to scan for idle build outputs '
              "(default: the directory holding this checkout's workspace, when run inside the workspace).")
      ..addMultiOption('keep',
          valueHelp: 'path-fragment', help: 'With --disk: never touch a checkout whose path contains this.')
      ..addMultiOption('log-dir',
          valueHelp: 'dir', help: "With --disk: keep this directory's entries for 30 days (e.g. matrix logs).")
      ..addMultiOption('video-dir',
          valueHelp: 'dir', help: 'With --disk: move videos under this directory after 7 days.');
  }

  @override
  String get name => 'clean';

  @override
  String get description => 'Stop any running LambdaTest tunnel and remove the iOS E2E build artifacts; '
      'with --disk, move old build outputs and caches to the Trash.';

  @override
  void validateInput() {
    final diskOnly = ['dry-run', 'aggressive'].where((flag) => argResults[flag] as bool);
    final diskLists = ['root', 'keep', 'log-dir', 'video-dir'].where((o) => (argResults[o] as List).isNotEmpty);
    if (!(argResults['disk'] as bool) && (diskOnly.isNotEmpty || diskLists.isNotEmpty)) {
      usageException('--${[...diskOnly, ...diskLists].first} only applies with --disk.');
    }
  }

  @override
  Future<int> runCommand() async {
    if (argResults['disk'] as bool) {
      await getDep<DiskJanitor>().clean(_diskOptions());
      return ExitCode.success.code;
    }
    await _stopTunnels();
    _removeArtifacts();
    logger.success('Cleaned up the login E2E environment.');
    return ExitCode.success.code;
  }

  DiskCleanOptions _diskOptions() {
    final repo = fileSystem.getAppDirectory(throwIfNotFound: false);
    final here = p.current;
    final inWorkspace = p.equals(repo.parent.path, here) || p.isWithin(repo.parent.path, here);
    final checkout = repo.existsSync() && inWorkspace ? repo.path : null;
    final roots = argResults['root'] as List<String>;
    return DiskCleanOptions(
      dryRun: argResults['dry-run'] as bool,
      aggressive: argResults['aggressive'] as bool,
      checkout: checkout,
      roots: roots.isNotEmpty || checkout == null ? roots : [p.dirname(p.dirname(checkout))],
      keep: argResults['keep'] as List<String>,
      logDirs: argResults['log-dir'] as List<String>,
      videoDirs: argResults['video-dir'] as List<String>,
    );
  }

  /// Stops every running LambdaTest tunnel. The binary path comes from `LT_BIN`
  /// (else [ltTunnelBinaryPath]). This is the one place allowed to stop tunnels it
  /// did not start, because the user ran `mplatrol clean` on purpose.
  Future<void> _stopTunnels() async {
    final home = platformWrapper.environment['HOME'] ?? '';
    final ltBin = platformWrapper.environment['LT_BIN'] ?? (home.isEmpty ? 'LT' : ltTunnelBinaryPath(home));
    logger.info('Stopping any running LambdaTest tunnel ($ltBin)');
    await shell.runArgs('pkill', ['-f', ltBin], throwOnError: false);
  }

  /// Removes the iOS LambdaTest build products and the tunnel log a run leaves
  /// in the app repo. Best-effort: silently skips anything absent.
  void _removeArtifacts() {
    final repo = fileSystem.getAppDirectory(throwIfNotFound: false);
    final targets = [p.join(repo.path, 'ios', 'build', 'xcui-lt'), p.join(repo.path, 'lt.log')];
    for (final path in targets) {
      if (removeIfExists(path)) {
        logger.info('Removed $path');
      }
    }
  }
}
