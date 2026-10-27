import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_timings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late MatrixRunDir run;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mplatrol_timings');
    run = MatrixRunDir(p.join(root.path, 'round7'))..append('start lanes=(a b) legs=3', DateTime(2026, 10, 3, 23, 50));
  });
  tearDown(() => root.deleteSync(recursive: true));

  void queue(String line) => File(run.queueLog).writeAsStringSync('$line\n', mode: FileMode.append);

  test('reports the round, each leg, its phases and the peak sessions', () {
    queue('2026-10-03 23:50:00 a start acme:lt-ios');
    queue('2026-10-03 23:50:01 b start globex:lt-android@Pixel 8-14');
    queue('2026-10-04 00:05:00 a released acme:lt-ios');
    queue('2026-10-04 00:30:00 a finish acme:lt-ios exit 70');
    queue('2026-10-04 00:31:00 b finish globex:lt-android@Pixel 8-14 exit 0');
    queue('2026-10-04 00:31:30 all lanes finished');
    File(run.times(MatrixLeg.parse('acme:lt-ios')!)).writeAsStringSync([
      'banner without time',
      '23:51:30 Prepared for the login E2E (tenant: acme).',
      '00:03:00 ⠋ Uploading Runner.ipa to LambdaTest',
      '00:04:30 [lane-release] artifacts uploaded',
    ].join('\n'));
    final usage = File(p.join(root.path, 'usage.log'))
      ..writeAsStringSync([
        '2026-10-03T23:00:00.000 grant 30 old inUse=30/30',
        '2026-10-04T00:06:00.000 grant 10 a inUse=10/30',
        '2026-10-04T00:07:00.000 grant 7 b inUse=17/30',
        'garbage',
      ].join('\n'));

    final report = MatrixTimings(usageLog: usage.path).report(run);

    expect(
        report,
        startsWith('## round7: 41m30s wall clock (23:50 to 00:31), 2 legs\n'
            'peak concurrent LambdaTest sessions: 17\n'));
    expect(report, contains('| acme:lt-ios | a | 70 | 40m00s | 15m00s | 1m30s | 11m30s | 1m30s | 25m30s | - |'));
    expect(report, contains('| globex:lt-android | b | 0 | 40m59s | 40m59s | — | — | — | — | - |'));
  });

  test('reports local legs, which hold their lane until they exit', () {
    queue('2026-10-03 23:50:00 a start acme:android');
    queue('2026-10-04 00:20:00 a finish acme:android exit 0');
    File(run.times(MatrixLeg.parse('acme:android')!))
        .writeAsStringSync('23:52:00 Prepared for the login E2E (tenant: acme).\n');

    final report = MatrixTimings().report(run);

    expect(report, contains('| acme:android | a | 0 | 30m00s | 30m00s | 2m00s | — | — | — |'));
  });

  test('a leg still running and no usage log leave their cells empty', () {
    queue('2026-10-03 23:55:00 a start initech:lt-ios');
    final report = MatrixTimings(usageLog: p.join(root.path, 'missing.log')).report(run);
    expect(report, isNot(contains('peak')));
    expect(report, contains('| initech:lt-ios | a | ? | — | — | — | — | — | — | - |'));
    expect(MatrixTimings().report(run), contains('initech:lt-ios'));
  });

  test('links the job and build pages a leg recorded in its summary.json', () {
    for (final spec in ['acme:lt-ios', 'globex:lt-android', 'initech:lt-ios', 'stark:lt-ios']) {
      queue('2026-10-03 23:50:00 a start $spec');
      queue('2026-10-04 00:30:00 a finish $spec exit 0');
    }
    void summary(String spec, String content) =>
        File(p.join(run.legDir(MatrixLeg.parse(spec)!), 'reports', 'summary.json'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
    summary(
        'acme:lt-ios',
        '{"Legs":[{"hyperexecuteJobUrl":"https://he/job?jobId=A https://he/job?jobId=B", '
            '"ltBuildUrl":"https://app/build?jobid=A"}]}');
    summary('globex:lt-android', '{"Legs":[{"hyperexecuteJobUrl":null,"ltBuildUrl":null}]}');
    summary('initech:lt-ios', 'not json');
    summary('stark:lt-ios', '{"Legs":"none"}');

    final report = MatrixTimings().report(run);

    expect(
        report,
        contains('| [job](https://he/job?jobId=A) [job](https://he/job?jobId=B) '
            '[build](https://app/build?jobid=A) |'));
    expect(RegExp(r'\| - \|\n').allMatches(report), hasLength(3));
  });

  test('locates the session budget log under HOME', () {
    expect(matrixUsageLog('/Users/me'), '/Users/me/.mplatrol/lt-slots/usage.log');
    expect(matrixUsageLog(''), isNull);
    expect(matrixUsageLog(null), isNull);
  });
}
