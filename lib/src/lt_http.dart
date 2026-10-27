import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thin HTTP transport for the LambdaTest + GitLab REST calls.
///
/// Every method resolves to an [http.Response]; transport-level failures
/// (DNS, TLS, timeouts, unreadable files) come back as a synthetic `599`
/// response instead of an exception, so the runners branch on `statusCode`
/// uniformly — upload retry loops treat them like any other failed attempt.
class LtHttp {
  /// [now] tells the time of uploads (see [postMultipart]); tests pass a fake clock.
  LtHttp({http.Client? client, DateTime Function()? now})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _now;

  /// Basic-auth header from a pre-joined `user:key` string.
  Map<String, String> basicAuthRaw(String credentials) => {
        'Authorization': 'Basic ${base64Encode(utf8.encode(credentials))}',
      };

  /// Basic-auth header for the LambdaTest API from separate user + key.
  Map<String, String> basicAuth(String user, String key) => basicAuthRaw('$user:$key');

  /// GET [url] with [headers], bounded by [timeout].
  Future<http.Response> get(
    String url, {
    required Map<String, String> headers,
    Duration timeout = const Duration(seconds: 25),
  }) =>
      _guard(() => _client.get(Uri.parse(url), headers: headers).timeout(timeout));

  /// POST a JSON [body] to [url] with [headers].
  Future<http.Response> postJson(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) =>
      _guard(
        () => _client.post(Uri.parse(url),
            headers: {'Content-Type': 'application/json', ...headers}, body: jsonEncode(body)),
      );

  /// PATCH a JSON [body] to [url] with [headers].
  Future<http.Response> patchJson(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) =>
      _guard(
        () => _client.patch(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json', ...headers},
          body: jsonEncode(body),
        ),
      );

  /// POST a multipart form to [url]: [fields] plus an optional file at [filePath] under the `appFile` part.
  ///
  /// The request is aborted, so it stops using the uplink, only when it stops making progress: no body bytes
  /// went out for [LtUploadLimits.stall], LambdaTest has not answered [LtUploadLimits.responseWait] after the
  /// last byte, or the whole request ran past [LtUploadLimits.hardCap]. A slow upload that keeps sending is
  /// never cut short. An aborted request comes back as a `599` naming which limit fired and how far the upload
  /// got. [onAnswered] hears what an answered request sent and how long it took.
  Future<http.Response> postMultipart(
    String url, {
    required Map<String, String> headers,
    Map<String, String> fields = const {},
    String? filePath,
    LtUploadLimits limits = const LtUploadLimits(),
    void Function(LtUploadStats stats)? onAnswered,
  }) =>
      _guard(() async {
        final watchdog = _UploadWatchdog(limits, _now);
        final request = _WatchedMultipartRequest(Uri.parse(url), watchdog)
          ..headers.addAll(headers)
          ..fields.addAll(fields);
        try {
          if (filePath != null) {
            request.files.add(await http.MultipartFile.fromPath('appFile', filePath));
          }
          watchdog.start(request.contentLength);
          final response = await http.Response.fromStream(await _client.send(request));
          onAnswered?.call(watchdog.answered());
          return response;
        } on http.RequestAbortedException {
          throw TimeoutException(watchdog.abortReason);
        } finally {
          watchdog.cancel();
        }
      });

  /// PUT the file at [filePath] to [url] with [headers], streaming the body
  /// (LT app uploads run to hundreds of MB — never buffer them in memory).
  Future<http.Response> putFile(String url, {required Map<String, String> headers, required String filePath}) =>
      _guard(() async {
        final file = File(filePath);
        final request = http.StreamedRequest('PUT', Uri.parse(url))
          ..headers.addAll(headers)
          ..contentLength = file.lengthSync();
        unawaited(_feedSink(file, request.sink));
        return http.Response.fromStream(await _client.send(request));
      });

  /// GET [url] streaming the body straight to [outPath] (for large binaries
  /// that must not be buffered in memory). Returns the HTTP status code.
  Future<int> getToFile(String url, {required Map<String, String> headers, required String outPath}) async {
    try {
      final request = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
      final response = await _client.send(request);
      final sink = File(outPath).openWrite();
      try {
        await sink.addStream(response.stream);
      } finally {
        await sink.close();
      }
      return response.statusCode;
    } on Exception {
      return 599;
    }
  }

  /// Pipes [file] into [sink], always closing it. A read failure shows up on
  /// the in-flight request as a body shorter than its content-length, so the
  /// error reaches the caller through `send()` rather than from here.
  Future<void> _feedSink(File file, StreamSink<List<int>> sink) async {
    try {
      await sink.addStream(file.openRead());
    } catch (_) {
      /* surfaced via the in-flight request */
    } finally {
      try {
        await sink.close();
      } catch (_) {
        /* the request already failed */
      }
    }
  }

  Future<http.Response> _guard(Future<http.Response> Function() send) async {
    try {
      return _decodedAsUtf8(await send());
    } on Exception catch (error) {
      return http.Response('transport failed: $error', 599);
    }
  }

  /// [response] with its body decoded as UTF-8. `package:http` decodes a body whose Content-Type names no
  /// charset as Latin-1, which turns every multi-byte character of a LambdaTest log into mojibake (the box
  /// drawing of Flutter's `EXCEPTION CAUGHT` banner became `âââ¡`).
  static http.Response _decodedAsUtf8(http.Response response) {
    final mediaType = (response.headers['content-type'] ?? 'text/plain').split(';').first.trim();
    return http.Response.bytes(
      utf8.encode(utf8.decode(response.bodyBytes, allowMalformed: true)),
      response.statusCode,
      request: response.request,
      headers: {...response.headers, 'content-type': '$mediaType; charset=utf-8'},
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

/// When [LtHttp.postMultipart] gives up on an upload: only once it stops making progress.
class LtUploadLimits {
  /// Production limits unless a test passes its own.
  const LtUploadLimits({
    this.stall = const Duration(seconds: 60),
    this.responseWait = const Duration(minutes: 5),
    this.hardCap = const Duration(minutes: 30),
  });

  /// How long the upload may send no body bytes at all (including connecting) before it is aborted. A healthy
  /// upload on a shared uplink sends some bytes every few seconds, however slow it is overall.
  final Duration stall;

  /// How long LambdaTest may take to answer after the last body byte went out: it reads and processes the app
  /// before it answers, and an upload aborted here wasted every byte, so this is generous.
  final Duration responseWait;

  /// The backstop on the whole request, however steadily it progresses (a 300 MB app at 0.2 MB/s takes 25
  /// minutes).
  final Duration hardCap;
}

/// What an answered [LtHttp.postMultipart] request sent and how long it took.
class LtUploadStats {
  /// [bytes] of request body sent in [sending]; LambdaTest answered [responseWait] after the last byte.
  const LtUploadStats({required this.bytes, required this.sending, required this.responseWait});

  /// Request body bytes sent.
  final int bytes;

  /// From the start of the request to the last body byte.
  final Duration sending;

  /// From the last body byte to LambdaTest's complete answer.
  final Duration responseWait;

  /// One line for the log, e.g. `293.0 MB in 412 s (0.71 MB/s); LambdaTest answered 23 s after the last byte`.
  String describe() {
    final seconds = sending.inMilliseconds / 1000;
    final rate = seconds == 0 ? '-' : (bytes / 1000000 / seconds).toStringAsFixed(2);
    return '${_megabytes(bytes)} in ${seconds.round()} s ($rate MB/s); LambdaTest answered '
        '${responseWait.inSeconds} s after the last byte';
  }
}

String _megabytes(int bytes) => '${(bytes / 1000000).toStringAsFixed(1)} MB';

/// A multipart request whose body reports each chunk handed to the client (the socket pulls it, so this
/// tracks bytes going out) to [_watchdog], and is aborted when the watchdog fires.
class _WatchedMultipartRequest extends http.MultipartRequest with http.Abortable {
  _WatchedMultipartRequest(Uri url, this._watchdog) : super('POST', url);

  final _UploadWatchdog _watchdog;

  @override
  Future<void> get abortTrigger => _watchdog.fired;

  @override
  http.ByteStream finalize() => http.ByteStream(
        super.finalize().transform(
              StreamTransformer.fromHandlers(
                handleData: (chunk, sink) {
                  _watchdog.sent(chunk.length);
                  sink.add(chunk);
                },
                handleDone: (sink) {
                  _watchdog.allSent();
                  sink.close();
                },
              ),
            ),
      );
}

/// The timers of one [LtHttp.postMultipart] request (see [LtUploadLimits]); [fired] completes when one fires.
class _UploadWatchdog {
  _UploadWatchdog(this._limits, this._now);

  final LtUploadLimits _limits;
  final DateTime Function() _now;
  final _fired = Completer<void>();
  final _timers = <Timer>[];
  Timer? _stallTimer;
  int _total = 0;
  int _sent = 0;
  late DateTime _startedAt;
  DateTime? _allSentAt;

  /// Why the request was aborted, once [fired] completed.
  String abortReason = '';

  Future<void> get fired => _fired.future;

  /// Starts the stall and hard-cap timers for a request body of [total] bytes.
  void start(int total) {
    _total = total;
    _startedAt = _now();
    _timers.add(
      Timer(_limits.hardCap, () => _fire('hit the ${_limits.hardCap.inMinutes} min hard cap ${_progress()}')),
    );
    _armStall();
  }

  /// [bytes] more of the body went out.
  void sent(int bytes) {
    _sent += bytes;
    _armStall();
  }

  /// The last body byte went out: LambdaTest now has [LtUploadLimits.responseWait] to answer.
  void allSent() {
    _stallTimer?.cancel();
    _allSentAt = _now();
    _timers.add(
      Timer(_limits.responseWait, () => _fire('got no response ${_limits.responseWait.inSeconds} s ${_progress()}')),
    );
  }

  /// What the answered request sent and how long it took.
  LtUploadStats answered() {
    final answeredAt = _now();
    final allSentAt = _allSentAt ?? answeredAt;
    return LtUploadStats(
      bytes: _sent,
      sending: allSentAt.difference(_startedAt),
      responseWait: answeredAt.difference(allSentAt),
    );
  }

  void cancel() {
    _stallTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
  }

  void _armStall() {
    _stallTimer?.cancel();
    _stallTimer = Timer(
      _limits.stall,
      () => _fire('stalled: no bytes sent for ${_limits.stall.inSeconds} s ${_progress()}'),
    );
  }

  String _progress() => _allSentAt == null
      ? 'after ${_megabytes(_sent)} of ${_megabytes(_total)}'
      : 'after the upload of ${_megabytes(_sent)} completed';

  void _fire(String reason) {
    abortReason = 'LambdaTest upload $reason; request aborted';
    cancel();
    _fired.complete();
  }
}
