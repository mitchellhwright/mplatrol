import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_hyperexecute_stall_watchdog.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLtHttp extends Mock implements LtHttp {}

class _MockLogger extends Mock implements MplatrolLogger {}

const _jobId = '0a480ae9-b8a9-47d9-aa84-8fe7f5d84930';
const _oldJobId = 'cb4e4649-e6df-48d8-86b3-a8a1fa70019f';
final _now = DateTime.utc(2026, 10, 2, 2);

String _link(String id) => '{"msg":"Build Link: https://appautomation.lambdatest.com/build?jobid=$id\\n"}\n';

Map<String, dynamic> _job({
  String status = 'running',
  List<Map<String, dynamic>>? tasks,
}) =>
    {
      'data': {
        'status': status,
        'tasks': tasks ??
            [
              {
                'groupNumber': 1,
                'status': 'passed',
                'endTime': _now.subtract(const Duration(minutes: 16)).toIso8601String(),
              },
              {
                'groupNumber': 2,
                'status': 'running',
                'startTime': _now.subtract(const Duration(minutes: 17)).toIso8601String(),
                'endTime': '',
              },
            ],
      },
    };

void main() {
  late Directory dir;
  late File cliLog;
  late _MockLtHttp http_;
  late _MockLogger logger;
  late List<String> requested;

  setUp(() async {
    await GetIt.I.reset();
    dir = Directory.systemTemp.createTempSync('he_watchdog');
    cliLog = File(p.join(dir.path, 'hyperexecute-cli.log'));
    http_ = _MockLtHttp();
    logger = _MockLogger();
    requested = [];
    GetIt.I.registerLazySingleton<LtHttp>(() => http_);
    GetIt.I.registerLazySingleton<MplatrolLogger>(() => logger);
  });

  tearDown(() async {
    dir.deleteSync(recursive: true);
    await GetIt.I.reset();
  });

  /// Answers job polls with [responses] in order (the last repeats) and
  /// session polls with [sessions], by default no sessions.
  void respond(List<http.Response> responses, {http.Response? sessions}) {
    var index = 0;
    when(() => http_.get(any(), headers: any(named: 'headers'))).thenAnswer((invocation) async {
      final url = invocation.positionalArguments.single as String;
      requested.add(url);
      if (url.endsWith('/sessions?limit=100')) {
        return sessions ?? http.Response(jsonEncode({'data': <Object>[]}), 200);
      }
      final response = responses[index < responses.length ? index : responses.length - 1];
      index++;
      return response;
    });
  }

  Future<String?> watch({int offset = 0, Future<void>? done}) => HyperexecuteStallWatchdog(
        pollEvery: const Duration(milliseconds: 1),
        clock: () => _now,
      ).watch(
        cliLogPath: cliLog.path,
        cliLogOffset: offset,
        headers: const {},
        done: done ?? Completer<void>().future,
      );

  test('reports task groups that never finished after the stall window', () async {
    cliLog.writeAsStringSync(_link(_jobId));
    respond([http.Response(jsonEncode(_job()), 200)]);

    final diagnostic = await watch();

    expect(diagnostic, contains('job $_jobId task group(s) #2 (running)'));
    expect(diagnostic, contains('no task started or finished for 16 min (limit 5 min)'));
    expect(requested, [
      'https://api.hyperexecute.cloud/v2.0/job/$_jobId',
      'https://api.hyperexecute.cloud/v2.0/job/$_jobId/sessions?limit=100',
    ]);
  });

  test('ignores jobs from earlier runs logged before the offset', () async {
    cliLog.writeAsStringSync(_link(_oldJobId));
    final offset = cliLog.lengthSync();
    final done = Completer<void>();
    Timer(const Duration(milliseconds: 30), done.complete);

    expect(await watch(offset: offset, done: done.future), isNull);
    verifyNever(() => http_.get(any(), headers: any(named: 'headers')));
  });

  test('waits for the CLI log to name the job', () async {
    final done = Completer<void>();
    Timer(const Duration(milliseconds: 30), done.complete);

    expect(await watch(done: done.future), isNull);
    verifyNever(() => http_.get(any(), headers: any(named: 'headers')));
  });

  test('keeps polling through API errors and progress, then reports a stall', () async {
    cliLog.writeAsStringSync('${_link(_oldJobId)}${_link(_jobId)}');
    final recent = _now.subtract(const Duration(minutes: 2)).toIso8601String();
    respond([
      http.Response('unavailable', 503),
      http.Response('not json', 200),
      http.Response(jsonEncode({'data': []}), 200),
      http.Response(jsonEncode(_job(status: 'queued')), 200),
      http.Response(
          jsonEncode(_job(tasks: [
            {'groupNumber': 1, 'status': 'running'},
          ])),
          200),
      http.Response(
          jsonEncode(_job(tasks: [
            {'groupNumber': 1, 'status': 'passed', 'endTime': recent},
          ])),
          200),
      http.Response(
          jsonEncode(_job(tasks: [
            {'groupNumber': 1, 'status': 'passed', 'endTime': recent},
            {'groupNumber': 2, 'status': 'initiated', 'endTime': null},
          ])),
          200),
      http.Response(jsonEncode(_job()), 200),
    ]);

    final diagnostic = await watch();

    expect(diagnostic, contains('#2 (running)'));
    expect(requested, hasLength(9));
    expect(requested.where((url) => url.endsWith(_jobId)), hasLength(8));
    expect(requested.last, endsWith('$_jobId/sessions?limit=100'));
    verify(() => logger.detail(any(that: contains('HTTP 503')))).called(1);
  });

  test('returns null as soon as the process finishes', () async {
    cliLog.writeAsStringSync(_link(_jobId));
    respond([http.Response(jsonEncode(_job(tasks: [])), 200)]);
    final done = Completer<void>();
    Timer(const Duration(milliseconds: 30), done.complete);

    expect(await watch(done: done.future), isNull);
  });

  test('defaults to a bounded 5 minute window polled every minute', () {
    final watchdog = HyperexecuteStallWatchdog();
    expect(watchdog.stallAfter, const Duration(minutes: 5));
    expect(watchdog.pollEvery, const Duration(minutes: 1));
  });

  Future<String?> watchBriefly(Map<String, dynamic> job, {http.Response? sessions}) {
    cliLog.writeAsStringSync(_link(_jobId));
    respond([http.Response(jsonEncode(job), 200)], sessions: sessions);
    final done = Completer<void>();
    Timer(const Duration(milliseconds: 30), done.complete);
    return watch(done: done.future);
  }

  String ago(int minutes) => _now.subtract(Duration(minutes: minutes)).toIso8601String();

  test('a task still queued for a device (no start time) is never a stall', () async {
    final diagnostic = await watchBriefly(_job(tasks: [
      {'groupNumber': 1, 'status': 'passed', 'startTime': ago(31), 'endTime': ago(30)},
      {'groupNumber': 2, 'status': 'queued', 'endTime': ''},
    ]));

    expect(diagnostic, isNull);
    expect(requested, isNotEmpty);
  });

  test('a task that started recently counts as progress', () async {
    final diagnostic = await watchBriefly(_job(tasks: [
      {'groupNumber': 1, 'status': 'passed', 'startTime': ago(21), 'endTime': ago(20)},
      {'groupNumber': 2, 'status': 'running', 'startTime': ago(2), 'endTime': ''},
    ]));

    expect(diagnostic, isNull);
  });

  test('four idle minutes is still inside the five minute window', () async {
    final diagnostic = await watchBriefly(_job(tasks: [
      {'groupNumber': 1, 'status': 'passed', 'startTime': ago(5), 'endTime': ago(4)},
      {'groupNumber': 2, 'status': 'running', 'startTime': ago(5), 'endTime': ''},
    ]));

    expect(diagnostic, isNull);
  });

  Map<String, dynamic> longTestJob() => _job(tasks: [
        {'id': 'task-1', 'groupNumber': 1, 'status': 'passed', 'startTime': ago(9), 'endTime': ago(8)},
        {'id': 'task-4', 'groupNumber': 4, 'status': 'running', 'startTime': ago(7), 'endTime': ''},
      ]);

  http.Response sessionsOf(List<Map<String, String>> sessions) => http.Response(jsonEncode({'data': sessions}), 200);

  // Regression: acme lt-ios 2026-10-02 wave 3 was stopped as stalled while
  // its DepositSdk session was still running at 414 s, discarding three passes.
  test('a still-running session of the idle task group is a long test, not a stall', () async {
    final diagnostic = await watchBriefly(longTestJob(),
        sessions: sessionsOf([
          {'sessionID': 'RMAA-IOS-1', 'taskID': 'task-1', 'status': 'passed'},
          {'sessionID': 'RMAA-IOS-4', 'taskID': 'task-4', 'status': 'running'},
        ]));

    expect(diagnostic, isNull);
    verify(() =>
            logger.detail(any(that: allOf(contains('session(s) RMAA-IOS-4 still running'), contains('not a stall')))))
        .called(greaterThan(0));
  });

  test('a session still running past the running-session limit is a stall', () async {
    respond([
      http.Response(
          jsonEncode(_job(tasks: [
            {'id': 'task-1', 'groupNumber': 1, 'status': 'passed', 'startTime': ago(40), 'endTime': ago(35)},
            {'id': 'task-4', 'groupNumber': 4, 'status': 'running', 'startTime': ago(34), 'endTime': ''},
          ])),
          200)
    ],
        sessions: sessionsOf([
          {'sessionID': 'RMAA-IOS-4', 'taskID': 'task-4', 'status': 'running'},
        ]));
    cliLog.writeAsStringSync(_link(_jobId));

    expect(await watch(), contains('#4 (running) never finished'));
  });

  test('an idle task group whose sessions all finished or belong elsewhere is a stall', () async {
    respond([http.Response(jsonEncode(longTestJob()), 200)],
        sessions: sessionsOf([
          {'sessionID': 'RMAA-IOS-1', 'taskID': 'task-1', 'status': 'running'},
          {'sessionID': 'RMAA-IOS-4', 'taskID': 'task-4', 'status': 'Failed'},
        ]));
    cliLog.writeAsStringSync(_link(_jobId));

    expect(await watch(), contains('#4 (running) never finished'));
  });

  for (final sessions in [
    http.Response('unavailable', 503),
    http.Response('not json', 200),
    http.Response(jsonEncode({'data': {}}), 200)
  ]) {
    test('unreadable sessions (${sessions.statusCode} ${sessions.body}) keep the stall protection', () async {
      respond([http.Response(jsonEncode(longTestJob()), 200)], sessions: sessions);
      cliLog.writeAsStringSync(_link(_jobId));

      expect(await watch(), contains('#4 (running) never finished'));
      verify(() => logger.detail(any(
          that: contains('sessions poll returned HTTP '
              '${sessions.statusCode}; treating its idle task group(s) as stalled')))).called(1);
    });
  }
}
