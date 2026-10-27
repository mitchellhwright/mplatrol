import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/trash_mover.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

ProcessResultX _result({int exitCode = 0, String stdout = '', String stderr = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: stderr);

void main() {
  late MplatrolShell shell;
  late MplatrolLogger logger;
  late TrashMover mover;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    logger = getDep<MplatrolLogger>();
    mover = getDep<TrashMover>();
    when(() => shell.whichSync('trash')).thenReturn('/usr/bin/trash');
    when(() => shell.runArgs('du', any(), throwOnError: false, silent: true)).thenAnswer((invocation) async {
      final paths = (invocation.positionalArguments[1] as List<String>).skip(1);
      return _result(stdout: [for (final path in paths) '${1024 * 1024}\t$path'].join('\n'));
    });
    when(() => shell.runArgs('trash', any(), throwOnError: false, silent: true)).thenAnswer((_) async => _result());
  });

  test('moves paths to the Trash in batches and reports their size', () async {
    final paths = [for (var i = 0; i < TrashMover.batchSize + 1; i++) '/p$i'];

    final outcome = await mover.move(paths, dryRun: false);

    expect(outcome.moved, paths.length);
    expect(outcome.gb, paths.length);
    expect(outcome.failed, isEmpty);
    verify(() => shell.runArgs('trash', paths.sublist(0, TrashMover.batchSize), throwOnError: false, silent: true))
        .called(1);
    verify(() => shell.runArgs('trash', ['/p${TrashMover.batchSize}'], throwOnError: false, silent: true)).called(1);
  });

  test('a dry run measures but moves nothing, even without a trash command', () async {
    when(() => shell.whichSync('trash')).thenReturn(null);

    final outcome = await mover.move(['/a', '/b'], dryRun: true);

    expect(outcome.moved, 2);
    expect(outcome.gb, 2);
    verifyNever(() => shell.runArgs('trash', any(), throwOnError: false, silent: true));
  });

  test('moves nothing and reports every path failed without a trash command', () async {
    when(() => shell.whichSync('trash')).thenReturn(null);

    final outcome = await mover.move(['/a'], dryRun: false);

    expect(outcome.moved, 0);
    expect(outcome.failed, ['/a']);
    verify(() => logger.warn(any(that: contains('No `trash` command')))).called(1);
  });

  test('retries a failed batch path by path and keeps the ones trash refuses', () async {
    when(() => shell.runArgs('trash', ['/a', '/b'], throwOnError: false, silent: true))
        .thenAnswer((_) async => _result(exitCode: 1));
    when(() => shell.runArgs('trash', ['/b'], throwOnError: false, silent: true))
        .thenAnswer((_) async => _result(exitCode: 1, stderr: 'permission denied\n'));

    final outcome = await mover.move(['/a', '/b'], dryRun: false);

    expect(outcome.moved, 1);
    expect(outcome.failed, ['/b']);
    verify(() => logger.warn('Could not move /b to the Trash: permission denied')).called(1);
  });

  test('an empty list does nothing; an unreadable size counts as zero', () async {
    expect((await mover.move(const [], dryRun: false)).moved, 0);
    when(() => shell.runArgs('du', any(), throwOnError: false, silent: true))
        .thenAnswer((_) async => _result(exitCode: 1));

    expect((await mover.move(['/a'], dryRun: false)).gb, 0);
  });
}
