import 'dart:io';

import 'package:mplatrol/src/disk/janitor_planner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _now = DateTime(2026, 10, 3, 12);

/// Sets [path]'s modification time to [daysAgo] days before [_now] (directories included).
void _age(String path, {required num daysAgo}) {
  final when = _now.subtract(Duration(minutes: (daysAgo * 24 * 60).round()));
  final stamp = '${when.year}${_two(when.month)}${_two(when.day)}${_two(when.hour)}${_two(when.minute)}';
  final result = Process.runSync('touch', ['-h', '-t', stamp, path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

String _two(int value) => value.toString().padLeft(2, '0');

String _dir(String path, {num daysAgo = 0}) {
  Directory(path).createSync(recursive: true);
  _age(path, daysAgo: daysAgo);
  return path;
}

String _file(String path, {num daysAgo = 0}) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');
  _age(path, daysAgo: daysAgo);
  return path;
}

/// A Flutter app checkout at [path] whose build and state directories were last touched [daysAgo].
String _checkout(String path, {required num daysAgo}) {
  _file(p.join(path, 'pubspec.yaml'), daysAgo: daysAgo);
  _dir(p.join(path, 'android', '.gradle'), daysAgo: daysAgo);
  _dir(p.join(path, 'android'), daysAgo: daysAgo);
  _dir(p.join(path, 'ios', 'Pods'), daysAgo: daysAgo);
  _dir(p.join(path, 'ios', 'build', 'xcui-lt'), daysAgo: daysAgo);
  _dir(p.join(path, 'ios', 'build'), daysAgo: daysAgo);
  _dir(p.join(path, 'ios'), daysAgo: daysAgo);
  _dir(p.join(path, 'build', 'app'), daysAgo: daysAgo);
  _dir(p.join(path, 'build'), daysAgo: daysAgo);
  _dir(p.join(path, '.dart_tool'), daysAgo: daysAgo);
  _dir(p.join(path, '.mplatrol', 'he-jobs'), daysAgo: daysAgo);
  _dir(p.join(path, '.mplatrol', 'patched_pub_cache'), daysAgo: daysAgo);
  _dir(p.join(path, '.mplatrol'), daysAgo: daysAgo);
  _age(path, daysAgo: daysAgo);
  return path;
}

void main() {
  late Directory tmp;
  late JanitorPlanner planner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('janitor_planner').absolute;
    tmp = Directory(tmp.resolveSymbolicLinksSync());
    planner = JanitorPlanner(now: _now);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String at(String rel) => p.join(tmp.path, rel);

  group('olderThan', () {
    test('lists old directories except named ones, and files only when asked', () {
      final old = _dir(at('dd/Runner-old'), daysAgo: 5);
      _dir(at('dd/Runner-new'), daysAgo: 1);
      _dir(at('dd/ModuleCache.noindex'), daysAgo: 9);
      final oldFile = _file(at('dd/old.log'), daysAgo: 9);

      expect(planner.olderThan(at('dd'), const Duration(days: 3), except: {'ModuleCache.noindex'}), [old]);
      expect(planner.olderThan(at('dd'), const Duration(days: 3), except: {'ModuleCache.noindex'}, files: true),
          unorderedEquals([old, oldFile]));
    });

    test('is empty for a missing directory or a symbolic link', () {
      _dir(at('real/old'), daysAgo: 9);
      Link(at('link')).createSync(at('real'));

      expect(planner.olderThan(at('missing'), Duration.zero), isEmpty);
      expect(planner.olderThan(at('link'), Duration.zero), isEmpty);
    });

    test('never lists a symbolic link inside the directory', () {
      _dir(at('target'), daysAgo: 9);
      _dir(at('dir'));
      Link(at('dir/linked')).createSync(at('target'));
      _age(at('dir/linked'), daysAgo: 9);

      expect(planner.olderThan(at('dir'), Duration.zero, files: true), isEmpty);
    });
  });

  test('oldDeviceSupport keeps the newest two iOS versions across device models', () {
    final ds = at('DeviceSupport');
    final old = [
      _dir(p.join(ds, 'iPhone17,3 18.0 (22A3351)')),
      _dir(p.join(ds, 'iPhone17,3 18.5 (22F76)')),
      _dir(p.join(ds, 'iPhone15,2 26.0.1 (23A355)')),
    ];
    _dir(p.join(ds, 'iPhone17,3 26.1 (23B85)'));
    _dir(p.join(ds, 'iPhone15,2 26.1 (23B85)'));
    _dir(p.join(ds, 'iPhone17,3 26.3 (23D127)'));
    _dir(p.join(ds, 'not a device support folder'));

    expect(planner.oldDeviceSupport(ds), unorderedEquals(old));
    expect(planner.oldDeviceSupport(at('missing')), isEmpty);
  });

  test('oldDeviceSupport orders versions numerically, missing parts as zero', () {
    final ds = at('ds');
    final oldest = _dir(p.join(ds, 'iPad 9.3 (1)'));
    _dir(p.join(ds, 'iPad 10 (2)'));
    _dir(p.join(ds, 'iPad 10.0.1 (3)'));
    _dir(p.join(ds, 'iPad 10.0.0 (4)'));

    expect(planner.oldDeviceSupport(ds, keep: 3), [oldest]);
  });

  group('checkouts', () {
    test('finds app checkouts at the root and one level down, never through links', () {
      final lane = _checkout(at('root/lane-a'), daysAgo: 0);
      final nested = _checkout(at('root/workspace/app'), daysAgo: 0);
      _file(at('root/workspace/notes.txt'));
      _dir(at('root/plain/sub'));
      Link(at('root/workspace/linked')).createSync(lane);

      expect(planner.checkouts([at('root'), at('missing')]), [lane, nested]..sort());
    });
  });

  group('staleCheckoutOutputs', () {
    test('moves outputs of idle checkouts, keeping the newest, current, kept and recent ones', () {
      final newest = _checkout(at('root/newest'), daysAgo: 0.5);
      final recent = _checkout(at('root/recent'), daysAgo: 2);
      final current = _checkout(at('root/current'), daysAgo: 10);
      final kept = _checkout(at('root/matrix-lane3'), daysAgo: 10);
      final idle = _checkout(at('root/idle'), daysAgo: 10);
      final freshEvidence = _dir(p.join(idle, 'build', 'ios_results_1.xcresult'), daysAgo: 4);
      final oldEvidence = _dir(p.join(idle, 'build', 'ios_results_0.xcresult'), daysAgo: 40);
      _dir(p.join(idle, 'build', 'reports'), daysAgo: 10);
      _age(p.join(idle, 'build'), daysAgo: 10);
      _age(idle, daysAgo: 10);
      expect(File(p.join(newest, 'pubspec.yaml')).existsSync(), isTrue);
      expect(recent, isNotEmpty);
      expect(kept, isNotEmpty);

      final paths = planner.staleCheckoutOutputs(
        planner.checkouts([at('root')]),
        current: current,
        keep: const ['', 'matrix-lane3'],
        maxIdle: const Duration(days: 3),
        evidenceMaxAge: const Duration(days: 30),
      );

      expect(
        paths,
        unorderedEquals([
          p.join(idle, 'build', 'app'),
          oldEvidence,
          p.join(idle, 'ios', 'build'),
          p.join(idle, 'android', '.gradle'),
          p.join(idle, '.mplatrol', 'he-jobs'),
        ]),
      );
      expect(paths, isNot(contains(freshEvidence)));
    });

    test('aggressive also moves pub state, Pods and the patched pub cache', () {
      _checkout(at('root/newest'), daysAgo: 0);
      final idle = _checkout(at('root/idle'), daysAgo: 10);

      final paths = planner.staleCheckoutOutputs(
        planner.checkouts([at('root')]),
        current: null,
        keep: const [],
        maxIdle: const Duration(days: 3),
        evidenceMaxAge: const Duration(days: 30),
        aggressive: true,
      );

      expect(
          paths,
          containsAll([
            p.join(idle, '.dart_tool'),
            p.join(idle, 'ios', 'Pods'),
            p.join(idle, '.mplatrol', 'patched_pub_cache'),
          ]));
    });

    test('keeps the only checkout and handles none', () {
      final only = _checkout(at('root/only'), daysAgo: 30);

      expect(
          planner.staleCheckoutOutputs([only],
              current: null, keep: const [], maxIdle: Duration.zero, evidenceMaxAge: Duration.zero),
          isEmpty);
      expect(
          planner.staleCheckoutOutputs(const [],
              current: null, keep: const [], maxIdle: Duration.zero, evidenceMaxAge: Duration.zero),
          isEmpty);
    });
  });

  test('oldXcresults keeps the newest three bundles', () {
    final checkout = at('co');
    final old = _dir(p.join(checkout, 'build', 'ios_results_1.xcresult'), daysAgo: 4);
    for (var i = 2; i <= 4; i++) {
      _dir(p.join(checkout, 'build', 'ios_results_$i.xcresult'), daysAgo: 4 - i * 0.5);
    }
    _dir(p.join(checkout, 'build', 'app'), daysAgo: 9);

    expect(planner.oldXcresults(checkout), [old]);
  });

  group('idleJobTools', () {
    test('moves tool copies of jobs whose CLI log went quiet, in the root and per-device dirs', () {
      final root = at('repo');
      final rootLt = _file(p.join(root, 'LT'), daysAgo: 1);
      _file(p.join(root, 'hyperexecute-cli.log'), daysAgo: 1);
      final busy = p.join(root, '.mplatrol', 'he-jobs', 'iOS-busy');
      _file(p.join(busy, 'LT'), daysAgo: 1);
      _file(p.join(busy, 'hyperexecute-cli.log'));
      final done = p.join(root, '.mplatrol', 'he-jobs', 'iOS-done');
      final doneCli = _dir(p.join(done, '.hyperexecute'), daysAgo: 1);
      final doneLt = _file(p.join(done, 'LT'), daysAgo: 1);
      _file(p.join(done, 'hyperexecute-cli.log'), daysAgo: 1);
      final nolog = p.join(root, '.mplatrol', 'he-jobs', 'Android-nolog');
      final nologLt = _file(p.join(nolog, 'LT'), daysAgo: 1);

      expect(planner.idleJobTools(root, idle: const Duration(hours: 1)),
          unorderedEquals([rootLt, doneLt, doneCli, nologLt]));
      expect(planner.idleJobTools(at('missing'), idle: Duration.zero), isEmpty);
    });
  });

  test('ltArtifactRecords moves expired, surplus and stale temporary records', () {
    final dir = at('lt-artifacts');
    final expired = _file(p.join(dir, 'ios-aaa-inputs-1.json'), daysAgo: 8);
    final surplus = _file(p.join(dir, 'ios-bbb.json'), daysAgo: 3);
    _file(p.join(dir, 'ios-ccc.json'), daysAgo: 2);
    _file(p.join(dir, 'ios-ddd.json'), daysAgo: 1);
    _file(p.join(dir, 'android-eee.json'), daysAgo: 3);
    final staleTmp = _file(p.join(dir, 'ios-fff.json.123.tmp'), daysAgo: 2);
    _file(p.join(dir, 'ios-ggg.json.456.tmp'));

    expect(planner.ltArtifactRecords(dir, maxAge: const Duration(days: 7), keepPerPlatform: 2),
        unorderedEquals([expired, surplus, staleTmp]));
  });

  test('oldVideos finds old videos anywhere under the directories, ignoring other files', () {
    final old = _file(at('scratch/triage/a/session.MP4'), daysAgo: 8);
    final oldMov = _file(at('scratch/b.mov'), daysAgo: 8);
    _file(at('scratch/c.webm'), daysAgo: 1);
    _file(at('scratch/device.log'), daysAgo: 30);

    expect(planner.oldVideos([at('scratch'), at('missing')], const Duration(days: 7)), unorderedEquals([old, oldMov]));
  });

  test('oldVideos and olderThan skip directories they cannot list', () {
    final locked = _dir(at('scratch/locked'));
    _file(at('scratch/locked/hidden.mp4'), daysAgo: 30);
    final visible = _file(at('scratch/v.mp4'), daysAgo: 30);
    Process.runSync('chmod', ['000', locked]);
    addTearDown(() => Process.runSync('chmod', ['755', locked]));

    expect(planner.oldVideos([at('scratch')], const Duration(days: 7)), [visible]);
    expect(planner.olderThan(locked, Duration.zero, files: true), isEmpty);
  });

  test('lastActivity is the newest time across the checkout and its build and state dirs', () {
    final checkout = _checkout(at('co'), daysAgo: 10);
    _dir(p.join(checkout, 'ios', 'build', 'fresh'), daysAgo: 1);
    _age(p.join(checkout, 'ios', 'build'), daysAgo: 10);

    expect(_now.difference(planner.lastActivity(checkout)).inHours, 24);
  });
}
