import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

void main() {
  late Directory repo;
  late List<String> infos;

  setUp(() async {
    await scaffoldMockDependencies();
    repo = Directory.systemTemp.createTempSync('it_coverage_');
    when(() => getDep<FileSystem>().getAppDirectory(
          throwIfNotFound: any(named: 'throwIfNotFound'),
          workingDir: any(named: 'workingDir'),
        )).thenReturn(repo);
    when(() => getDep<MplatrolShell>().whichSync('genhtml')).thenReturn(null);
    infos = [];
    when(() => getDep<MplatrolLogger>().info(any()))
        .thenAnswer((i) => infos.add(i.positionalArguments.first as String));
  });

  tearDown(() => repo.deleteSync(recursive: true));

  String write(String name, String text) => (File(p.join(repo.path, name))..writeAsStringSync(text)).path;

  Future<int> merge(List<String> args) => MplatrolCommandRunner().run(['coverage', 'merge', ...args]);

  test('merges two real flutter test reports by file and line, with summary and JSON', () async {
    const a = 'test/fixtures/e2e_coverage/flutter_test_a.info';
    const b = 'test/fixtures/e2e_coverage/flutter_test_b.info';
    final output = p.join(repo.path, 'merged.info');

    final code = await merge([a, b, '--output=$output']);

    expect(code, ExitCode.success.code);
    final expected = Lcov.merge([Lcov.parse(File(a).readAsStringSync()), Lcov.parse(File(b).readAsStringSync())]);
    expect(Lcov.parse(File(output).readAsStringSync()).files, expected.files);
    final json = jsonDecode(File(p.join(repo.path, 'merged.json')).readAsStringSync()) as Map<String, dynamic>;
    expect(json, containsPair('kind', 'merged'));
    expect(json['sources'], ['flutter_test_a.info', 'flutter_test_b.info']);
    expect(infos, contains(startsWith('[coverage] E2E (journey) line coverage:')));
  });

  test('writes lcov-merged-<timestamp>.info under .mplatrol/reports/coverage by default', () async {
    final input = write('one.info', 'SF:/w/pkg/lib/a.dart\nDA:1,1\nend_of_record\n');

    expect(await merge([input]), ExitCode.success.code);

    final names =
        Directory(p.join(repo.path, '.mplatrol', 'reports', 'coverage')).listSync().map((e) => p.basename(e.path));
    expect(names, contains(matches(RegExp(r'^lcov-merged-\d{8}T\d{6}Z\.info$'))));
  });

  test('asks for at least one file', () async {
    expect(await merge([]), ExitCode.usage.code);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('Pass at least one LCOV file')))).called(1);
  });

  test('names a file that does not exist', () async {
    expect(await merge([p.join(repo.path, 'nope.info')]), ExitCode.usage.code);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('LCOV file not found')))).called(1);
  });

  test('names a file that is not valid LCOV and writes nothing', () async {
    final bad = write('bad.info', 'SF:/a.dart\nDA:x\n');

    expect(await merge([bad]), ExitCode.data.code);

    verify(() => getDep<MplatrolLogger>().err(any(that: allOf(contains(bad), contains('Malformed LCOV record')))))
        .called(1);
    expect(Directory(p.join(repo.path, '.mplatrol')).existsSync(), isFalse);
  });
}
