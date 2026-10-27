import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/local_leg_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _crashProto = '''
issue {
  severity: SEVERE
  code: 1
  name: "INSTRUMENTATION_FAILED"
  message: "Expected 31 tests, received 2. INSTRUMENTATION_ABORTED: System has crashed. \\"quoted\\""
}
''';

void main() {
  late Directory root;
  late String repo;
  late String leg;
  late String results;

  void useLegDir(String? path) =>
      when(() => getDep<PlatformWrapper>().environment).thenReturn({if (path != null) itLegDirEnv: path});

  void writeResults() {
    final device = p.join(results, 'mplatrol_e2e_pixel9(AVD) - 16');
    File(p.join(device, 'test-result.textproto'))
      ..createSync(recursive: true)
      ..writeAsStringSync(_crashProto);
    File(p.join(device, 'logcat-mplatrol.e2e.DepositSdkRdcJourneyTest-opens.txt')).writeAsStringSync('logcat');
  }

  setUp(() async {
    await scaffoldMockDependencies();
    root = Directory.systemTemp.createTempSync('leg_artifacts');
    repo = p.join(root.path, 'lane', 'app');
    leg = p.join(root.path, 'run', 'legs', 'acme_android');
    results = p.join(repo, 'build', 'app', 'outputs', 'androidTest-results', 'connected', 'debug');
    useLegDir(leg);
  });
  tearDown(() => root.deleteSync(recursive: true));

  // Regression: r12 legs failed when one file could not be copied (Operation not permitted on ~/Downloads/LT).
  group('copyEvidenceFile', () {
    test('copies evidence, and skips the tunnel and HyperExecute binaries and symbolic links', () {
      final source = Directory(p.join(root.path, 'job'))..createSync(recursive: true);
      for (final name in ['LT', 'hyperexecute', 'scenario.log']) {
        File(p.join(source.path, name)).writeAsStringSync(name);
      }
      final outside = File(p.join(root.path, 'outside.txt'))..writeAsStringSync('outside');
      Link(p.join(source.path, 'link.txt')).createSync(outside.path);
      final copied = {
        for (final name in ['LT', 'hyperexecute', 'scenario.log', 'link.txt'])
          name: copyEvidenceFile(p.join(source.path, name), p.join(leg, name), getDep<MplatrolLogger>()),
      };

      expect(copied, {'LT': false, 'hyperexecute': false, 'scenario.log': true, 'link.txt': false});
      expect(File(p.join(leg, 'scenario.log')).readAsStringSync(), 'scenario.log');
      expect(File(p.join(leg, 'link.txt')).existsSync(), isFalse);
    });

    test('a file that cannot be copied warns with its name and error, and the rest continue', () {
      final unreadable = File(p.join(root.path, 'unreadable.log'))..writeAsStringSync('secret');
      Process.runSync('chmod', ['000', unreadable.path]);
      addTearDown(() => Process.runSync('chmod', ['644', unreadable.path]));

      expect(copyEvidenceFile(unreadable.path, p.join(leg, 'unreadable.log'), getDep<MplatrolLogger>()), isFalse);
      verify(() => getDep<MplatrolLogger>().warn(any(
          that: allOf(
              startsWith('[leg-artifacts] warn: could not copy '
                  '${unreadable.path}'),
              contains('continuing without it'))))).called(1);
    });

    test('an unreadable result file does not stop the rest of the Android results', () {
      writeResults();
      final blocked = File(p.join(results, 'blocked.txt'))..writeAsStringSync('x');
      Process.runSync('chmod', ['000', blocked.path]);
      addTearDown(() => Process.runSync('chmod', ['644', blocked.path]));

      LocalLegArtifacts().keepAndroidResults(repo, results: results, since: DateTime(2000));

      final kept = p.join(leg, 'android', 'androidTest-results');
      expect(File(p.join(kept, 'mplatrol_e2e_pixel9(AVD) - 16', 'test-result.textproto')).existsSync(), isTrue);
      expect(File(p.join(kept, 'blocked.txt')).existsSync(), isFalse);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('blocked.txt')))).called(1);
    });
  });

  test('appends every run of the leg to its build log', () {
    final artifacts = LocalLegArtifacts();
    expect(artifacts.keepBuildLog(repo, variant: 'android', output: 'first tenant'), p.join(leg, 'build.log'));
    artifacts.keepBuildLog(repo, variant: 'android', output: 'second tenant');

    final log = File(p.join(leg, 'build.log')).readAsStringSync();
    expect(log, allOf(contains('===== android '), contains('first tenant\n'), contains('second tenant\n')));
    expect(artifacts.videoDirectory(repo), p.join(leg, 'video'));
    verify(() => getDep<MplatrolLogger>().info('[leg-artifacts] full android build and test output: '
        '${p.join(leg, 'build.log')}')).called(2);
  });

  test('without a leg directory keeps the build log in the checkout and the results where they are', () {
    useLegDir(null);
    writeResults();
    final artifacts = LocalLegArtifacts();

    expect(artifacts.keepBuildLog(repo, variant: 'ios', output: 'out'), p.join(repo, 'build', 'mplatrol', 'build.log'));
    expect(artifacts.keepAndroidResults(repo, results: results, since: DateTime(2000)), hasLength(1));
    artifacts.keepIosResults(repo, [p.join(repo, 'build', 'ios_results_1.xcresult')]);

    expect(artifacts.videoDirectory(repo), p.join(repo, 'build', 'e2e-videos'));
    expect(Directory(p.join(repo, 'build', 'mplatrol', 'android')).existsSync(), isFalse);
  });

  test('copies the Android results of each tenant into the leg and reads the instrumentation crash', () {
    writeResults();
    final artifacts = LocalLegArtifacts();

    final issues = artifacts.keepAndroidResults(repo, results: results, since: DateTime(2000));
    artifacts.keepAndroidResults(repo, results: results, since: DateTime(2000));

    const crash = '[android-utp] INSTRUMENTATION_FAILED: Expected 31 tests, received 2. '
        'INSTRUMENTATION_ABORTED: System has crashed. "quoted"';
    expect(issues, [crash]);
    for (final copy in ['androidTest-results', 'androidTest-results-2']) {
      expect(
          File(p.join(leg, 'android', copy, 'mplatrol_e2e_pixel9(AVD) - 16',
                  'logcat-mplatrol.e2e.DepositSdkRdcJourneyTest-opens.txt'))
              .readAsStringSync(),
          'logcat');
    }
    verify(() => getDep<MplatrolLogger>().err(issues.single)).called(2);
  });

  test('ignores an instrumentation report older than the run and missing results', () {
    writeResults();
    final artifacts = LocalLegArtifacts();

    expect(artifacts.keepAndroidResults(repo, results: results, since: DateTime.now().add(const Duration(hours: 1))),
        isEmpty);
    expect(artifacts.keepAndroidResults(repo, results: p.join(repo, 'missing'), since: DateTime(2000)), isEmpty);
  });

  test('moves the iOS result bundles of the run into the leg', () {
    final bundle = p.join(repo, 'build', 'ios_results_1.xcresult');
    File(p.join(bundle, 'Info.plist'))
      ..createSync(recursive: true)
      ..writeAsStringSync('plist');

    LocalLegArtifacts().keepIosResults(repo, [bundle, p.join(repo, 'build', 'gone.xcresult')]);

    expect(Directory(bundle).existsSync(), isFalse);
    expect(File(p.join(leg, 'ios', 'ios_results_1.xcresult', 'Info.plist')).readAsStringSync(), 'plist');
  });
}
