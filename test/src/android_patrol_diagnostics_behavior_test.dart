@TestOn('mac-os')
library;

import 'dart:io';

import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:test/test.dart';

// JDK 17+, no Android SDK or third-party Java jars. Run with flutter test on this file.
// Both classpaths contain the actual generated base, never a stored production copy.
void main() {
  Directory? temporary;
  late String present;
  late String absent;
  late String base;
  const fixture = 'test/fixtures/android_patrol_diagnostics';
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('patrol_boundary_behavior_');
    Directory('${temporary!.path}/patrol_test').createSync();
    File('${temporary!.path}/patrol_test/observer_test.dart').writeAsStringSync("patrolTest('probe');");
    generateAndroidPatrolRunner(temporary!.path);
    base = File('${temporary!.path}/android/app/src/androidTest/java/'
            'mplatrol/e2e/PatrolDartTest.java')
        .readAsStringSync();
    await _java('javac', ['-version']);
    await _java('java', ['-version']);
    present = await _compileBoundary(temporary!, fixture, absent: false);
    absent = await _compileBoundary(temporary!, fixture, absent: true);
  });
  tearDownAll(() => temporary?.deleteSync(recursive: true));

  test('actual generated base pre-grants only location through UiDevice', () {
    _expectOnlyLocationPregrant(base);
  });
  test('pregrant guard rejects UiAutomation, adb, shell and other permissions', () {
    for (final bypass in [
      'import android.app.UiAutomation;',
      'automation.grantRuntimePermission(appPackage, permission);',
      'Runtime.getRuntime().exec("adb shell pm grant app android.permission.CAMERA");',
      'new ProcessBuilder("pm", "grant");',
      'String camera = "android.permission.CAMERA";',
      'device.executeShellCommand("appops set " + appPackage + " CAMERA allow");',
    ]) {
      expect(() => _expectOnlyLocationPregrant('$base\n$bypass'), throwsA(isA<TestFailure>()));
    }
  });

  for (final name in ['success', 'initialize', 'setup', 'wait', 'list', 'match', 'run', 'grant', 'exempt', 'absent']) {
    test('actual generated diagnostic boundary: $name', () async {
      final classpath = name == 'absent' ? absent : present;
      await _java('java', [
        '-cp',
        classpath,
        'mplatrol.e2e.BoundaryBehavior',
        name,
      ]);
    });
  }
}

Future<String> _compileBoundary(Directory root, String fixture, {required bool absent}) async {
  final output = Directory('${root.path}/${absent ? 'absent' : 'present'}')..createSync();
  final classes = '${output.path}/classes';
  Directory(classes).createSync();
  final sources = _externalSources(output, '$fixture/external_apis.java.txt', absent: absent);
  await _java('javac', [
    '-Xlint:all',
    '-Werror',
    '-d',
    classes,
    ...sources,
    '${root.path}/android/app/src/androidTest/java/mplatrol/e2e/PatrolDartTest.java',
    '$fixture/BoundaryBehavior.java',
  ]);
  return classes;
}

String _jdkTool(String tool) {
  final home = Platform.environment['JAVA_HOME'];
  return home == null || home.isEmpty ? tool : '$home/bin/$tool';
}

Future<void> _java(String tool, List<String> arguments) async {
  final executable = _jdkTool(tool);
  ProcessResult result;
  try {
    result = await Process.run(executable, arguments);
  } on ProcessException catch (error) {
    fail('JDK required: install JDK 17+ and set JAVA_HOME or put javac/java on PATH. '
        'Unable to execute $executable: ${error.message}');
  }
  expect(result.exitCode, 0,
      reason: 'JDK 17+ required (JAVA_HOME or javac/java on PATH). '
          'Failed: $executable ${arguments.join(' ')}\n'
          '${result.stdout}\n${result.stderr}');
}

List<String> _externalSources(Directory output, String fixture, {bool absent = false}) {
  final sources = <String>[];
  for (final section in File(fixture).readAsStringSync().split('// FILE ').skip(1)) {
    final newline = section.indexOf('\n');
    final relative = section.substring(0, newline).trim();
    if (absent && relative.endsWith('/NativeActivityDiagnostics.java')) {
      continue;
    }
    final file = File('${output.path}/$relative')..createSync(recursive: true);
    file.writeAsStringSync(section.substring(newline + 1));
    sources.add(file.path);
  }
  return sources;
}

void _expectOnlyLocationPregrant(String source) {
  final forbidden = RegExp(
    r'\b(UiAutomation|getUiAutomation|grantRuntimePermission|'
    r'grantDeclaredRuntimePermissions|ProcessBuilder|adb|Runtime)\b',
  );
  expect(forbidden.hasMatch(source), isFalse,
      reason: 'Only the shared UiDevice may pre-grant; no UiAutomation, adb or exec.');
  final permissions = RegExp(r'android\.permission\.[A-Z_]+').allMatches(source).map((match) => match.group(0)).toSet();
  expect(
      permissions,
      {
        'android.permission.ACCESS_FINE_LOCATION',
        'android.permission.ACCESS_COARSE_LOCATION',
      },
      reason: 'Only location permissions may be pre-granted.');
  final shellCalls = RegExp(r'executeShellCommand\(([^;]*)\);')
      .allMatches(source)
      .map((match) => match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim())
      .toList();
  expect(shellCalls, ['"pm grant " + appPackage + " " + permission'],
      reason: 'The only shell command is the location pm grant.');
}
