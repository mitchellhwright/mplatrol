import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mplatrol/src/android_instrumentation_verdict.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_native_annotation.dart';
import 'package:test/test.dart';

const _id = 'RMAA-AND-1913856-1790805848426672708DGI';
const _identity = 'com.example.SelectedTest/selected_method';
const _base = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1';
const _jobId = 'c407a474-1111-2222-3333-444444444444';

class _Fixture {
  final session = <String, dynamic>{
    'sessionID': _id,
    'taskID': 'task-current',
    'scenario_name': _identity,
    'status': 'passed'
  };
  final job = <String, dynamic>{
    'id': _jobId,
    'tasks': [
      {'id': 'task-current'}
    ]
  };
  final native = <String, dynamic>{
    'session_id': _id,
    'build_id': 28244439,
    'platform': 'Android',
    'test_id': 'native-test-current',
    'status_ind': 'passed',
    'name': 'original',
    'customdata': {
      'customData': {'existing': 'preserved'}
    }
  };
  final requests = <http.Request>[];
  Map<String, dynamic>? written;
  int patchStatus = 200;
  int getStatus = 200;
  bool malformed = false;
  bool readbackMismatch = false;
  bool transportFailure = false;
  bool incomplete = false;
  bool duplicate = false;
  bool android = true;
  String? readbackField;
  final pendingPatch = Completer<http.Response>();
  bool holdPatch = false;

  Future<String> run(
      {AndroidInstrumentationOutcome outcome = AndroidInstrumentationOutcome.skipped,
      List? sessions,
      Set<String>? selected,
      LtHttp? transport}) {
    return annotateNativeNonpass(
        http: transport ?? LtHttp(client: MockClient(_respond)),
        headers: const {'Authorization': 'protected-fixture'},
        job: job,
        sessions: sessions ?? [session],
        session: session,
        selected: selected ?? {_identity},
        outcome: outcome,
        android: android);
  }

  Future<http.Response> _respond(http.Request request) async {
    requests.add(request);
    expect(request.url.host, 'mobile-api.lambdatest.com');
    if (transportFailure) {
      throw const FormatException('protected secret must never appear');
    }
    if (request.method == 'PATCH') {
      written = jsonDecode(request.body) as Map<String, dynamic>;
      if (holdPatch) {
        return pendingPatch.future;
      }
      return http.Response('{}', patchStatus);
    }
    if (malformed) {
      return http.Response('not json protected secret', getStatus);
    }
    if (request.url.queryParameters.containsKey('build_id')) {
      final data = [native, if (duplicate) native];
      return http.Response(
          jsonEncode({
            'data': data,
            'metadata': {'total': data.length, 'hasmore': incomplete}
          }),
          getStatus);
    }
    return _sessionResponse();
  }

  http.Response _sessionResponse() {
    final data = Map<String, dynamic>.from(native);
    if (written != null && !readbackMismatch) {
      data['name'] = written!['name'];
      data['status_ind'] = written!['status_ind'];
      data['customdata'] = {'customData': written!['custom_data']};
      if (readbackField != null) {
        data[readbackField!] = 'foreign';
      }
    }
    return http.Response(jsonEncode({'data': data}), getStatus);
  }

  void expectNoPatch() => expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
}

void _registerOutcomeCases() {
  test('matching -4 annotates failed plus SKIPPED and verifies same-session readback', () async {
    final fixture = _Fixture();
    const log = 'INSTRUMENTATION_STATUS: class=com.example.SelectedTest\n'
        'INSTRUMENTATION_STATUS: test=selected_method\n'
        'INSTRUMENTATION_STATUS_CODE: -4\nINSTRUMENTATION_CODE: -1\n';
    final outcome = androidInstrumentationVerdict(log, nativeIdentity: _identity).outcome;
    expect(await fixture.run(outcome: outcome), contains('SKIPPED annotation verified'));
    expect(fixture.written!['status_ind'], 'failed');
    expect(fixture.written!['name'], '[SKIPPED] native test');
    final metadata = fixture.written!['custom_data'] as Map;
    expect(metadata['existing'], 'preserved');
    expect(metadata['mplatrol_native_identity'], _identity);
    expect(metadata['mplatrol_native_build'], '28244439');
    expect(fixture.requests.map((r) => '${r.method} ${r.url}'), [
      'GET $_base/sessions/$_id',
      'GET $_base/sessions?build_id=28244439',
      'PATCH $_base/sessions/$_id',
      'GET $_base/sessions/$_id'
    ]);
  });
  test('missing instrumentation is UNVERIFIED, never SKIPPED', () async {
    final fixture = _Fixture();
    expect(await fixture.run(outcome: AndroidInstrumentationOutcome.unavailable),
        contains('UNVERIFIED annotation verified'));
    expect(fixture.written!['name'], '[UNVERIFIED] native test');
    expect((fixture.written!['custom_data'] as Map)['mplatrol_native_reason'], 'instrumentation_unavailable');
  });
  for (final outcome in [AndroidInstrumentationOutcome.passed, AndroidInstrumentationOutcome.failed]) {
    test('$outcome never mutates genuine pass or unclassified failure', () async {
      final fixture = _Fixture();
      await fixture.run(outcome: outcome);
      expect(fixture.requests, isEmpty);
    });
  }
}

void _registerOwnershipCases() {
  for (final field in ['sessionID', 'taskID', 'scenario_name', 'status']) {
    test('foreign current-job $field never writes', () async {
      final fixture = _Fixture();
      fixture.session[field] = 'foreign';
      expect(await fixture.run(), contains('refused'));
      fixture.expectNoPatch();
    });
  }
  test('duplicate sessions never write', () async {
    final fixture = _Fixture();
    await fixture.run(sessions: [fixture.session, fixture.session]);
    fixture.expectNoPatch();
  });
  test('foreign selected artifact never writes', () async {
    final fixture = _Fixture();
    await fixture.run(selected: {'foreign'});
    fixture.expectNoPatch();
  });
  for (final field in ['session_id', 'scenario_name', 'platform', 'build_id']) {
    test('foreign native $field never writes', () async {
      final fixture = _Fixture();
      fixture.native[field] = 'foreign';
      expect(await fixture.run(), contains('refused'));
      fixture.expectNoPatch();
    });
  }
  for (final mode in ['incomplete', 'duplicate']) {
    test('$mode build inventory never writes', () async {
      final fixture = _Fixture();
      fixture.incomplete = mode == 'incomplete';
      fixture.duplicate = mode == 'duplicate';
      expect(await fixture.run(), contains('refused'));
      fixture.expectNoPatch();
    });
  }
}

void _registerFailureCases() {
  for (final status in [400, 401, 403, 404, 599]) {
    test('PATCH HTTP $status remains annotation-unverified', () async {
      final fixture = _Fixture()..patchStatus = status;
      expect(await fixture.run(), contains('unverified'));
      expect(fixture.requests.where((r) => r.method == 'PATCH').length, 1);
      expect(fixture.written!['status_ind'], isNot('skipped'));
    });
    test('metadata HTTP $status never writes', () async {
      final fixture = _Fixture()..getStatus = status;
      expect(await fixture.run(), contains('unverified'));
      fixture.expectNoPatch();
    });
  }
  test('same-endpoint readback mismatch cannot certify annotation', () async {
    final fixture = _Fixture()..readbackMismatch = true;
    expect(await fixture.run(), contains('readback mismatch'));
  });
  for (final mode in ['malformed', 'transport']) {
    test('$mode errors never expose protected data', () async {
      final fixture = _Fixture();
      fixture.malformed = mode == 'malformed';
      fixture.transportFailure = mode == 'transport';
      final result = await fixture.run();
      expect(result, contains('unverified'));
      expect(result, isNot(contains('protected secret')));
      fixture.expectNoPatch();
    });
  }
}

void main() {
  _registerOutcomeCases();
  _registerOwnershipCases();
  _registerFailureCases();
  _registerReadbackAndTimeoutCases();
}

void _registerReadbackAndTimeoutCases() {
  test('iOS missing instrumentation uses exact RMAA-IOS ownership and UNVERIFIED', () async {
    final fixture = _Fixture()..android = false;
    fixture.session['sessionID'] = 'RMAA-IOS-1913856-1790805848426672708DGI';
    fixture.native['session_id'] = fixture.session['sessionID'];
    fixture.native['platform'] = 'iOS';
    expect(await fixture.run(outcome: AndroidInstrumentationOutcome.unavailable),
        contains('UNVERIFIED annotation verified'));
  });
  for (final field in ['session_id', 'scenario_name', 'platform', 'build_id', 'test_id', 'customdata']) {
    test('readback changed $field never certifies annotation', () async {
      final fixture = _Fixture()..readbackField = field;
      expect(await fixture.run(), contains('readback mismatch'));
    });
  }
  test('top-level customData metadata is preserved in the annotation', () async {
    final fixture = _Fixture();
    fixture.native
      ..remove('customdata')
      ..['customData'] = {'existing': 'top-level'};
    expect(await fixture.run(), contains('SKIPPED annotation verified'));
    expect((fixture.written!['custom_data'] as Map)['existing'], 'top-level');
  });
  test('unsupported native metadata shape never writes', () async {
    final fixture = _Fixture();
    fixture.native['customdata'] = 'malformed';
    expect(await fixture.run(), contains('refused'));
    fixture.expectNoPatch();
  });
  test('PATCH timeout has no retry or overlapping readback', () {
    fakeAsync((async) {
      final fixture = _Fixture()..holdPatch = true;
      String? outcome;
      fixture.run(transport: _DeadlineHttp(fixture)).then((value) => outcome = value);
      async.flushMicrotasks();
      expect(fixture.written, isNotNull);
      async.elapse(const Duration(seconds: 25));
      expect(outcome, contains('TimeoutException'));
      expect(fixture.requests.length, 3);
      fixture.pendingPatch.complete(http.Response('{}', 200));
      async.flushMicrotasks();
      expect(fixture.requests.length, 3);
    });
  });
}

class _DeadlineHttp extends LtHttp {
  _DeadlineHttp(this.fixture) : super(client: MockClient((_) async => http.Response('', 599)));
  final _Fixture fixture;

  @override
  Future<http.Response> get(String url,
          {required Map<String, String> headers, Duration timeout = const Duration(seconds: 25)}) =>
      fixture._respond(http.Request('GET', Uri.parse(url)));

  @override
  Future<http.Response> patchJson(String url,
          {required Map<String, String> headers, required Map<String, dynamic> body}) =>
      fixture._respond(http.Request('PATCH', Uri.parse(url))..body = jsonEncode(body));
}
