import 'dart:convert';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;

/// Env var: `0` turns off the one automatic retry of a LambdaTest infrastructure failure: the tests it
/// (`lt-tunnel-err`, `lt-failure`) kept from a result (see `LtHyperexecuteRunner`) and an app upload that
/// still failed after its attempts (see [LtAppUpload.uploadLtApp]). On when unset.
const e2eInfraRetryEnv = 'MPLATROL_E2E_INFRA_RETRY';

/// Whether [environment] leaves the infrastructure retry of [e2eInfraRetryEnv] on.
bool ltInfraRetryEnabled(Map<String, String> environment) => (environment[e2eInfraRetryEnv] ?? '').trim() != '0';

/// LambdaTest realDevice app-upload endpoint.
const ltRealDeviceUploadUrl = 'https://manual-api.lambdatest.com/app/upload/realDevice';

/// Env var: the most LambdaTest app uploads all `mplatrol run` processes of this user on this machine send
/// at once (see [LtAppUpload.uploadLtApp]).
const ltMaxConcurrentUploadsEnv = 'MPLATROL_LT_MAX_CONCURRENT_UPLOADS';

/// Default [ltMaxConcurrentUploadsEnv]: a matrix round starts about 17 legs whose 150-300 MB uploads at the
/// same moment saturated the uplink (r12: uploads took up to 274 s, then resets and timeouts); three at a
/// time keep each one fast.
const ltDefaultMaxConcurrentUploads = 3;

/// How a LambdaTest app upload retries (see [LtAppUpload.uploadLtApp]).
class LtUploadPolicy {
  /// Production waits unless a test passes its own.
  const LtUploadPolicy({
    this.attemptDelays = defaultAttemptDelays,
    this.retryDelay = defaultRetryDelay,
    this.capPollInterval = const Duration(seconds: 5),
  });

  /// The waits between the attempts of one upload: six attempts with about three minutes of growing backoff,
  /// so a network blip of a few minutes (r12: four connection resets in 190 s) does not lose the leg.
  static const defaultAttemptDelays = [
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 45),
    Duration(seconds: 60),
  ];

  /// The wait before the one infrastructure retry of an upload whose attempts all failed.
  static const defaultRetryDelay = Duration(seconds: 60);

  /// The wait after each failed attempt but the last; one more attempt than waits is made.
  final List<Duration> attemptDelays;

  /// The wait before the infrastructure retry.
  final Duration retryDelay;

  /// How often an upload waiting for a free place under [ltMaxConcurrentUploadsEnv] checks again.
  final Duration capPollInterval;

  /// Attempts one upload makes before it fails.
  int get attempts => attemptDelays.length + 1;
}

/// A LambdaTest app upload that failed: [retryable] when LambdaTest or the network failed (transport errors,
/// HTTP 429 and 5xx), not when LambdaTest refused it (another 4xx, e.g. bad credentials).
class LtUploadFailure implements Exception {
  /// The failure [message] names the artifact, the attempts and the last response.
  const LtUploadFailure(this.message, {required this.retryable});

  /// What failed, for the log; a retryable failure is recognized as lesson [TestLesson.lambdaTestUpload].
  final String message;

  /// Whether the failure is LambdaTest's or the network's rather than a refusal.
  final bool retryable;

  @override
  String toString() => message;
}

/// The direct LambdaTest app upload both LambdaTest runners share: retried with backoff, then retried once
/// more as an infrastructure failure, and reported as `lt-failure` when even that fails.
mixin LtAppUpload {
  /// How uploads retry; the host runner provides it (zero waits in tests).
  LtUploadPolicy get uploadPolicy;

  MplatrolLogger get _uploadLogger => getDep<MplatrolLogger>();

  /// Uploads [file] to LambdaTest as [name] with the auth [headers] and returns its `lt://` app id.
  ///
  /// Each upload makes [LtUploadPolicy.attempts] attempts with the policy's growing waits, retrying transport
  /// failures (`599`, including an attempt [LtHttp.postMultipart] aborted because it stopped making progress
  /// under [LtUploadLimits]), HTTP 429, 5xx and a success without an app id. Each successful upload logs its
  /// size, duration and MB/s. When they all fail and [e2eInfraRetryEnv] leaves the infrastructure retry on,
  /// the upload runs once more after [LtUploadPolicy.retryDelay]. Throws [LtUploadFailure] when it still fails,
  /// or at once when LambdaTest refuses the upload (another 4xx).
  Future<String> uploadLtApp({
    required String file,
    required String name,
    required Map<String, String> headers,
  }) async {
    try {
      return await _uploadAttempts(file: file, name: name, headers: headers);
    } on LtUploadFailure catch (failure) {
      if (!failure.retryable || !ltInfraRetryEnabled(getDep<PlatformWrapper>().environment)) {
        rethrow;
      }
      _uploadLogger.warn('[retry] LambdaTest upload of $name: all ${uploadPolicy.attempts} attempts failed; '
          'uploading it once more in ${uploadPolicy.retryDelay.inSeconds}s after a LambdaTest infrastructure '
          'failure; only the retry is reported.');
      await Future<void>.delayed(uploadPolicy.retryDelay);
    }
    return _uploadAttempts(file: file, name: name, headers: headers);
  }

  /// Logs [failure] and, when it is LambdaTest's or the network's, records lesson
  /// [TestLesson.lambdaTestUpload] so the leg's tests end `lt-failure` rather than `not-run`.
  void reportLtUploadFailure(LtUploadFailure failure, {required String repo}) {
    _uploadLogger.err(failure.message);
    reportTestLessons(failure.message, repo: repo, logger: _uploadLogger);
  }

  Future<String> _uploadAttempts({
    required String file,
    required String name,
    required Map<String, String> headers,
  }) async {
    final attempts = uploadPolicy.attempts;
    final budget = _uploadBudget();
    for (var attempt = 1;; attempt++) {
      final lease = await budget?.acquire(wanted: 1, label: name);
      LtUploadStats? stats;
      final response = await getDep<LtHttp>()
          .postMultipart(ltRealDeviceUploadUrl,
              headers: headers, fields: {'name': name}, filePath: file, onAnswered: (answered) => stats = answered)
          .whenComplete(() => lease?.release());
      final status = response.statusCode;
      final appId = status < 400 ? _appId(response.body) : null;
      if (appId != null) {
        _logThroughput(name, stats);
        return appId;
      }
      if (status >= 400 && status != 429 && status < 500) {
        throw LtUploadFailure('LambdaTest refused the upload of $name (HTTP $status): ${response.body}',
            retryable: false);
      }
      if (attempt >= attempts) {
        throw LtUploadFailure(
            'LambdaTest upload of $name failed after $attempts attempts (HTTP $status): ${response.body}',
            retryable: true);
      }
      final delay = uploadPolicy.attemptDelays[attempt - 1];
      _uploadLogger.warn('LambdaTest upload of $name failed (HTTP $status: ${_excerpt(response.body)}); '
          'retrying attempt ${attempt + 1}/$attempts in ${delay.inSeconds}s.');
      await Future<void>.delayed(delay);
    }
  }

  /// The machine-wide cap on concurrent uploads ([ltMaxConcurrentUploadsEnv]) under
  /// `~/.mplatrol/lt-uploads`; null without a `HOME`, where there is no per-user place to share it.
  LtSlotBudget? _uploadBudget() {
    final environment = getDep<PlatformWrapper>().environment;
    final raw = (environment[ltMaxConcurrentUploadsEnv] ?? '').trim();
    final limit = raw.isEmpty ? ltDefaultMaxConcurrentUploads : int.tryParse(raw);
    if (limit == null || limit < 1) {
      throw LtUploadFailure('$ltMaxConcurrentUploadsEnv must be a positive whole number of uploads (got "$raw").',
          retryable: false);
    }
    final home = environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }
    return LtSlotBudget(
      directory: p.join(home, '.mplatrol', 'lt-uploads'),
      limit: limit,
      logger: _uploadLogger,
      tag: 'lt-uploads',
      unit: 'LambdaTest app upload(s)',
      limitSource: ' ($ltMaxConcurrentUploadsEnv)',
      pollInterval: uploadPolicy.capPollInterval,
    );
  }

  /// One line per successful upload with its size, duration and throughput, so a round's log shows what the
  /// uplink really delivers.
  void _logThroughput(String name, LtUploadStats? stats) {
    if (stats != null) {
      _uploadLogger.info('LambdaTest upload of $name: ${stats.describe()}.');
    }
  }

  /// The first line of a failed response [body], at most 200 characters, e.g. the transport error.
  String _excerpt(String body) {
    final line = body.trim().split('\n').first;
    return line.length > 200 ? '${line.substring(0, 200)}...' : line;
  }

  String? _appId(String body) {
    try {
      final decoded = jsonDecode(body);
      final appId = decoded is Map ? decoded['app_url'] ?? decoded['test_url'] : null;
      return appId is String && appId.isNotEmpty ? appId : null;
    } on FormatException {
      return null;
    }
  }
}
