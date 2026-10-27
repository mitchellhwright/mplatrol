import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/disk_space.dart';
import 'package:test/test.dart';

import '../../helpers/helpers.dart';

ProcessResultX _result(String stdout, {int exitCode = 0, String stderr = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: stderr);

/// `df -k` output with [availableKb] available.
String dfOutput(int availableKb) => 'Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on\n'
    '/dev/disk3s1 971350000 900000000 $availableKb 98% 1 2 1% /System/Volumes/Data\n';

const _gbKb = 1024 * 1024;

void stubDf(MplatrolShell shell, ProcessResultX result) => when(
      () => shell.runArgs('df', any(), throwOnError: false, silent: true),
    ).thenAnswer((_) async => result);

void stubDu(MplatrolShell shell, ProcessResultX result) => when(
      () => shell.runArgs('du', any(), throwOnError: false, silent: true),
    ).thenAnswer((_) async => result);

void main() {
  late MplatrolShell shell;
  late PlatformWrapper platform;
  late DiskSpace disk;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    platform = getDep<PlatformWrapper>();
    disk = getDep<DiskSpace>();
    when(() => platform.environment).thenReturn({'HOME': '/Users/me'});
  });

  group('freeGb', () {
    test('reads the Available column of df -k', () async {
      stubDf(shell, _result(dfOutput(24 * _gbKb)));

      expect(await disk.freeGb('/repo'), 24);
      verify(() => shell.runArgs('df', ['-k', '/repo'], throwOnError: false, silent: true)).called(1);
    });

    test('is null when df fails, prints no data line, or a short or non-numeric one', () async {
      for (final result in [
        _result(dfOutput(1), exitCode: 1),
        _result('Filesystem only\n'),
        _result('header\n/dev/x 1 2\n'),
        _result('header\n/dev/x 1 2 lots 9%\n'),
      ]) {
        stubDf(shell, result);
        expect(await disk.freeGb('/repo'), isNull);
      }
    });
  });

  group('sizeGb and trashGb', () {
    test('sums du -sk lines and reads the Trash', () async {
      stubDu(shell, _result('${2 * _gbKb}\t/a\n$_gbKb\t/b\nbogus\n'));

      expect(await disk.sizeGb(['/a', '/b']), 3);
      expect(await disk.trashGb(), 3);
      verify(() => shell.runArgs('du', ['-sk', '/Users/me/.Trash'], throwOnError: false, silent: true)).called(1);
    });

    test('is zero for no paths and null when du fails or HOME is unset', () async {
      stubDu(shell, _result('', exitCode: 1));

      expect(await disk.sizeGb(const []), 0);
      expect(await disk.trashGb(), isNull);
      when(() => platform.environment).thenReturn(const {});
      expect(await disk.trashGb(), isNull);
    });
  });

  group('summary', () {
    test('states free space and a large Trash with the empty-it nudge', () async {
      stubDf(shell, _result(dfOutput(30 * _gbKb)));
      stubDu(shell, _result('${25 * _gbKb}\t/Users/me/.Trash\n'));

      expect(await disk.summary('/repo'),
          'Disk: 30.0 GB free; the Trash holds 25.0 GB: empty the Trash to reclaim 25.0 GB');
    });

    test('says when free space and the Trash cannot be read', () async {
      stubDf(shell, _result('', exitCode: 1));
      stubDu(shell, _result('', exitCode: 1));

      expect(
          await disk.summary('/repo'), 'Disk: free space unknown; the Trash size is unreadable here (Finder shows it)');
    });

    test('states a small Trash plainly', () {
      expect(DiskSpace.trashText(1.25), 'the Trash holds 1.3 GB');
    });
  });

  group('lowDiskWarning', () {
    test('warns below the default 40 GB with the Trash and the clean command', () async {
      stubDf(shell, _result(dfOutput(24 * _gbKb)));
      stubDu(shell, _result('${5 * _gbKb}\t/Users/me/.Trash\n'));

      final warning = await disk.lowDiskWarning('/repo');

      expect(warning, contains('Only 24.0 GB free on the disk (below 40 GB'));
      expect(warning, contains('the Trash holds 5.0 GB'));
      expect(warning, contains('mplatrol clean --disk'));
    });

    test('is null at or above the threshold, or when df has no answer', () async {
      stubDf(shell, _result(dfOutput(40 * _gbKb)));
      expect(await disk.lowDiskWarning('/repo'), isNull);
      stubDf(shell, _result('', exitCode: 1));
      expect(await disk.lowDiskWarning('/repo'), isNull);
    });

    test('honours MPLATROL_IT_MIN_FREE_GB and ignores an invalid value', () async {
      stubDf(shell, _result(dfOutput(50 * _gbKb)));
      stubDu(shell, _result('', exitCode: 1));

      when(() => platform.environment).thenReturn({itMinFreeGbEnv: '60'});
      expect(disk.minFreeGb, 60);
      expect(await disk.lowDiskWarning('/repo'), contains('below 60 GB'));
      for (final invalid in ['0', '-5', 'lots', '']) {
        when(() => platform.environment).thenReturn({itMinFreeGbEnv: invalid});
        expect(disk.minFreeGb, DiskSpace.defaultMinFreeGb);
      }
    });
  });
}
