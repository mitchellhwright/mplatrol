import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The App Automation test page of [sessionId]: video, screenshots, device and network logs. With the
/// session's [buildId] it opens on the logs tab; without it LambdaTest still finds the session.
String ltTestPageUrl(String sessionId, {String? buildId}) => buildId == null || buildId.isEmpty
    ? 'https://appautomation.lambdatest.com/test?testID=$sessionId'
    : 'https://appautomation.lambdatest.com/test?build=$buildId&testID=$sessionId&selectedTab=logs';

/// The App Automation build page of the HyperExecute job [jobId], the link the HyperExecute CLI prints
/// as `Build Link:`.
String ltBuildPageUrl(String jobId) => 'https://appautomation.lambdatest.com/build?jobid=$jobId';

/// The HyperExecute job page of [jobId]: its devices, stages and logs, live while the job runs.
String hyperexecuteJobPageUrl(String jobId) => 'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=$jobId';

/// The id of the HyperExecute job a CLI log names, from the last `Build Link:` line in [text], or null.
String? hyperexecuteJobIdIn(String text) => RegExp(
      r'Build Link: https://appautomation\.lambdatest\.com/build\?jobid=([a-fA-F0-9-]{36})',
    ).allMatches(text).lastOrNull?.group(1);

/// The id of the job named by the CLI log at [path] after byte [offset] (this run only), or null when the
/// file is missing, has no new text or names no job yet.
String? hyperexecuteJobIdInLog(String path, int offset) {
  final file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  final bytes = file.readAsBytesSync();
  if (bytes.length <= offset) {
    return null;
  }
  return hyperexecuteJobIdIn(utf8.decode(bytes.sublist(offset), allowMalformed: true));
}

/// Calls [onJob] once with the job id as soon as the HyperExecute CLI log at [cliLogPath] (text after byte
/// [cliLogOffset]) names it, checking every [every]; returns when it did or when [done] completes.
Future<void> announceHyperexecuteJob({
  required String cliLogPath,
  required int cliLogOffset,
  required Future<void> done,
  required void Function(String jobId) onJob,
  Duration every = const Duration(seconds: 2),
}) async {
  var finished = false;
  unawaited(done.whenComplete(() => finished = true));
  while (!finished) {
    final jobId = hyperexecuteJobIdInLog(cliLogPath, cliLogOffset);
    if (jobId != null) {
      onJob(jobId);
      return;
    }
    final wake = Completer<void>();
    final timer = Timer(every, wake.complete);
    await Future.any([wake.future, done]).whenComplete(timer.cancel);
  }
}
