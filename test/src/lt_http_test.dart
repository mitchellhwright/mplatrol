import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:test/test.dart';

/// A client that, like `IOClient`, pulls the request body as the socket drains it and ends an abortable
/// request when its trigger completes: it takes the next body chunk [perChunk] after the last, stops pulling
/// after [stallAfterChunks] chunks, and answers [answerAfter] after the last byte (never when null).
class _PacedClient extends http.BaseClient {
  _PacedClient({this.perChunk = Duration.zero, this.stallAfterChunks, this.answerAfter = Duration.zero});

  final Duration perChunk;
  final int? stallAfterChunks;
  final Duration? answerAfter;
  bool aborted = false;
  int chunks = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final response = Completer<http.StreamedResponse>();
    final timers = <Timer>[];
    final body = request.finalize().listen(null);
    body
      ..onData((_) {
        body.pause();
        if (++chunks != stallAfterChunks) {
          timers.add(Timer(perChunk, body.resume));
        }
      })
      ..onDone(() {
        if (answerAfter case final wait?) {
          timers.add(Timer(wait, () => response.complete(http.StreamedResponse(Stream.value(utf8.encode('ok')), 200))));
        }
      });
    unawaited((request as http.Abortable).abortTrigger!.then((_) {
      aborted = true;
      for (final timer in timers) {
        timer.cancel();
      }
      unawaited(body.cancel());
      response.completeError(http.RequestAbortedException(request.url));
    }));
    return response.future;
  }
}

/// Ten 1 MB fields: a multipart body of about 10 MB in 41 chunks (separator, header, value and line break per
/// field, then the closing boundary).
final _tenMegabytes = {for (var i = 0; i < 10; i++) 'part$i': 'x' * 1000000};

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lt_http_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String headerOf(http.Request request, String name) =>
      request.headers.entries.firstWhere((entry) => entry.key.toLowerCase() == name).value;

  group('basic auth', () {
    test('basicAuthRaw encodes credentials as Basic base64', () {
      expect(LtHttp().basicAuthRaw('u:k'), {'Authorization': 'Basic ${base64Encode(utf8.encode('u:k'))}'});
    });

    test('basicAuth joins user + key', () {
      expect(LtHttp().basicAuth('u', 'k'), LtHttp().basicAuthRaw('u:k'));
    });
  });

  test('GET sends the headers and returns the response', () async {
    late http.Request seen;
    final lt = LtHttp(
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"ok":1}', 200);
      }),
    );

    final res = await lt.get('https://lt/builds/1', headers: const {'Authorization': 'Basic x'});

    expect(res.statusCode, 200);
    expect(res.body, '{"ok":1}');
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'https://lt/builds/1');
    expect(headerOf(seen, 'authorization'), 'Basic x');
  });

  test('GET turns a timeout into a synthetic 599', () async {
    final lt = LtHttp(
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('late', 200);
      }),
    );

    final res = await lt.get('https://lt/slow', headers: const {}, timeout: const Duration(milliseconds: 20));

    expect(res.statusCode, 599);
  });

  test('POST JSON adds the content-type and encoded body', () async {
    late http.Request seen;
    final lt = LtHttp(
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"buildId":"b"}', 200);
      }),
    );

    final res = await lt.postJson('https://lt/build', headers: const {'Authorization': 'Basic x'}, body: {'a': 1});

    expect(res.body, '{"buildId":"b"}');
    expect(seen.method, 'POST');
    expect(headerOf(seen, 'content-type'), contains('application/json'));
    expect(headerOf(seen, 'authorization'), 'Basic x');
    expect(seen.body, jsonEncode({'a': 1}));
  });

  test('PATCH JSON adds the content-type and encoded body', () async {
    late http.Request seen;
    final lt = LtHttp(
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"status":"success"}', 200);
      }),
    );

    final res = await lt.patchJson(
      'https://lt/session',
      headers: const {'Authorization': 'Basic x'},
      body: {'name': 'testA'},
    );

    expect(res.body, '{"status":"success"}');
    expect(seen.method, 'PATCH');
    expect(headerOf(seen, 'content-type'), contains('application/json'));
    expect(seen.body, jsonEncode({'name': 'testA'}));
  });

  test('multipart upload attaches fields and optional file', () async {
    final apk = File('${tempDir.path}/app.apk')..writeAsStringSync('APKBYTES');
    late http.Request seen;
    final lt = LtHttp(
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"app_url":"u"}', 200);
      }),
    );

    final res = await lt.postMultipart(
      'https://lt/upload',
      headers: const {'Authorization': 'Basic x'},
      fields: const {'name': 'n'},
      filePath: apk.path,
    );

    expect(res.statusCode, 200);
    expect(seen.method, 'POST');
    expect(headerOf(seen, 'content-type'), contains('multipart/form-data'));
    expect(headerOf(seen, 'authorization'), 'Basic x');
    expect(seen.body, contains('name="name"'));
    expect(seen.body, contains('name="appFile"'));
    expect(seen.body, contains('APKBYTES'));
  });

  test('PUT streams the file as the request body', () async {
    final apk = File('${tempDir.path}/app.apk')..writeAsStringSync('APPBYTES');
    late http.Request seen;
    final lt = LtHttp(
      client: MockClient((request) async {
        seen = request;
        return http.Response('', 201);
      }),
    );

    final res = await lt.putFile('https://gl/pkg', headers: const {'PRIVATE-TOKEN': 't'}, filePath: apk.path);

    expect(res.statusCode, 201);
    expect(seen.method, 'PUT');
    expect(headerOf(seen, 'private-token'), 't');
    expect(seen.body, 'APPBYTES');
    expect(seen.contentLength, 'APPBYTES'.length);
  });

  test('PUT surfaces transport failures as a synthetic 599', () async {
    final apk = File('${tempDir.path}/app.apk')..writeAsStringSync('APPBYTES');
    final lt = LtHttp(client: MockClient((_) async => throw const SocketException('Failure when receiving data')));

    final res = await lt.putFile('https://gl/pkg', headers: const {'PRIVATE-TOKEN': 't'}, filePath: apk.path);

    expect(res.statusCode, 599);
    expect(res.body, contains('Failure when receiving data'));
  });

  test('getToFile streams the body to disk and returns the status', () async {
    final outPath = '${tempDir.path}/out.bin';
    final lt = LtHttp(client: MockClient((_) async => http.Response('BLOB', 200)));

    final status = await lt.getToFile('https://gl/pkg/file', headers: const {}, outPath: outPath);

    expect(status, 200);
    expect(File(outPath).readAsStringSync(), 'BLOB');
  });

  test('getToFile returns 599 when the transport fails', () async {
    final lt = LtHttp(client: MockClient((_) async => throw const SocketException('refused')));

    final status = await lt.getToFile('https://gl/pkg/file', headers: const {}, outPath: '${tempDir.path}/out.bin');

    expect(status, 599);
  });

  test('decodes a body without a charset as UTF-8, not Latin-1', () async {
    const banner = '══╡ EXCEPTION CAUGHT ╞══';
    final lt = LtHttp(
      client: MockClient((_) async => http.Response.bytes(utf8.encode(banner), 200,
          headers: {'content-type': 'text/plain', 'x-request-id': 'r1'}, reasonPhrase: 'OK')),
    );

    final res = await lt.get('https://lt/log', headers: const {});

    expect(res.body, banner);
    expect(res.statusCode, 200);
    expect(res.headers['x-request-id'], 'r1');
    expect(res.headers['content-type'], 'text/plain; charset=utf-8');
  });

  test('decodes a body with no content type and keeps invalid bytes as replacement characters', () async {
    final lt = LtHttp(
      client: MockClient((_) async => http.Response.bytes([0x68, 0x69, 0xff], 200, headers: {})),
    );

    final res = await lt.get('https://lt/log', headers: const {});

    expect(res.body, 'hi\u{fffd}');
    expect(res.headers['content-type'], 'text/plain; charset=utf-8');
  });

  group('postMultipart watchdog', () {
    /// Runs [postMultipart] of [_tenMegabytes] with the production [LtUploadLimits] through [client] on a fake
    /// clock until it answers.
    (http.Response, LtUploadStats?, Duration) upload(_PacedClient client) {
      return fakeAsync((fake) {
        http.Response? response;
        LtUploadStats? stats;
        final lt = LtHttp(client: client, now: fake.getClock(DateTime(2026, 10, 27)).now);
        unawaited(lt
            .postMultipart('https://lt/upload',
                headers: const {}, fields: _tenMegabytes, onAnswered: (answered) => stats = answered)
            .then((answered) => response = answered));
        while (response == null) {
          fake.elapse(const Duration(seconds: 1));
        }
        return (response!, stats, fake.elapsed);
      });
    }

    test('a slow upload that keeps sending is not aborted, however long it takes', () {
      final client = _PacedClient(perChunk: const Duration(seconds: 40), answerAfter: const Duration(seconds: 20));

      final (response, stats, elapsed) = upload(client);

      expect(response.statusCode, 200);
      expect(client.aborted, isFalse);
      expect(elapsed, const Duration(seconds: 41 * 40 + 20));
      expect(stats!.bytes, greaterThan(10000000));
      expect(stats.sending, const Duration(seconds: 41 * 40));
      expect(stats.responseWait, const Duration(seconds: 20));
    });

    test('aborts an upload that sent nothing for the stall window, naming how far it got', () {
      final client = _PacedClient(perChunk: const Duration(seconds: 5), stallAfterChunks: 12);

      final (response, stats, elapsed) = upload(client);

      expect(client.aborted, isTrue);
      expect(stats, isNull);
      expect(elapsed, const Duration(seconds: 5 * 11 + 60));
      expect(response.statusCode, 599);
      expect(
          response.body,
          'transport failed: TimeoutException: LambdaTest upload stalled: no bytes sent for 60 s after 3.0 MB of '
          '10.0 MB; request aborted');
    });

    test('aborts an upload LambdaTest does not answer within the window after the last byte', () {
      final client = _PacedClient(answerAfter: null);

      final (response, _, elapsed) = upload(client);

      expect(client.aborted, isTrue);
      expect(elapsed, const Duration(minutes: 5));
      expect(
          response.body,
          'transport failed: TimeoutException: LambdaTest upload got no response 300 s after the upload of '
          '10.0 MB completed; request aborted');
    });

    test('an answer within the window after the last byte is returned with what the upload took', () {
      final client = _PacedClient(perChunk: const Duration(seconds: 1), answerAfter: const Duration(minutes: 2));

      final (response, stats, _) = upload(client);

      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(stats!.sending, const Duration(seconds: 41));
      expect(stats.responseWait, const Duration(minutes: 2));
      expect(stats.describe(), '10.0 MB in 41 s (0.24 MB/s); LambdaTest answered 120 s after the last byte');
    });

    test('aborts an upload that is still progressing at the hard cap', () {
      final client = _PacedClient(perChunk: const Duration(seconds: 59));

      final (response, _, elapsed) = upload(client);

      expect(client.aborted, isTrue);
      expect(elapsed, const Duration(minutes: 30));
      expect(
          response.body,
          startsWith('transport failed: TimeoutException: LambdaTest upload hit the 30 min hard cap '
              'after '));
      expect(response.body, endsWith(' MB of 10.0 MB; request aborted'));
    });

    test('the hard cap names an upload that already sent every byte', () {
      final client = _PacedClient(answerAfter: null);

      final response = fakeAsync((fake) {
        http.Response? answered;
        unawaited(LtHttp(client: client)
            .postMultipart('https://lt/upload',
                headers: const {},
                fields: _tenMegabytes,
                limits: const LtUploadLimits(responseWait: Duration(minutes: 10), hardCap: Duration(minutes: 5)))
            .then((response) => answered = response));
        fake.elapse(const Duration(minutes: 5));
        return answered;
      });

      expect(
          response!.body,
          'transport failed: TimeoutException: LambdaTest upload hit the 5 min hard cap after the upload of 10.0 MB '
          'completed; request aborted');
    });

    test('an answer before the body is sent counts no response wait', () {
      final lt = LtHttp(
        client: MockClient((_) async => http.Response('{"message":"Unauthorized"}', 401)),
        now: () => DateTime(2026, 10, 27),
      );
      LtUploadStats? stats;

      return lt
          .postMultipart('https://lt/upload', headers: const {}, onAnswered: (answered) => stats = answered)
          .then((response) {
        expect(response.statusCode, 401);
        expect(stats!.responseWait, Duration.zero);
      });
    });

    group('over a real socket', () {
      late HttpServer server;
      late LtHttp lt;
      const quick = LtUploadLimits(
        stall: Duration(milliseconds: 300),
        responseWait: Duration(milliseconds: 300),
        hardCap: Duration(seconds: 20),
      );

      setUp(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        lt = LtHttp(client: http.Client());
      });

      tearDown(() => server.close(force: true));

      Future<http.Response> post(Map<String, String> fields) =>
          lt.postMultipart('http://127.0.0.1:${server.port}/upload', headers: const {}, fields: fields, limits: quick);

      test('aborts once a peer that stopped reading lets the socket fill up', () async {
        server.listen((request) => request.listen(null).pause());
        final big = {for (var i = 0; i < 64; i++) 'part$i': 'x' * 1000000};

        final response = await post(big);

        expect(response.statusCode, 599);
        expect(response.body, contains('LambdaTest upload stalled: no bytes sent for 0 s after '));
        expect(response.body, contains(' MB of 64.0 MB; request aborted'));
      });

      test('aborts a request whose body went out but that gets no answer', () async {
        server.listen((request) => request.drain<void>());

        final response = await post(const {'name': 'n'});

        expect(response.body, contains('LambdaTest upload got no response 0 s after the upload of 0.0 MB completed'));
      });

      test('returns an answer that arrives in time', () async {
        server.listen((request) async {
          await request.drain<void>();
          request.response.write('{"app_url":"lt://A"}');
          await request.response.close();
        });

        final response = await post(_tenMegabytes);

        expect(response.body, '{"app_url":"lt://A"}');
      });
    });

    test('describes an upload that took no time without a rate', () {
      const stats = LtUploadStats(bytes: 293000000, sending: Duration.zero, responseWait: Duration(seconds: 3));

      expect(stats.describe(), '293.0 MB in 0 s (- MB/s); LambdaTest answered 3 s after the last byte');
    });
  });
}
