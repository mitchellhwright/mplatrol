import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/commands/it_clean_command.dart';
import 'package:mplatrol/src/commands/mplatrol_command_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

class _MockDiskJanitor extends Mock implements DiskJanitor {}

class _FakeDiskCleanOptions extends Fake implements DiskCleanOptions {}

void main() {
  late MplatrolShell shell;
  late FileSystem fileSystem;
  late PlatformWrapper platform;
  late Directory repo;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    fileSystem = getDep<FileSystem>();
    platform = getDep<PlatformWrapper>();
    repo = Directory(Directory.systemTemp.createTempSync('it_clean_repo').resolveSymbolicLinksSync());
    when(
      () => fileSystem.getAppDirectory(
        throwIfNotFound: any(named: 'throwIfNotFound'),
        workingDir: any(named: 'workingDir'),
      ),
    ).thenReturn(repo);
  });

  tearDown(() {
    if (repo.existsSync()) {
      repo.deleteSync(recursive: true);
    }
  });

  group('clean', () {
    test('stops the tunnel via LT_BIN and removes the build artifacts', () async {
      when(() => platform.environment).thenReturn({'LT_BIN': '/opt/LT'});
      final buildDir = Directory(p.join(repo.path, 'ios', 'build', 'xcui-lt'))..createSync(recursive: true);
      final ltLog = File(p.join(repo.path, 'lt.log'))..writeAsStringSync('x');

      final result = await MplatrolCommandRunner().run('clean'.split(' '));

      expect(result, ExitCode.success.code);
      verify(() => shell.runArgs('pkill', ['-f', '/opt/LT'], throwOnError: false)).called(1);
      expect(buildDir.existsSync(), isFalse);
      expect(ltLog.existsSync(), isFalse);
    });

    test('defaults the tunnel binary to the mplatrol copy under HOME', () async {
      when(() => platform.environment).thenReturn({'HOME': '/Users/me'});

      await MplatrolCommandRunner().run('clean'.split(' '));

      verify(() => shell.runArgs('pkill', ['-f', '/Users/me/.mplatrol/hyperexecute/LT'], throwOnError: false))
          .called(1);
    });

    test('falls back to a bare LT match when HOME is unset', () async {
      when(() => platform.environment).thenReturn(const {});

      await MplatrolCommandRunner().run('clean'.split(' '));

      verify(() => shell.runArgs('pkill', ['-f', 'LT'], throwOnError: false)).called(1);
    });

    test('reports success and removes nothing when no artifacts exist', () async {
      when(() => platform.environment).thenReturn(const {});
      final logger = getDep<MplatrolLogger>();

      final result = await MplatrolCommandRunner().run('clean'.split(' '));

      expect(result, ExitCode.success.code);
      verifyNever(() => logger.info(any(that: contains('Removed'))));
      verify(() => logger.success(any(that: contains('Cleaned up')))).called(1);
    });
  });

  group('clean --disk', () {
    late DiskJanitor janitor;

    setUpAll(() => registerFallbackValue(_FakeDiskCleanOptions()));

    setUp(() {
      janitor = _MockDiskJanitor();
      GetIt.I.unregister<DiskJanitor>();
      GetIt.I.registerSingleton<DiskJanitor>(janitor);
      when(() => janitor.clean(any())).thenAnswer((_) async => 0);
      when(() => platform.environment).thenReturn(const {});
    });

    DiskCleanOptions captured() => verify(() => janitor.clean(captureAny())).captured.single as DiskCleanOptions;

    test('prunes the disk instead of stopping tunnels, scanning the workspace parent by default', () async {
      final previous = Directory.current;
      Directory.current = repo;
      addTearDown(() => Directory.current = previous);

      final result = await MplatrolCommandRunner().run('clean --disk'.split(' '));

      expect(result, ExitCode.success.code);
      verifyNever(() => shell.runArgs('pkill', any(), throwOnError: any(named: 'throwOnError')));
      final options = captured();
      expect(options.checkout, repo.path);
      expect(options.roots, [p.dirname(p.dirname(repo.path))]);
      expect(options.dryRun, isFalse);
      expect(options.aggressive, isFalse);
    });

    test('passes the dry-run, aggressive and directory options through', () async {
      await MplatrolCommandRunner().run([
        'clean',
        '--disk',
        '--dry-run',
        '--aggressive',
        '--root',
        '/r1',
        '--root',
        '/r2',
        '--keep',
        'matrix-lane3',
        '--log-dir',
        '/logs',
        '--video-dir',
        '/videos',
      ]);

      final options = captured();
      expect(options.dryRun, isTrue);
      expect(options.aggressive, isTrue);
      expect(options.roots, ['/r1', '/r2']);
      expect(options.keep, ['matrix-lane3']);
      expect(options.logDirs, ['/logs']);
      expect(options.videoDirs, ['/videos']);
    });

    test('run outside the checkout workspace it protects nothing extra and scans only given roots', () async {
      await MplatrolCommandRunner().run('clean --disk --root /r'.split(' '));

      final options = captured();
      expect(options.checkout, isNull);
      expect(options.roots, ['/r']);
    });

    test('outside a checkout it scans only the roots it is given', () async {
      repo.deleteSync(recursive: true);

      await MplatrolCommandRunner().run('clean --disk'.split(' '));

      final options = captured();
      expect(options.checkout, isNull);
      expect(options.roots, isEmpty);
    });

    test('describes the disk mode in its help', () {
      expect(ItCleanCommand().description, contains('with --disk, move old build outputs and caches to the Trash'));
    });

    test('rejects disk options without --disk', () async {
      for (final args in [
        ['--dry-run'],
        ['--root', '/r'],
      ]) {
        final result = await MplatrolCommandRunner().run(['clean', ...args]);
        expect(result, ExitCode.usage.code);
      }
      verifyNever(() => janitor.clean(any()));
    });
  });
}
