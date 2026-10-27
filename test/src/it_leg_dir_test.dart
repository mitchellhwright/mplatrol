import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

void main() {
  late Directory root;
  late String repo;
  late String leg;
  late ItLegDir legDir;

  void write(String path, String content) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  setUp(() async {
    await scaffoldMockDependencies();
    root = Directory.systemTemp.createTempSync('mplatrol_leg');
    repo = p.join(root.path, 'lane', 'app');
    leg = p.join(root.path, 'run', 'legs', 'acme_lt-ios');
    write(p.join(repo, '.mplatrol', 'test_lessons.json'), '{"schemaVersion":1,"lessons":{}}');
    write(p.join(repo, 'integration_test', 'e2e_credentials.local.json'), '{"E2E_USERNAME":"u"}');
    write(p.join(repo, '.mplatrol', 'bug-drafts', 'sig1', 'draft.json'), '{}');
    when(() => getDep<PlatformWrapper>().environment).thenReturn({itLegDirEnv: ' $leg '});
    when(() => getDep<MplatrolShell>().runArgs('git', ['rev-parse', '--short=12', 'HEAD'],
        workingDirectory: repo,
        throwOnError: false,
        silent: true)).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 0, 'abc123def456\n', '')));
    legDir = ItLegDir();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('frees the checkout once every expected variant uploaded', () async {
    var hooks = 0;
    legDir
      ..expectedUploads = 2
      ..onRelease(() async => hooks++);

    await legDir.release(repo: repo, env: const {});
    expect(legDir.released, isFalse);
    expect(legDir.expectedUploads, 1);
    expect(legDir.jobRoot(repo, 'ios'), p.join(leg, 'hyperexecute', 'ios'));
    expect(legDir.stateRepo(repo), repo);

    await legDir.release(repo: repo, env: const {});
    expect(legDir.released, isTrue);
    expect(hooks, 1);
    expect(legDir.jobRoot(repo, 'android'), p.join(leg, 'hyperexecute', 'android'));
    expect(legDir.stateRepo(repo), p.join(leg, 'state'));
    expect(File(p.join(leg, 'state', '.mplatrol', 'bug-drafts', 'sig1', 'draft.json')).readAsStringSync(), '{}');
    expect(legDir.commit, 'abc123def456');
    expect(File(p.join(leg, 'state', '.mplatrol', 'test_lessons.json')).readAsStringSync(),
        '{"schemaVersion":1,"lessons":{}}');
    expect(File(p.join(leg, 'state', 'integration_test', 'e2e_credentials.local.json')).existsSync(), isTrue);
    expect(DateTime.parse(File(p.join(leg, itCheckoutReleasedMarker)).readAsStringSync().trim()).isUtc, isTrue);
    verify(() => getDep<MplatrolLogger>().info('[lane-release] artifacts uploaded; the checkout is free for the next '
        'leg (this leg continues in $leg)')).called(1);

    await legDir.release(repo: repo, env: const {});
    expect(hooks, 1);
  });

  test('keeps the checkout when no upload is expected', () async {
    await legDir.release(repo: repo, env: const {});
    expect(legDir.released, isFalse);
    expect(legDir.jobRoot(repo, 'ios'), repo);
    expect(Directory(leg).existsSync(), isFalse);
  });

  test('keeps the checkout without a leg directory', () async {
    when(() => getDep<PlatformWrapper>().environment).thenReturn(const {});
    legDir.expectedUploads = 1;

    await legDir.release(repo: repo, env: const {});
    expect(legDir.path, isNull);
    expect(legDir.released, isFalse);
  });

  test('copies only the state that exists, and a credential file inside the checkout', () async {
    File(p.join(repo, '.mplatrol', 'test_lessons.json')).deleteSync();
    Directory(p.join(repo, '.mplatrol', 'bug-drafts')).deleteSync(recursive: true);
    final outside = p.join(root.path, 'creds.json');
    write(outside, '{}');
    when(() => getDep<MplatrolShell>().runArgs('git', ['rev-parse', '--short=12', 'HEAD'],
        workingDirectory: repo,
        throwOnError: false,
        silent: true)).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 128, '', 'not a git repository')));
    legDir.expectedUploads = 1;

    await legDir.release(repo: repo, env: {'MPLATROL_E2E_DART_DEFINE_FILE': outside});

    expect(legDir.released, isTrue);
    expect(legDir.commit, isNull);
    expect(Directory(p.join(leg, 'state')).existsSync(), isFalse);
  });
}
