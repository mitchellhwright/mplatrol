import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/lt_app_upload.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _Uploader with LtAppUpload {
  _Uploader([LtUploadPolicy? policy]) : uploadPolicy = policy ?? instantLtUploadPolicy;

  @override
  final LtUploadPolicy uploadPolicy;
}

const _ok = '{"app_url": "lt://APP"}';
const _leg = ItRunLeg(tenant: 'demo', environment: 'QA', variant: 'lt-ios');
const _test = ItSelectedTest(id: 'pinnedsdk', file: 'pinnedsdk_registration_journey_test', description: 'registers');

void main() {
  late Directory temp;
  late LtHttp ltHttp;
  late MplatrolLogger logger;
  late Map<String, String> environment;

  Future<http.Response> upload() => ltHttp.postMultipart(
        any(),
        headers: any(named: 'headers'),
        fields: any(named: 'fields'),
        filePath: any(named: 'filePath'),
        onAnswered: any(named: 'onAnswered'),
      );

  void answer(List<http.Response> responses) {
    var call = 0;
    when(upload).thenAnswer((_) async => responses[min(call++, responses.length - 1)]);
  }

  Future<String> run({String name = 'demo-app', String? file, LtUploadPolicy? policy}) => _Uploader(policy)
      .uploadLtApp(file: file ?? p.join(temp.path, 'missing.ipa'), name: name, headers: const {'Authorization': 'x'});

  setUp(() async {
    await scaffoldMockDependencies();
    temp = Directory.systemTemp.createTempSync('lt_app_upload_test');
    ltHttp = getDep<LtHttp>();
    logger = getDep<MplatrolLogger>();
    environment = {};
    when(() => getDep<PlatformWrapper>().environment).thenAnswer((_) => environment);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('LtUploadPolicy', () {
    test('six attempts wait about three minutes, longer each time', () {
      const policy = LtUploadPolicy();
      final waits = policy.attemptDelays.map((delay) => delay.inSeconds).toList();

      expect(policy.attempts, 6);
      expect(waits, [10, 20, 30, 45, 60]);
      expect(policy.retryDelay, const Duration(seconds: 60));
    });
  });

  test('the infrastructure retry is on unless the env var is 0', () {
    expect(ltInfraRetryEnabled({}), isTrue);
    expect(ltInfraRetryEnabled({e2eInfraRetryEnv: '1'}), isTrue);
    expect(ltInfraRetryEnabled({e2eInfraRetryEnv: ' 0 '}), isFalse);
  });

  group('uploadLtApp', () {
    test('returns the app id and logs the upload throughput', () async {
      final file = File(p.join(temp.path, 'Runner.ipa'))..writeAsBytesSync(List.filled(1500000, 0));
      when(upload).thenAnswer((invocation) async {
        final onAnswered = invocation.namedArguments[#onAnswered] as void Function(LtUploadStats);
        onAnswered(const LtUploadStats(
            bytes: 293000000, sending: Duration(seconds: 412), responseWait: Duration(seconds: 23)));
        return http.Response(_ok, 200);
      });

      expect(await run(file: file.path), 'lt://APP');

      verify(() => ltHttp.postMultipart(ltRealDeviceUploadUrl,
          headers: {'Authorization': 'x'},
          fields: {'name': 'demo-app'},
          filePath: file.path,
          onAnswered: any(named: 'onAnswered'))).called(1);
      verify(() => logger.info('LambdaTest upload of demo-app: 293.0 MB in 412 s (0.71 MB/s); LambdaTest answered '
          '23 s after the last byte.')).called(1);
      verifyNever(() => logger.warn(any()));
    });

    test('logs no throughput for a failed attempt that LambdaTest answered', () async {
      var call = 0;
      when(upload).thenAnswer((invocation) async {
        (invocation.namedArguments[#onAnswered] as void Function(LtUploadStats))(
            const LtUploadStats(bytes: 1000000, sending: Duration(seconds: 1), responseWait: Duration.zero));
        return call++ == 0 ? http.Response('upstream 502', 502) : http.Response(_ok, 200);
      });

      expect(await run(), 'lt://APP');

      verify(() => logger.info(any(that: startsWith('LambdaTest upload of demo-app: 1.0 MB')))).called(1);
    });

    test('accepts test_url when there is no app_url', () async {
      answer([http.Response('{"test_url": "lt://TEST"}', 200)]);

      expect(await run(), 'lt://TEST');
    });

    test('retries transport failures, 5xx and 429 after the policy waits, naming each failure', () async {
      answer([
        http.Response('transport failed: SocketException: Connection reset by peer\nmore', 599),
        http.Response('x' * 300, 503),
        http.Response('slow down', 429),
        http.Response(_ok, 200),
      ]);
      final policy = LtUploadPolicy(
          attemptDelays: [const Duration(seconds: 1), ...List.filled(4, Duration.zero)], retryDelay: Duration.zero);

      expect(await run(policy: policy), 'lt://APP');

      verify(upload).called(4);
      verifyInOrder([
        () => logger.warn('LambdaTest upload of demo-app failed (HTTP 599: transport failed: SocketException: '
            'Connection reset by peer); retrying attempt 2/6 in 1s.'),
        () => logger.warn('LambdaTest upload of demo-app failed (HTTP 503: ${'x' * 200}...); retrying attempt '
            '3/6 in 0s.'),
        () => logger.warn('LambdaTest upload of demo-app failed (HTTP 429: slow down); retrying attempt 4/6 in 0s.'),
      ]);
    });

    test('a refusal fails at once without the infrastructure retry', () async {
      answer([http.Response('{"message": "Unauthorized"}', 401)]);

      await expectLater(
          run(),
          throwsA(isA<LtUploadFailure>().having((failure) => failure.retryable, 'retryable', isFalse).having(
              (failure) => '$failure',
              'message',
              'LambdaTest refused the upload of demo-app (HTTP 401): {"message": "Unauthorized"}')));
      verify(upload).called(1);
      verifyNever(() => logger.warn(any()));
    });

    test('uploads once more after every attempt failed, and fails when that fails too', () async {
      answer([http.Response('upstream 502', 502)]);

      await expectLater(
          run(),
          throwsA(isA<LtUploadFailure>().having((failure) => failure.retryable, 'retryable', isTrue).having(
              (failure) => failure.message,
              'message',
              'LambdaTest upload of demo-app failed after 6 attempts (HTTP 502): upstream 502')));
      verify(upload).called(12);
      verify(() => logger.warn('[retry] LambdaTest upload of demo-app: all 6 attempts failed; uploading it once '
          'more in 0s after a LambdaTest infrastructure failure; only the retry is reported.')).called(1);
    });

    test('the infrastructure retry returns the id its upload got', () async {
      answer([...List.filled(6, http.Response('', 599)), http.Response(_ok, 201)]);

      expect(await run(), 'lt://APP');
      verify(upload).called(7);
    });

    test('makes no infrastructure retry when the env var turns it off', () async {
      environment = {e2eInfraRetryEnv: '0'};
      answer([http.Response('<html>502</html>', 200)]);

      await expectLater(run(), throwsA(isA<LtUploadFailure>()));
      verify(upload).called(6);
      verifyNever(() => logger.warn(any(that: startsWith('[retry]'))));
    });
  });

  group('machine-wide upload cap', () {
    test('leases one upload from ~/.mplatrol/lt-uploads per attempt', () async {
      environment = {'HOME': temp.path};
      final uploads = Directory(p.join(temp.path, '.mplatrol', 'lt-uploads'));
      final leasesDuringUpload = <int>[];
      when(upload).thenAnswer((_) async {
        leasesDuringUpload.add(uploads.listSync().where((entity) => entity.path.endsWith('.lease')).length);
        return http.Response(_ok, 200);
      });

      expect(await run(), 'lt://APP');

      expect(leasesDuringUpload, [1]);
      expect(uploads.listSync().where((entity) => entity.path.endsWith('.lease')), isEmpty);
    });

    test('an upload waits while MPLATROL_LT_MAX_CONCURRENT_UPLOADS others run', () async {
      environment = {'HOME': temp.path, ltMaxConcurrentUploadsEnv: '1'};
      final release = Completer<void>();
      final waiting = Completer<void>();
      final started = <String>[];
      when(upload).thenAnswer((invocation) async {
        final name = (invocation.namedArguments[#fields] as Map<String, String>)['name']!;
        started.add(name);
        if (name == 'first') {
          await release.future;
        }
        return http.Response(_ok, 200);
      });
      when(() => logger.info(any(that: contains('waiting for')))).thenAnswer((_) {
        if (!waiting.isCompleted) {
          waiting.complete();
        }
      });

      final first = run(name: 'first');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = run(name: 'second');
      await waiting.future;

      expect(started, ['first']);
      verify(() => logger.info('[lt-uploads] second: waiting for 1 free LambdaTest app upload(s) of the '
          'machine-wide 1 ($ltMaxConcurrentUploadsEnv)')).called(1);
      release.complete();
      expect(await Future.wait([first, second]), ['lt://APP', 'lt://APP']);
      expect(started, ['first', 'second']);
    });

    for (final raw in ['0', 'three']) {
      test('refuses a cap of "$raw"', () async {
        environment = {ltMaxConcurrentUploadsEnv: raw};

        await expectLater(
            run(),
            throwsA(isA<LtUploadFailure>().having((failure) => failure.message, 'message',
                '$ltMaxConcurrentUploadsEnv must be a positive whole number of uploads (got "$raw").')));
        verifyNever(upload);
      });
    }
  });

  group('reportLtUploadFailure', () {
    Future<ItTestResult> reported(LtUploadFailure failure) async {
      final results = getDep<ItRunResults>();
      await results.withLeg(_leg, () async => _Uploader().reportLtUploadFailure(failure, repo: temp.path));
      results.endLeg(_leg, exitCode: 70, planned: () => [_test]);
      return results.resultsOf(_leg).single;
    }

    test("a failed upload ends the leg's tests as lt-failure, not not-run", () async {
      const message = 'LambdaTest upload of Runner.ipa failed after 6 attempts (HTTP 599): transport failed';

      final result = await reported(const LtUploadFailure(message, retryable: true));

      expect(result.category, ItResultCategory.ltFailure);
      verify(() => logger.err(message)).called(1);
      verify(() => logger.info(any(that: startsWith('lesson lambdaTestUpload (observed 1): ')))).called(1);
    });

    test('a refused upload stays not-run', () async {
      final result = await reported(
          const LtUploadFailure('LambdaTest refused the upload of Runner.ipa (HTTP 401): no', retryable: false));

      expect(result.category, ItResultCategory.notRun);
    });
  });
}
