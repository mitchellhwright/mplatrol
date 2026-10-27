import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_session_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _api = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/sessions';
const _env = {'LT_USERNAME': 'user', 'LT_ACCESS_KEY': 'key'};

void main() {
  late LtHttp ltHttp;
  late String outPath;
  final artifacts = LtSessionArtifacts();

  void stubGet(String url, String body, [int status = 200]) => when(
        () => ltHttp.get(url, headers: any(named: 'headers'), timeout: any(named: 'timeout')),
      ).thenAnswer((_) async => http.Response(body, status));

  void stubDownload(int status, {String content = 'mp4'}) =>
      when(() => ltHttp.getToFile(any(), headers: any(named: 'headers'), outPath: any(named: 'outPath')))
          .thenAnswer((invocation) async {
        File(invocation.namedArguments[#outPath] as String).writeAsStringSync(content);
        return status;
      });

  setUp(() async {
    await scaffoldMockDependencies();
    ltHttp = getDep<LtHttp>();
    outPath = p.join(Directory.systemTemp.createTempSync('lt_video').path, 'video.mp4');
  });

  group('session', () {
    test('returns the session data, authenticated with the LambdaTest credentials', () async {
      stubGet('$_api/S1', '{"data":{"device":"Pixel 9"}}');

      expect(await artifacts.session('S1', _env), {'device': 'Pixel 9'});
      verify(() => ltHttp.basicAuth('user', 'key')).called(1);
    });

    test('is null for an error, a non-JSON body or a missing data object', () async {
      stubGet('$_api/S1', 'nope', 404);
      expect(await artifacts.session('S1', _env), isNull);
      stubGet('$_api/S1', 'not json');
      expect(await artifacts.session('S1', _env), isNull);
      stubGet('$_api/S1', '{"data":[]}');
      expect(await artifacts.session('S1', _env), isNull);
    });
  });

  test('instrumentationLog returns the log, or empty when it is unavailable', () async {
    stubGet('$_api/S1/log/instrumentation', 'log body');
    expect(await artifacts.instrumentationLog('S1', const {}), 'log body');
    stubGet('$_api/S1/log/instrumentation', 'missing', 404);
    expect(await artifacts.instrumentationLog('S1', const {}), '');
  });

  group('downloadVideo', () {
    test('downloads the signed video URL LambdaTest returns', () async {
      stubGet('$_api/S1/video', '{"url":"https://signed/video.mp4"}');
      stubDownload(200);

      expect(await artifacts.downloadVideo('S1', outPath, _env), isTrue);
      expect(File(outPath).readAsStringSync(), 'mp4');
      verify(() => ltHttp.getToFile('https://signed/video.mp4', headers: const {}, outPath: outPath)).called(1);
    });

    test('retries until the video is published', () async {
      var asks = 0;
      when(() => ltHttp.get('$_api/S1/video', headers: any(named: 'headers'), timeout: any(named: 'timeout')))
          .thenAnswer((_) async => ++asks < 3 ? http.Response('{}', 200) : http.Response('{"url":"u"}', 200));
      stubDownload(200);

      expect(await artifacts.downloadVideo('S1', outPath, _env), isTrue);
      expect(asks, 3);
    });

    test('gives up after the last attempt and leaves no partial file', () async {
      stubGet('$_api/S1/video', '{"url":"u"}');
      stubDownload(403, content: 'AccessDenied');

      expect(await artifacts.downloadVideo('S1', outPath, _env), isFalse);
      expect(File(outPath).existsSync(), isFalse);
      verify(() => ltHttp.getToFile('u', headers: const {}, outPath: outPath)).called(LtSessionArtifacts.videoAttempts);
    });

    test('fails when LambdaTest has no video for the session', () async {
      stubGet('$_api/S1/video', 'not found', 404);

      expect(await artifacts.downloadVideo('S1', outPath, _env), isFalse);
      verifyNever(() => ltHttp.getToFile(any(), headers: any(named: 'headers'), outPath: any(named: 'outPath')));
    });

    test('treats an empty download as no video', () async {
      stubGet('$_api/S1/video', '{"url":"u"}');
      stubDownload(200, content: '');

      expect(await artifacts.downloadVideo('S1', outPath, _env), isFalse);
    });
  });
}
