import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/lt_http.dart';

/// Reads one LambdaTest session's details, instrumentation log and video, for
/// bug drafts. Authenticates with LT_USERNAME / LT_ACCESS_KEY from the env.
class LtSessionArtifacts {
  static const _sessionsUrl = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/sessions';

  /// LambdaTest publishes a session's video shortly after it ends.
  static const videoAttempts = 3;

  LtHttp get _http => getDep<LtHttp>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  Map<String, String> _auth(Map<String, String> env) =>
      _http.basicAuth(env['LT_USERNAME'] ?? '', env['LT_ACCESS_KEY'] ?? '');

  /// The session's `data` object (device, version, name, ...), or null when
  /// LambdaTest does not return one.
  Future<Map<String, dynamic>?> session(String sessionId, Map<String, String> env) async {
    final response = await _http.get('$_sessionsUrl/$sessionId', headers: _auth(env));
    if (response.statusCode != 200) {
      return null;
    }
    final data = _jsonField(response.body, 'data');
    return data is Map<String, dynamic> ? data : null;
  }

  /// The session's instrumentation log, or '' when it is unavailable.
  Future<String> instrumentationLog(String sessionId, Map<String, String> env) async {
    final response = await _http.get('$_sessionsUrl/$sessionId/log/instrumentation',
        headers: _auth(env), timeout: const Duration(seconds: 30));
    return response.statusCode == 200 ? response.body : '';
  }

  /// Downloads the session video to [outPath]; true when a non-empty file was
  /// saved. Asks LambdaTest for the video's signed URL, retrying while the
  /// video is still being published.
  Future<bool> downloadVideo(String sessionId, String outPath, Map<String, String> env) async {
    for (var attempt = 1; attempt <= videoAttempts; attempt++) {
      final url = await _videoUrl(sessionId, env);
      if (url != null) {
        final status = await _http.getToFile(url, headers: const {}, outPath: outPath);
        final file = File(outPath);
        if (status == 200 && file.existsSync() && file.lengthSync() > 0) {
          return true;
        }
        _logger.detail('[bug-draft] video download for session $sessionId returned HTTP $status.');
      }
      if (attempt < videoAttempts) {
        await getDep<SleepFunction>()(const Duration(seconds: 10));
      }
    }
    final file = File(outPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
    return false;
  }

  Future<String?> _videoUrl(String sessionId, Map<String, String> env) async {
    final response = await _http.get('$_sessionsUrl/$sessionId/video', headers: _auth(env));
    if (response.statusCode != 200) {
      _logger.detail('[bug-draft] video URL for session $sessionId: HTTP ${response.statusCode}.');
      return null;
    }
    final url = _jsonField(response.body, 'url');
    return url is String && url.isNotEmpty ? url : null;
  }

  static Object? _jsonField(String body, String key) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded[key] : null;
    } on FormatException {
      return null;
    }
  }
}
