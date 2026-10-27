import 'dart:io';

import 'package:mplatrol/src/patrol_android_native_views_patch.dart';
import 'package:test/test.dart';

void main() {
  final upstream = File('test/fixtures/patrol_android_native_views/upstream.kt').readAsStringSync();
  test('actual Java bridge preserves acquisition errors; swallowing mutation is red',
      () => _runAndroidSnapshotBoundaryFixture(upstream),
      testOn: 'mac-os');
  test('preserves selector and clips acquired node fields without live getters', () {
    final patched = patchPatrolAndroidNativeViewsSource(upstream);
    expect(patched, contains('PatrolNativeSnapshot.findMatches(uiDevice, selector)'));
    expect(patched, contains('PatrolNativeSnapshot.visibleBounds(device, obj)'));
    expect(patched, contains('obj.viewIdResourceName'));
    expect(patched, contains('obj.packageName?.toString()'));
    expect(patched, contains('if (child.isVisibleToUser)'));
    expect(patched, contains('throw IllegalStateException("Native snapshot child disappeared")'));
    expect(patched, isNot(contains('uiDevice.findObjects(selector)')));
    expect(patched, isNot(contains('fromUiObject2(')));
    expect(patched, isNot(contains('catch')));
    expect(patchPatrolAndroidNativeViewsSource(patched), patched);
  });
  test('unknown duplicate and incomplete serializer fails closed', () {
    final patched = patchPatrolAndroidNativeViewsSource(upstream);
    for (final source in [
      '',
      '$upstream$upstream',
      upstream.replaceFirst('applicationPackage = obj.applicationPackage', 'applicationPackage = null'),
      upstream.replaceFirst('findObjects(selector)', 'findObjects(otherSelector)'),
      patched.replaceFirst('nodes.map', 'nodes.filter'),
    ]) {
      expect(() => patchPatrolAndroidNativeViewsSource(source), throwsStateError);
    }
  });
  test('version-bound prepared bridge is exact and unchanged prepare preserves timestamps', () {
    final root = Directory.systemTemp.createTempSync('android-native-snapshot-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/$patrolAndroidNativeViewsSourcePath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(upstream);
    final gradle = File('${root.path}/android/build.gradle');
    gradle.writeAsStringSync('api "androidx.test.uiautomator:uiautomator:2.3.0"');
    expect(hasPatrolAndroidNativeViewsPatch(root), isFalse);
    patchPatrolAndroidNativeViews(root);
    expect(hasPatrolAndroidNativeViewsPatch(root), isTrue);
    file.setLastModifiedSync(DateTime.utc(2000));
    patchPatrolAndroidNativeViews(root);
    expect(file.lastModifiedSync().toUtc(), DateTime.utc(2000));
    final legacy = File('${root.path}/android/src/main/kotlin/androidx/test/uiautomator/'
        'PatrolNativeSnapshot.java');
    legacy.parent.createSync(recursive: true);
    legacy.writeAsStringSync('old candidate bridge');
    expect(hasPatrolAndroidNativeViewsPatch(root), isFalse);
    expect(() => patchPatrolAndroidNativeViews(root), throwsStateError);
    legacy.deleteSync();
    final bridge = File('${root.path}/android/src/main/java/androidx/test/uiautomator/'
        'PatrolNativeSnapshot.java');
    final prepared = bridge.readAsStringSync();
    bridge.writeAsStringSync('$prepared\n// local edit');
    expect(() => patchPatrolAndroidNativeViews(root),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('snapshot bridge changed'))));
    bridge.writeAsStringSync(prepared);
    for (final dependency in [
      'api "androidx.test.uiautomator:uiautomator:2.4.0"',
      '''api "androidx.test.uiautomator:uiautomator:2.3.0"
api "androidx.test.uiautomator:uiautomator:2.4.0"''',
      '''api "androidx.test.uiautomator:uiautomator:2.3.0"
api "androidx.test.uiautomator:uiautomator:2.3.0"''',
      'api "androidx.test.uiautomator:uiautomator:2.+"',
      '// api "androidx.test.uiautomator:uiautomator:2.3.0"',
      'println "androidx.test.uiautomator:uiautomator:2.3.0"',
    ]) {
      gradle.writeAsStringSync(dependency);
      expect(hasPatrolAndroidNativeViewsPatch(root), isFalse);
      expect(() => patchPatrolAndroidNativeViews(root), throwsStateError);
    }
    gradle.deleteSync();
    expect(hasPatrolAndroidNativeViewsPatch(root), isFalse);
  });
}

Future<void> _runAndroidSnapshotBoundaryFixture(String upstream) async {
  final root = Directory.systemTemp.createTempSync('android-snapshot-jvm-');
  addTearDown(() => root.deleteSync(recursive: true));
  final file = File('${root.path}/$patrolAndroidNativeViewsSourcePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(upstream);
  File('${root.path}/android/build.gradle').writeAsStringSync('api "androidx.test.uiautomator:uiautomator:2.3.0"');
  patchPatrolAndroidNativeViews(root);
  final bridge = File('${root.path}/android/src/main/java/androidx/test/uiautomator/'
      'PatrolNativeSnapshot.java');
  final fixtures = Directory('test/fixtures/patrol_android_native_views/jvm')
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path)
      .toList();
  final javaHome = Platform.environment['JAVA_HOME'];
  String executable(String name) => javaHome == null ? name : '$javaHome/bin/$name';
  final compile =
      await Process.run(executable('javac'), ['-Xlint:all', '-Werror', '-d', root.path, bridge.path, ...fixtures]);
  expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  final run = await Process.run(executable('java'), ['-cp', root.path, 'androidx.test.uiautomator.Harness']);
  expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  expect(run.stdout, contains('JAVA_SNAPSHOT_BOUNDARY_PASSED cases=7'));
  bridge.writeAsStringSync(bridge.readAsStringSync().replaceFirst(
      'return ByMatcher.findMatches(device, selector, roots);',
      'try { return ByMatcher.findMatches(device, selector, roots); } '
          'catch (RuntimeException error) { return java.util.Collections.emptyList(); }'));
  final mutationCompile =
      await Process.run(executable('javac'), ['-Xlint:all', '-Werror', '-d', root.path, bridge.path, ...fixtures]);
  expect(mutationCompile.exitCode, 0);
  final mutationRun = await Process.run(executable('java'), ['-cp', root.path, 'androidx.test.uiautomator.Harness']);
  expect(mutationRun.exitCode, isNot(0));
  expect(mutationRun.stderr, contains('native failure became absence'));
}
