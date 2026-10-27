import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_hyperexecute_scenario_logs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _job = 'job-1';
const _headers = {'Authorization': 'Basic dGVzdDp0ZXN0'};
const _api = 'https://api.hyperexecute.cloud';
const _name = 'mplatrol.e2e.AccountSearchJourneyTest/PROJ_TC_7644_Account_Search';
const _file = 'mplatrol.e2e.AccountSearchJourneyTest-PROJ_TC_7644_Account_Search';

String _page(List<Map<String, Object?>> data, {String? cursor, bool hasMore = false}) => jsonEncode({
      'data': data,
      'metadata': {'total': data.length, 'cursor': cursor, 'hasmore': hasMore},
      'status': 'success',
    });

void main() {
  late Directory work;
  late Directory scenarios;
  late Map<String, http.Response> responses;
  late List<(String, Map<String, String>)> requests;

  setUp(() async {
    await scaffoldMockDependencies();
    work = Directory.systemTemp.createTempSync('scenario_logs');
    scenarios = Directory(p.join(work.path, 'logs', _job, 'scenarios'))..createSync(recursive: true);
    responses = {};
    requests = [];
    when(() => getDep<LtHttp>().get(any(), headers: any(named: 'headers'))).thenAnswer((invocation) async {
      final url = invocation.positionalArguments.single as String;
      requests.add((url, invocation.namedArguments[#headers] as Map<String, String>));
      return responses[url] ?? http.Response('', 404);
    });
  });

  tearDown(() => work.deleteSync(recursive: true));

  File refused(String name) => File(p.join(scenarios.path, name))..writeAsStringSync(hyperexecuteAccessDenied);

  Future<void> refetch() => HyperexecuteScenarioLogs().refetch(workDir: work.path, jobId: _job, headers: _headers);

  String list(List<Map<String, Object?>> data, {String? cursor, bool hasMore = false}) =>
      _page(data, cursor: cursor, hasMore: hasMore);

  void answer(String url, String body, {int status = 200}) => responses[url] = http.Response(body, status);

  const listUrl = '$_api/v2.0/job/$_job/scenarios?limit=20';
  const stageUrl = '$_api/v1.0/stage/s1/logs';

  test('does nothing when the job has no scenario logs or none was refused', () async {
    scenarios.deleteSync();
    await refetch();
    scenarios.createSync();
    File(p.join(scenarios.path, 'ok')).writeAsStringSync('real log');
    File(p.join(scenarios.path, 'big')).writeAsStringSync('x' * 300);
    await refetch();
    expect(requests, isEmpty);
  });

  test('re-fetches the refused log through the Basic-auth log link and sends the account only to LambdaTest', () async {
    final log = refused(_file);
    refused('other');
    answer(
        listUrl,
        list([
          {'id': 's1', 'name': _name},
          {'id': 's2', 'name': 'not-refused'},
          {'id': 5, 'name': 'bad id'},
        ]));
    answer(stageUrl, jsonEncode({'data': 'https://mobile-api.lambdatest.com/logs/s1.txt'}));
    answer('https://mobile-api.lambdatest.com/logs/s1.txt', 'Dart test failed: Expected: true');

    await refetch();

    expect(log.readAsStringSync(), 'Dart test failed: Expected: true');
    expect(requests.map((request) => request.$1), [listUrl, stageUrl, 'https://mobile-api.lambdatest.com/logs/s1.txt']);
    expect(requests.every((request) => request.$2 == _headers), isTrue);
    verify(() => getDep<MplatrolLogger>().info(any(that: contains('re-fetched 1 of 2 scenario log(s)'))));
    verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('still missing'))));
  });

  test('a signed storage link gets no credentials', () async {
    final log = refused(_file);
    answer(
        listUrl,
        list([
          {'id': 's1', 'name': _name},
        ]));
    answer(stageUrl, jsonEncode({'data': 'https://storage.example.com/signed?sig=1'}));
    answer('https://storage.example.com/signed?sig=1', 'log body');

    await refetch();

    expect(log.readAsStringSync(), 'log body');
    expect(requests.last.$2, isEmpty);
  });

  test('follows the scenario list across pages and stops on a repeated cursor', () async {
    refused(_file);
    answer(
        listUrl,
        list([
          {'id': 'x', 'name': 'a'}
        ], cursor: 'c1', hasMore: true));
    answer(
        '$listUrl&cursor=c1',
        list([
          {'id': 'y', 'name': 'b'}
        ], cursor: 'c1', hasMore: true));
    answer('$_api/v1.0/stage/x/logs', '{}');

    await refetch();

    expect(requests.map((request) => request.$1), [listUrl, '$listUrl&cursor=c1']);
  });

  test('stops after the page limit when the provider never says it is done', () async {
    refused(_file);
    var page = 0;
    when(() => getDep<LtHttp>().get(any(), headers: any(named: 'headers'))).thenAnswer((_) async {
      page++;
      return http.Response(list([], cursor: 'c$page', hasMore: true), 200);
    });
    await refetch();
    expect(page, 50);
  });

  test('an unreadable scenario list warns once and keeps the refused logs', () async {
    refused(_file);
    for (final body in [
      http.Response('nope', 500),
      http.Response('not json', 200),
      http.Response('[]', 200),
      http.Response('{"data":[],"metadata":3}', 200)
    ]) {
      when(() => getDep<LtHttp>().get(any(), headers: any(named: 'headers'))).thenAnswer((_) async => body);
      await refetch();
    }
    verify(() => getDep<MplatrolLogger>().warn(any(that: contains('the scenario list could not be read')))).called(4);
  });

  test('names each log that could not be fetched and why', () async {
    refused('a');
    refused('b');
    refused('c');
    answer(
        listUrl,
        list([
          {'id': 's1', 'name': 'a'},
          {'id': 's2', 'name': 'b'},
          {'id': 's3', 'name': 'c'},
        ]));
    answer(stageUrl, jsonEncode({'data': null}), status: 403);
    answer('$_api/v1.0/stage/s2/logs', jsonEncode({'data': 'http://insecure.example.com/x'}));
    answer('$_api/v1.0/stage/s3/logs', jsonEncode({'data': 'https://deep.lambdatest.com/x'}));
    answer('https://deep.lambdatest.com/x', hyperexecuteAccessDenied);

    await refetch();

    expect(File(p.join(scenarios.path, 'a')).readAsStringSync(), hyperexecuteAccessDenied);
    final warning = verify(() => getDep<MplatrolLogger>().warn(captureAny(that: contains('still missing'))))
        .captured
        .single as String;
    expect(
        warning,
        allOf(contains('3 scenario log(s)'), contains('a: no log link (HTTP 403)'),
            contains('b: no log link (HTTP 200)'), contains('c: HTTP 200 from deep.lambdatest.com')));
  });

  test('repairs scenario logs an earlier version saved double-encoded', () async {
    const banner = '══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞══\nThe following TimeoutException was thrown';
    final saved = File(p.join(scenarios.path, 'saved'))
      ..writeAsBytesSync(utf8.encode(latin1.decode(utf8.encode(banner))));
    final fine = File(p.join(scenarios.path, 'fine'))..writeAsStringSync(banner);

    await refetch();

    expect(saved.readAsStringSync(), banner);
    expect(fine.readAsStringSync(), banner);
    verify(() => getDep<MplatrolLogger>().info(any(that: contains('repaired 1 scenario log(s)'))));
  });

  test('saves a refetched log as the UTF-8 the provider sent', () async {
    final log = refused(_file);
    answer(
        listUrl,
        list([
          {'id': 's1', 'name': _name}
        ]));
    answer(stageUrl, jsonEncode({'data': 'https://mobile-api.lambdatest.com/logs/s1.txt'}));
    responses['https://mobile-api.lambdatest.com/logs/s1.txt'] =
        http.Response.bytes(utf8.encode('══╡ EXCEPTION CAUGHT ╞══'), 200);

    await refetch();

    expect(utf8.decode(log.readAsBytesSync()), '══╡ EXCEPTION CAUGHT ╞══');
  });
}
