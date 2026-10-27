import 'dart:async';
import 'dart:io';

import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/lt_dashboard_links.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _job = '0a480ae9-b8a9-47d9-aa84-8fe7f5d84930';
const _other = 'cb4e4649-e6df-48d8-86b3-a8a1fa70019f';
String _link(String id) => 'Build Link: https://appautomation.lambdatest.com/build?jobid=$id\n';

void main() {
  late Directory dir;
  late String log;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('lt_links');
    log = p.join(dir.path, 'hyperexecute-cli.log');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('builds the dashboard pages LambdaTest documents and prints', () {
    expect(ltTestPageUrl('RMAA-1', buildId: '28547361'),
        'https://appautomation.lambdatest.com/test?build=28547361&testID=RMAA-1&selectedTab=logs');
    expect(ltTestPageUrl('RMAA-1'), 'https://appautomation.lambdatest.com/test?testID=RMAA-1');
    expect(ltTestPageUrl('RMAA-1', buildId: ''), 'https://appautomation.lambdatest.com/test?testID=RMAA-1');
    expect(ltBuildPageUrl(_job), 'https://appautomation.lambdatest.com/build?jobid=$_job');
    expect(hyperexecuteJobPageUrl(_job), 'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=$_job');
  });

  test('reads the last job a CLI log names, only from this run', () {
    expect(hyperexecuteJobIdIn('nothing'), isNull);
    expect(hyperexecuteJobIdIn('${_link(_job)}${_link(_other)}'), _other);
    expect(hyperexecuteJobIdInLog(log, 0), isNull, reason: 'no file');
    final old = _link(_job);
    File(log).writeAsStringSync(old);
    expect(hyperexecuteJobIdInLog(log, old.length), isNull, reason: 'no new text');
    File(log).writeAsStringSync(_link(_other), mode: FileMode.append);
    expect(hyperexecuteJobIdInLog(log, old.length), _other);
  });

  test('announces the job once, as soon as the log names it', () async {
    final done = Completer<void>();
    final jobs = <String>[];
    final announced = announceHyperexecuteJob(
        cliLogPath: log, cliLogOffset: 0, done: done.future, onJob: jobs.add, every: const Duration(milliseconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(jobs, isEmpty);
    File(log).writeAsStringSync(_link(_job));
    await announced.timeout(const Duration(seconds: 2));
    expect(jobs, [_job]);
    done.complete();
  });

  test('stops quietly when the process ends before the log names a job', () async {
    final done = Completer<void>();
    final jobs = <String>[];
    final announced = announceHyperexecuteJob(cliLogPath: log, cliLogOffset: 0, done: done.future, onJob: jobs.add);
    done.complete();
    await announced.timeout(const Duration(seconds: 2));
    expect(jobs, isEmpty);
  });

  test('ItRunResults ignores a job recorded outside a leg', () {
    ItRunResults().hyperexecuteJob(_job);
  });
}
