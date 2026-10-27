import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_publisher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late MatrixRunDir run;
  late List<String> calls;
  late List<String> reports;
  late int exitCode;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mplatrol_matrix_pub');
    run = MatrixRunDir(p.join(root.path, 'round8'))..append('start', DateTime(2026, 10, 5));
    calls = [];
    reports = [];
    exitCode = 0;
  });
  tearDown(() => root.deleteSync(recursive: true));

  MatrixPublisher publisher({Duration interval = const Duration(milliseconds: 60), List<String>? commands}) =>
      MatrixPublisher(
        commands: commands ?? ['pub {run}'],
        run: run,
        interval: interval,
        runHook: (command, {required silent}) async {
          calls.add('$command silent=$silent state=${File(run.roundStateFile).readAsStringSync().trim()}');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return exitCode;
        },
        report: (message, {required fatal}) => reports.add('${fatal ? 'fatal' : 'warn'} $message'),
      );

  Future<void> wait(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));

  test('publishes at once when a leg finishes, then at most once per interval', () async {
    final pub = publisher(interval: const Duration(seconds: 2));

    pub.legFinished();
    await wait(30);
    expect(calls, ['pub ${run.path} silent=true state=running']);

    pub
      ..legFinished()
      ..legFinished();
    await wait(30);
    expect(calls, hasLength(1), reason: 'debounced inside the interval');

    await wait(2500);
    expect(calls, hasLength(2), reason: 'the debounced results go out once the interval is up');
    await pub.finish(MatrixRoundState.complete);
  });

  test('a leg finishing while a publish runs is published afterwards', () async {
    final pub = publisher(interval: Duration.zero);

    pub.legFinished();
    await wait(1);
    pub.legFinished();
    await wait(40);

    expect(calls, hasLength(2));
    await pub.finish(MatrixRoundState.complete);
  });

  test('finish publishes the final state, cancels the pending interim publish and counts failures', () async {
    final pub = publisher(interval: const Duration(seconds: 30), commands: ['good {run}', 'bad']);
    pub.legFinished();
    await wait(30);
    pub.legFinished();
    exitCode = 2;

    final failed = await pub.finish(MatrixRoundState.partial);
    await wait(30);

    expect(failed, 2);
    expect(calls.where((call) => call.endsWith('state=partial')),
        ['good ${run.path} silent=false state=partial', 'bad silent=false state=partial']);
    expect(calls.where((call) => call.endsWith('state=running')), hasLength(2), reason: 'nothing after finish');
    expect(reports.last, 'fatal [matrix] --publish "bad" failed (exit 2); rerun it by hand.');
    expect(File(run.roundStateFile).readAsStringSync(), 'partial\n');
  });

  test('an interim failure is a warning and the next publish retries', () async {
    exitCode = 1;
    final pub = publisher(interval: Duration.zero);

    pub.legFinished();
    await wait(30);

    expect(reports, ['warn [matrix] interim --publish "pub {run}" failed (exit 1); the next publish retries.']);
    await pub.finish(MatrixRoundState.complete);
  });

  test('a hook that throws is reported and does not stop the final publish', () async {
    final pub = MatrixPublisher(
      commands: ['boom', 'ok'],
      run: run,
      runHook: (command, {required silent}) async {
        calls.add(command);
        if (command == 'boom') {
          throw StateError('no shell');
        }
        return 0;
      },
      report: (message, {required fatal}) => reports.add(message),
    );

    expect(await pub.finish(MatrixRoundState.partial), 1);
    expect(calls, ['boom', 'ok']);
    expect(reports.single, contains('Bad state: no shell'));
  });

  test('without hooks nothing runs', () async {
    final pub = publisher(commands: const []);

    pub.legFinished();
    expect(await pub.finish(MatrixRoundState.complete), 0);
    expect(calls, isEmpty);
  });

  test('leg results after finish are ignored', () async {
    final pub = publisher();
    await pub.finish(MatrixRoundState.complete);

    pub.legFinished();
    await wait(20);

    expect(calls, hasLength(1));
  });
}
