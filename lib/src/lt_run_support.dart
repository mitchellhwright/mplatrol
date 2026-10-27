import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;

/// Env var: the revision of build inputs that live outside the checkout (e.g. a white-label assets repo the
/// prepare command copies in), part of the per-user artifact cache key (see [LtRunSupport.sharedArtifactPath]).
/// Unset when every input is in the checkout.
const ltInputsRevisionEnv = 'MPLATROL_INPUTS_REVISION';

/// The LambdaTest tunnel binary (`LT`) the HyperExecute CLI runs, kept in mplatrol's own per-user directory
/// under [home]: `~/.mplatrol/hyperexecute/LT`. `LT_BIN` overrides it. Never `~/Downloads`: a
/// round started from Terminal has no macOS permission to read it (r12: Operation not permitted).
String ltTunnelBinaryPath(String home) => p.join(home, '.mplatrol', 'hyperexecute', 'LT');

/// Removes [path] whether it is a directory (recursively) or a file, and
/// reports whether anything was removed. Best-effort: a path that does not
/// exist is a no-op that returns `false`.
///
/// Shared by the iOS LambdaTest runner (pre-cleaning IPA staging dirs) and
/// `mplatrol clean` (removing leftover build artifacts), both of which work on
/// real on-disk paths through `dart:io` rather than the mocked [FileSystem].
bool removeIfExists(String path) {
  final dir = Directory(path);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
    return true;
  }
  final file = File(path);
  if (file.existsSync()) {
    file.deleteSync();
    return true;
  }
  return false;
}

/// Logic shared by [LtAndroidRunner] and [LtIosRunner]: the terminal build
/// statuses, the poll-budget sizing, the reuse-last cache decode, and the
/// git-sha build name. Each runner mixes this in and supplies only what differs
/// (its queue timeout, its build-name prefix, and how it surfaces failures).
///
/// The mixin resolves its own dependencies through [getDep] (so hosts need not
/// forward them) and reads [pollDelay] from the host, which both runners already
/// expose as a field.
mixin LtRunSupport {
  /// Wait between build-status poll iterations; the host runner provides it
  /// (two seconds in production, [Duration.zero] in tests).
  Duration get pollDelay;

  MplatrolShell get ltShell => getDep<MplatrolShell>();
  FileSystem get ltFileSystem => getDep<FileSystem>();

  /// How long an upload recorded in the per-user artifact cache is reused;
  /// LambdaTest keeps uploaded apps for a limited time.
  static const sharedArtifactMaxAge = Duration(days: 7);

  /// The per-user record of the LambdaTest ids uploaded for build [identity]
  /// of [platform] with the build inputs revision [ltInputsRevisionEnv] names in
  /// [env], shared by every checkout so a lane reuses an upload another lane
  /// made from the same sources: `~/.mplatrol/lt-artifacts/`. Null without a
  /// `HOME`.
  String? sharedArtifactPath(String platform, String identity, Map<String, String> env) {
    final home = getDep<PlatformWrapper>().environment['HOME'] ?? '';
    final revision = (env[ltInputsRevisionEnv] ?? '').trim();
    final name = revision.isEmpty ? '$platform-$identity' : '$platform-$identity-inputs-$revision';
    return home.isEmpty ? null : p.join(home, '.mplatrol', 'lt-artifacts', '$name.json');
  }

  /// Why the per-user record at [path] cannot be reused, or null when it can.
  String? sharedArtifactMiss(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return 'no upload recorded for build identity ${shortIdentity(path)}';
    }
    final age = DateTime.now().difference(file.lastModifiedSync());
    if (age > sharedArtifactMaxAge) {
      return 'the upload recorded for build identity ${shortIdentity(path)} is ${age.inDays} days old';
    }
    return null;
  }

  /// The first 12 characters of the build identity a shared record [path]
  /// names, for logs.
  String shortIdentity(String path) {
    final name = p.basenameWithoutExtension(path);
    var identity = name.substring(name.indexOf('-') + 1);
    final revision = identity.lastIndexOf('-inputs-');
    if (revision >= 0) {
      identity = identity.substring(0, revision);
    }
    return identity.length > 12 ? identity.substring(0, 12) : identity;
  }

  /// LambdaTest statuses that mean the run finished (success is decided by the
  /// caller). Identical for Espresso and XCUITest builds.
  static const terminalStatuses = {
    'passed',
    'completed',
    'failed',
    'error',
    'stopped',
    'timeout',
    'idle_timeout',
    'aborted',
  };

  /// Extra seconds added to `queueTimeout + idleTimeout` when sizing the poll
  /// budget, so polling outlasts the worst-case run instead of cutting the
  /// tunnel mid-test.
  static const _pollMarginSeconds = 120;

  /// Lower bound on poll attempts, used when [pollDelay] is zero (tests) so the
  /// loop still iterates enough to reach a terminal status.
  static const _minPollAttempts = 600;

  /// Poll attempts sized so `attempts * pollDelay` outlasts the worst-case run:
  /// the [queueTimeoutSeconds] the trigger sends plus the [idleTimeoutSeconds]
  /// plus a margin. Falls back to [_minPollAttempts] when [pollDelay] is zero
  /// (tests).
  int maxPollAttempts({required int queueTimeoutSeconds, required int idleTimeoutSeconds}) {
    final budgetSeconds = queueTimeoutSeconds + idleTimeoutSeconds + _pollMarginSeconds;
    final perPoll = pollDelay.inSeconds;
    if (perPoll <= 0) {
      return _minPollAttempts;
    }
    return (budgetSeconds / perPoll).ceil();
  }

  /// `<prefix>-<short git sha>` (e.g. `PatrolIOS-abc1234`), falling back to
  /// `<prefix>-local` when the sha cannot be read.
  Future<String> gitBuildName({required String prefix, required String workingDirectory}) async {
    final result = await ltShell.run(
      'git rev-parse --short HEAD',
      throwOnError: false,
      silent: true,
      workingDirectory: workingDirectory,
    );
    final sha = result.outText.trim();
    return '$prefix-${sha.isEmpty ? 'local' : sha}';
  }

  /// Decodes [body] to a JSON object, or null when it is blank or not a JSON
  /// map. Callers that must fail on a bad body wrap this; pollers tolerate null.
  Map<String, dynamic>? tryDecodeObject(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// The `{app, test}` ids written by the last build+upload (`--reuse-last`),
  /// or null when the cache is missing or incomplete. The reason is reported
  /// through [onMissing]/[onIncomplete] so each runner keeps its own wording and
  /// failure shape (the Android runner logs + returns null; the iOS runner
  /// throws). [onLoaded] runs with the valid ids before they are returned.
  /// SDK-aware callers must supply the current selection and complete build identity.
  /// SDK receipt failures use [onSdkInvalid] or the existing incomplete callback.
  (String, String)? loadCachedAppIds(
    String cachePath, {
    required String nativeGeneratorIdentity,
    required void Function() onMissing,
    required void Function() onIncomplete,
    required void Function(String appId, String testId) onLoaded,
    PatrolSelectionPlan? sdkSelection,
    String? sdkBuildIdentity,
    void Function(String reason)? onSdkInvalid,
  }) {
    if (!ltFileSystem.fileExistsSync(cachePath)) {
      onMissing();
      return null;
    }
    final cache = tryDecodeObject(ltFileSystem.readAsStringSync(cachePath));
    final appId = cache?['app'];
    final testId = cache?['test'];
    if (appId is! String ||
        appId.isEmpty ||
        testId is! String ||
        testId.isEmpty ||
        cache?['nativeGenerator'] != nativeGeneratorIdentity) {
      onIncomplete();
      return null;
    }
    final reason = _sdkCacheFailure(cache!, sdkSelection, sdkBuildIdentity);
    if (reason != null) {
      _reportSdkFailure(reason, onSdkInvalid, onIncomplete);
      return null;
    }
    onLoaded(appId, testId);
    return (appId, testId);
  }

  /// Persists the uploaded [appId]/[testId] for a later `--reuse-last`.
  void saveCachedAppIds(String cachePath, String appId, String testId,
      {required String nativeGeneratorIdentity,
      PatrolSdkArtifactReceipt? sdkReceipt,
      PatrolSelectionPlan? sdkSelection,
      String? sdkBuildIdentity}) {
    final data = <String, dynamic>{
      'app': appId,
      'test': testId,
      'nativeGenerator': nativeGeneratorIdentity,
      if (sdkReceipt != null) 'sdkReceipt': sdkReceipt.toJson(),
    };
    final reason = _sdkCacheFailure(data, sdkSelection, sdkBuildIdentity);
    if (reason != null) {
      throw StateError(reason);
    }
    ltFileSystem.writeAsStringSync(
      filePath: cachePath,
      newContent: jsonEncode(data),
    );
  }
}

String? _sdkCacheFailure(Map<String, dynamic> cache, PatrolSelectionPlan? selection, String? buildIdentity) {
  if (!cache.containsKey('sdkReceipt') && selection == null && buildIdentity == null) {
    return null;
  }
  if (selection == null || buildIdentity == null) {
    return 'SDK-bound uploads require a current selection and complete build identity; rebuild.';
  }
  try {
    PatrolSdkArtifactReceipt.fromJson(cache['sdkReceipt']).validate(
      selection: selection,
      buildIdentity: buildIdentity,
      nativeGeneratorIdentity: cache['nativeGenerator'] as String,
      appId: cache['app'] as String,
      testId: cache['test'] as String,
    );
    return null;
    // Prepared-plan validation uses StateError for stale evidence; report cache refusal.
    // ignore: avoid_catching_errors
  } on StateError catch (error) {
    return error.message.toString();
  }
}

void _reportSdkFailure(String reason, void Function(String)? onSdkInvalid, void Function() onIncomplete) {
  if (onSdkInvalid != null) {
    onSdkInvalid(reason);
  } else {
    onIncomplete();
  }
}
