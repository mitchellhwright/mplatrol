import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;

/// Env var: a directory of this `mplatrol run` leg's own, outside the app
/// checkout. With it, a LambdaTest run frees the checkout as soon as its app and
/// test artifacts are uploaded (see [ItLegDir.release]), so a matrix lane can
/// prepare and build the next leg while this leg's devices still run.
const itLegDirEnv = 'MPLATROL_IT_LEG_DIR';

/// The file [ItLegDir.release] writes in the leg directory once the checkout is
/// no longer needed; it holds the release time.
const itCheckoutReleasedMarker = 'checkout-released';

/// The binaries a HyperExecute job directory holds that are not evidence: the LambdaTest tunnel and the
/// HyperExecute CLI.
const _notEvidence = {'LT', 'hyperexecute'};

/// Copies one evidence file [source] to [destination] and returns whether it did. Evidence never fails a leg: the
/// HyperExecute CLI and tunnel binaries and symbolic links (which may point out of the job directory) are
/// skipped, and a copy that fails logs a `[leg-artifacts] warn` naming the file and the error.
bool copyEvidenceFile(String source, String destination, MplatrolLogger logger) {
  if (_notEvidence.contains(p.basename(source)) || FileSystemEntity.isLinkSync(source)) {
    return false;
  }
  try {
    File(destination).parent.createSync(recursive: true);
    File(source).copySync(destination);
    return true;
  } on FileSystemException catch (error) {
    logger.warn('[leg-artifacts] warn: could not copy $source to $destination '
        '(${error.osError?.message ?? error.message}); continuing without it.');
    return false;
  }
}

/// One `mplatrol run` leg's directory ([itLegDirEnv]) and whether the leg still
/// needs the app checkout.
///
/// A run may free the checkout only when it is one tenant on LambdaTest variants
/// only ([expectedUploads]); it frees it once every one of those variants has
/// uploaded ([release]). From then on the leg's HyperExecute jobs run in
/// [jobRoot], and test lessons and bug drafts go to [stateRepo], a copy of the
/// checkout state they read, so nothing reads or writes the checkout again.
class ItLegDir {
  PlatformWrapper get _platform => getDep<PlatformWrapper>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// How many LambdaTest variants of this run still upload before the checkout
  /// is free; 0 keeps it for the whole run (several tenants, or a local variant
  /// that builds and runs from it).
  int get expectedUploads => _pendingUploads;
  set expectedUploads(int variants) {
    _pendingUploads = variants;
    _releasable = variants > 0;
  }

  var _pendingUploads = 0;
  var _releasable = false;

  var _released = false;
  String? _commit;
  final _hooks = <Future<void> Function()>[];

  /// The leg directory, or null when [itLegDirEnv] is not set.
  String? get path {
    final raw = (_platform.environment[itLegDirEnv] ?? '').trim();
    return raw.isEmpty ? null : p.normalize(p.absolute(raw));
  }

  /// Whether this leg no longer uses the checkout.
  bool get released => _released;

  /// The checkout's commit when it was released; null before.
  String? get commit => _commit;

  /// Runs [hook] when the checkout is released, before anything else stops
  /// reading it.
  void onRelease(Future<void> Function() hook) => _hooks.add(hook);

  /// Where this leg's HyperExecute jobs of [platform] run: a directory of
  /// their own in the leg directory when the run can free the checkout (so a
  /// variant that uploaded first never starts its jobs in the checkout), else
  /// [repo].
  String jobRoot(String repo, String platform) =>
      _releasable && path != null ? p.join(path!, 'hyperexecute', platform) : repo;

  /// Where test lessons and bug drafts are read and written: a copy of the
  /// checkout state in the leg directory once released, else [repo].
  String stateRepo(String repo) => _released ? p.join(path!, 'state') : repo;

  /// Called by each LambdaTest variant once its artifacts are uploaded. When
  /// the last expected variant uploaded, copies the checkout state the rest of
  /// the run reads ([repo]'s test lessons and bug drafts, and the credential
  /// file [env] names)
  /// into the leg directory, runs the [onRelease] hooks and writes
  /// [itCheckoutReleasedMarker], after which the checkout is not used again.
  Future<void> release({required String repo, required Map<String, String> env}) async {
    if (_released || _pendingUploads < 1 || --_pendingUploads > 0) {
      return;
    }
    final leg = path;
    if (leg == null) {
      return;
    }
    for (final hook in _hooks) {
      await hook();
    }
    final state = p.join(leg, 'state');
    _copyInto(state, repo, TestLessonHistory(repo).file.path);
    final drafts = Directory(p.join(repo, '.mplatrol', 'bug-drafts'));
    if (drafts.existsSync()) {
      for (final file in drafts.listSync(recursive: true).whereType<File>()) {
        _copyInto(state, repo, file.path);
      }
    }
    final credentials = e2eCredentialsFilePath(repo, env);
    if (credentials != null && p.isWithin(repo, credentials)) {
      _copyInto(state, repo, credentials);
    }
    _commit = await _checkoutCommit(repo);
    _released = true;
    Directory(leg).createSync(recursive: true);
    File(p.join(leg, itCheckoutReleasedMarker)).writeAsStringSync('${DateTime.now().toUtc().toIso8601String()}\n');
    _logger.info('[lane-release] artifacts uploaded; the checkout is free for the next leg '
        '(this leg continues in $leg)');
  }

  void _copyInto(String state, String repo, String file) {
    if (File(file).existsSync()) {
      copyEvidenceFile(file, p.join(state, p.relative(file, from: repo)), _logger);
    }
  }

  Future<String?> _checkoutCommit(String repo) async {
    final result = await getDep<MplatrolShell>()
        .runArgs('git', ['rev-parse', '--short=12', 'HEAD'], workingDirectory: repo, throwOnError: false, silent: true);
    final commit = result.outText.trim();
    return result.exitCode == 0 && commit.isNotEmpty ? commit : null;
  }
}
