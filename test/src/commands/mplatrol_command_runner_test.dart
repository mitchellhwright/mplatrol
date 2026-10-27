import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/version.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

void main() {
  setUp(scaffoldMockDependencies);

  test('registers every command', () {
    expect(MplatrolCommandRunner().commands.keys,
        containsAll(['run', 'build', 'matrix', 'devices', 'doctor', 'clean', 'coverage', 'help']));
  });

  test('--version prints the package version', () async {
    expect(await MplatrolCommandRunner().run(['--version']), ExitCode.success.code);
    verify(() => getDep<MplatrolLogger>().info(mplatrolVersion)).called(1);
  });

  test('a usage error exits 64 with the message and the usage', () async {
    expect(await MplatrolCommandRunner().run(['no-such-command']), ExitCode.usage.code);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('Could not find a command named "no-such-command"'))))
        .called(1);
  });

  test('--verbose turns on verbose logging', () async {
    await MplatrolCommandRunner().run(['--verbose', '--version']);
    verify(() => getDep<MplatrolLogger>().level = Level.verbose).called(1);
  });

  group('project lessons', () {
    tearDown(clearRegisteredTestLessons);

    test('registers the lessons it is given and the configured ones before running a command', () async {
      final given = TestLesson.custom(
          name: 'givenLesson', category: ItResultCategory.ltFailure, symptom: 's', remedy: 'r', pattern: 'GIVEN');
      final configured = TestLesson.custom(
          name: 'configuredLesson', category: ItResultCategory.envFailure, symptom: 's', remedy: 'r', pattern: 'CONF');
      when(() => getDep<MplatrolConfig>().lessons).thenReturn([configured]);

      expect(await MplatrolCommandRunner(lessons: [given]).run(['--version']), ExitCode.success.code);

      expect(recognizeTestLessons('GIVEN and CONF'), {given, configured});
    });

    test('an invalid configured lesson stops the run with a config error', () async {
      when(() => getDep<MplatrolConfig>().lessons)
          .thenThrow(const FormatException('lessons: in mplatrol.yaml must be a list.'));

      expect(await MplatrolCommandRunner().run(['--version']), ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err('Invalid lesson: lessons: in mplatrol.yaml must be a list.')).called(1);
    });

    test('a lesson whose name is taken stops the run with a config error', () async {
      final clash = TestLesson.custom(
          name: 'proxy', category: ItResultCategory.envFailure, symptom: 's', remedy: 'r', pattern: 'x');

      expect(await MplatrolCommandRunner(lessons: [clash]).run(['--version']), ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: startsWith('Invalid lesson: lessons')))).called(1);
    });
  });
}
