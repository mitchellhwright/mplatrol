import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

ProcessResultX _result({int exitCode = 0, String stdout = '', String stderr = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: stderr);

const _gbKb = 1024 * 1024;

void _old(String path, {int days = 40}) {
  final when = DateTime.now().subtract(Duration(days: days));
  final stamp = '${when.year}${_two(when.month)}${_two(when.day)}${_two(when.hour)}${_two(when.minute)}';
  expect(Process.runSync('touch', ['-h', '-t', stamp, path]).exitCode, 0);
}

String _two(int value) => value.toString().padLeft(2, '0');

String _mk(String path, {int? days, bool file = false}) {
  if (file) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
  } else {
    Directory(path).createSync(recursive: true);
  }
  if (days != null) {
    _old(path, days: days);
  }
  return path;
}

void main() {
  late MplatrolShell shell;
  late MplatrolLogger logger;
  late PlatformWrapper platform;
  late Directory home;
  late List<List<String>> trashed;
  late DiskJanitor janitor;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    logger = getDep<MplatrolLogger>();
    platform = getDep<PlatformWrapper>();
    janitor = getDep<DiskJanitor>();
    home = Directory(Directory.systemTemp.createTempSync('janitor_home').resolveSymbolicLinksSync());
    when(() => platform.environment).thenReturn({'HOME': home.path});
    when(() => platform.isMac).thenReturn(true);
    when(() => shell.whichSync('trash')).thenReturn('/usr/bin/trash');
    trashed = [];
    when(() => shell.runArgs('trash', any(), throwOnError: false, silent: true)).thenAnswer((invocation) async {
      trashed.add(invocation.positionalArguments[1] as List<String>);
      return _result();
    });
    when(() => shell.runArgs('du', any(), throwOnError: false, silent: true)).thenAnswer((invocation) async {
      final paths = (invocation.positionalArguments[1] as List<String>).skip(1);
      final trash = paths.length == 1 && paths.single.endsWith('.Trash');
      return _result(stdout: [for (final path in paths) '${trash ? 25 * _gbKb : _gbKb}\t$path'].join('\n'));
    });
    when(() => shell.runArgs('df', any(), throwOnError: false, silent: true)).thenAnswer(
        (_) async => _result(stdout: 'Filesystem 1024-blocks Used Available\n/dev/disk 1 1 ${30 * _gbKb} 9% /\n'));
    when(() => shell.runArgs('xcrun', any(), throwOnError: false, silent: true)).thenAnswer((_) async => _result());
  });

  tearDown(() => home.deleteSync(recursive: true));

  String at(String rel) => p.join(home.path, rel);

  /// A Flutter app checkout under [rel] last built [days] ago.
  String checkout(String rel, {required int days}) {
    final path = at(rel);
    _mk(p.join(path, 'pubspec.yaml'), file: true, days: days);
    _mk(p.join(path, 'android'), days: days);
    _mk(p.join(path, 'ios', 'build', 'xcui-lt'), days: days);
    _mk(p.join(path, 'ios', 'build'), days: days);
    _mk(p.join(path, 'ios'), days: days);
    _mk(p.join(path, 'build', 'app'), days: days);
    _mk(p.join(path, 'build'), days: days);
    _old(path, days: days);
    return path;
  }

  DiskCleanOptions options({
    bool dryRun = false,
    String? current,
    List<String> roots = const [],
    List<String> logDirs = const [],
    List<String> videoDirs = const [],
  }) =>
      DiskCleanOptions(
        dryRun: dryRun,
        aggressive: false,
        checkout: current,
        roots: roots,
        keep: const [],
        logDirs: logDirs,
        videoDirs: videoDirs,
      );

  group('clean', () {
    test('moves every category to the Trash, deletes unavailable simulators and nags about the Trash', () async {
      final current = checkout('wt/current', days: 0);
      checkout('wt/idle', days: 10);
      final oldXcresults = [for (var i = 0; i < 4; i++) _mk(p.join(current, 'build', 'r$i.xcresult'), days: 9 - i)];
      final oldReport = _mk(p.join(current, '.mplatrol', 'reports', 'old.json'), file: true, days: 40);
      final derived = _mk(at('Library/Developer/Xcode/DerivedData/Runner-x'), days: 5);
      _mk(at('Library/Developer/Xcode/DerivedData/ModuleCache.noindex'), days: 5);
      final ds = at('Library/Developer/Xcode/iOS DeviceSupport');
      final oldDs = _mk(p.join(ds, 'iPhone 18.0 (1)'));
      _mk(p.join(ds, 'iPhone 26.1 (2)'));
      _mk(p.join(ds, 'iPhone 26.3 (3)'));
      final record = _mk(at('.mplatrol/lt-artifacts/ios-abc.json'), file: true, days: 8);
      final oldLog = _mk(at('matrix-logs/2026-08-01'), days: 40);
      final video = _mk(at('scratch/v.mp4'), file: true, days: 8);

      final gb = await janitor.clean(
          options(current: current, roots: [at('wt')], logDirs: [at('matrix-logs')], videoDirs: [at('scratch')]));

      final moved = trashed.expand((batch) => batch).toList();
      expect(
          moved,
          unorderedEquals([
            at('wt/idle/build/app'),
            at('wt/idle/ios/build'),
            oldXcresults.first,
            derived,
            oldDs,
            record,
            oldReport,
            oldLog,
            video,
          ]));
      expect(gb, moved.length);
      verify(() => shell.runArgs('xcrun', ['simctl', 'delete', 'unavailable'], throwOnError: false, silent: true))
          .called(1);
      verify(() => logger.info(any(that: startsWith('Before: Disk: 30.0 GB free')))).called(1);
      verify(() => logger.info('Moved ${moved.length}.0 GB to the Trash.')).called(1);
      verify(() => logger.warn('The Trash holds 25.0 GB: empty the Trash to reclaim 25.0 GB.')).called(1);
    });

    test('a dry run lists but moves nothing and runs no simctl', () async {
      _mk(at('Library/Developer/Xcode/DerivedData/Runner-x'), days: 5);

      final gb = await janitor.clean(options(dryRun: true));

      expect(gb, 1);
      expect(trashed, isEmpty);
      verifyNever(() => shell.runArgs('xcrun', any(), throwOnError: false, silent: true));
      verify(() => logger.info('Would move 1.0 GB to the Trash.')).called(1);
      verify(() => logger.info(any(that: contains('would run `xcrun simctl delete unavailable`')))).called(1);
    });

    test('off macOS and without HOME it only prunes the given directories', () async {
      when(() => platform.isMac).thenReturn(false);
      when(() => platform.environment).thenReturn(const {});
      _mk(at('Library/Developer/Xcode/DerivedData/Runner-x'), days: 5);

      expect(await janitor.clean(options()), 0);
      expect(trashed, isEmpty);
      verify(() => logger.info('· videos older than 7 days: nothing to move')).called(1);
      verifyNever(() => shell.runArgs('xcrun', any(), throwOnError: false, silent: true));
    });

    test('reports a failed simctl and asks to empty the Trash when its size is unreadable', () async {
      _mk(at('Library/Developer/Xcode/DerivedData/Runner-x'), days: 5);
      when(() => shell.runArgs('xcrun', any(), throwOnError: false, silent: true))
          .thenAnswer((_) async => _result(exitCode: 1, stderr: 'no xcode\n'));
      when(() => shell.runArgs('du', ['-sk', at('.Trash')], throwOnError: false, silent: true))
          .thenAnswer((_) async => _result(exitCode: 1));

      await janitor.clean(options());

      verify(() => logger.info(any(that: contains('xcrun simctl failed (no xcode)')))).called(1);
      verify(() => logger.warn('Empty the Trash to reclaim the 1.0 GB moved there.')).called(1);
    });

    test('says nothing about the Trash when it is small', () async {
      when(() => shell.runArgs('du', ['-sk', at('.Trash')], throwOnError: false, silent: true))
          .thenAnswer((_) async => _result(stdout: '1\t${at('.Trash')}'));

      await janitor.clean(options());

      verifyNever(() => logger.warn(any()));
    });
  });

  group('afterRun', () {
    test('moves finished job tools, old xcresults and reports of the checkout and leg dir', () async {
      final repo = checkout('repo', days: 0);
      final lt = _mk(p.join(repo, 'LT'), file: true, days: 1);
      final legLt = _mk(at('leg/hyperexecute/ios/.mplatrol/he-jobs/iOS-a/LT'), file: true, days: 1);
      final report = _mk(p.join(repo, '.mplatrol', 'reports', 'r.json'), file: true, days: 40);

      await janitor.afterRun(checkout: repo, legDir: at('leg'));

      expect(trashed.single, unorderedEquals([lt, report, legLt]));
      verify(() => logger.info(any(that: startsWith('[auto-clean] moved 3 old run output(s)')))).called(1);
    });

    test('leaves a released checkout to the next leg and prunes only the leg dir', () async {
      final repo = checkout('repo', days: 0);
      _mk(p.join(repo, 'LT'), file: true, days: 1);
      _mk(p.join(repo, '.mplatrol', 'reports', 'r.json'), file: true, days: 40);
      final legLt = _mk(at('leg/hyperexecute/android/LT'), file: true, days: 1);

      await janitor.afterRun(checkout: repo, legDir: at('leg'), checkoutReleased: true);

      expect(trashed.single, [legLt]);
    });

    test('does nothing when MPLATROL_IT_AUTO_CLEAN=off, nothing is old, or there is no trash command', () async {
      final repo = checkout('repo', days: 0);
      await janitor.afterRun(checkout: repo);
      _mk(p.join(repo, 'LT'), file: true, days: 1);
      when(() => platform.environment).thenReturn({itAutoCleanEnv: ' OFF '});
      await janitor.afterRun(checkout: repo);
      when(() => platform.environment).thenReturn(const {});
      when(() => shell.whichSync('trash')).thenReturn(null);
      await janitor.afterRun(checkout: repo);

      expect(trashed, isEmpty);
    });

    test('never fails the run', () async {
      final repo = checkout('repo', days: 0);
      _mk(p.join(repo, 'LT'), file: true, days: 1);
      when(() => shell.runArgs('du', any(), throwOnError: false, silent: true)).thenThrow(StateError('boom'));

      await janitor.afterRun(checkout: repo);

      verify(() => logger.warn('[auto-clean] skipped: Bad state: boom')).called(1);
    });
  });
}
