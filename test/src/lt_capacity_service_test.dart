import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mplatrol/src/lt_capacity_service.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:test/test.dart';

void main() {
  const env = {'LT_USERNAME': 'user', 'LT_ACCESS_KEY': 'key'};
  late List<http.Request> requests;

  void answer(http.Response Function() response) {
    GetIt.I.registerSingleton<LtHttp>(LtHttp(client: MockClient((request) async {
      requests.add(request);
      return response();
    })));
  }

  setUp(() => requests = []);
  tearDown(GetIt.I.reset);

  test('reads the org max, running and queued sessions with the LambdaTest credentials', () async {
    answer(() => http.Response(
        '{"data":{"max_concurrency":40,"max_queue":80,"queued":3,"running":25},"status":"success"}', 200));

    final reading = await LtCapacityService().read(env);

    expect(reading.capacity!.toJson(), {'max': 40, 'running': 25, 'queued': 3});
    expect(reading.error, isNull);
    expect(requests.single.url.toString(), ltConcurrencyUrl);
    expect(requests.single.headers['Authorization'], 'Basic dXNlcjprZXk=');
    expect(await LtCapacityService().summary(env), 'LambdaTest org usage: 25 of 40 sessions running, 3 queued');
  });

  test('says why there is no reading', () async {
    answer(() => http.Response('denied', 401));
    expect((await LtCapacityService().read(env)).error, 'HTTP 401 from $ltConcurrencyUrl');
    expect((await LtCapacityService().read(const {})).error, 'LT_USERNAME / LT_ACCESS_KEY are not set');
    expect(await LtCapacityService().summary(const {}),
        'LambdaTest org usage unknown: LT_USERNAME / LT_ACCESS_KEY are not set');
    expect(requests, hasLength(1));
  });

  test('an unexpected answer is no reading', () async {
    answer(() => http.Response('{"data":{"running":"many"}}', 200));
    expect((await LtCapacityService().read(env)).error, 'unexpected answer from $ltConcurrencyUrl');
  });
}
