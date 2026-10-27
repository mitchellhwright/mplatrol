import 'dart:io';

import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:test/test.dart';

const _fixtureRoot = 'test/fixtures/patrol_ios_text_input';
const _sourcePath = 'darwin/patrol/Sources/PatrolImpl/AutomatorServer/Automator/IOSAutomator.swift';

void main() {
  late String upstream;

  setUpAll(() {
    upstream = File('$_fixtureRoot/upstream_methods.swift').readAsStringSync();
  });

  test('actual upstream field and indexed input bodies remain intact', () {
    final patched = patchPatrolIosTextInputSource(upstream);
    expect(patched, contains('app.descendants(matching: .textView)'));
    final existing = upstream.substring(upstream.indexOf('      var data = data'));
    final beforeClear = existing.substring(0, existing.indexOf('    private func clearAndEnterText('));
    expect(patched, contains(beforeClear));
    expect(patched, contains(upstream.substring(upstream.indexOf('    private func clearAndEnterText('))));
    expect(patchPatrolIosTextInputSource(patched), patched);
  });

  test('changed and ambiguous upstream anchors fail rather than half-patching', () {
    for (final changed in [
      upstream.replaceFirst('on selector: IOSSelector,', 'on changed: IOSSelector,'),
      '$upstream$upstream',
      upstream.replaceFirst('element.typeText(delete + data)', 'element.typeText(data)'),
    ]) {
      expect(() => patchPatrolIosTextInputSource(changed), throwsStateError);
    }
  });

  test('missing optional-count predicate anchor fails rather than patching', () {
    final changed = upstream.replaceAll('let textFieldPredicate = NSPredicate(format: "elementType == 49")',
        'let textFieldPredicate = NSPredicate(format: "elementType == 0")');
    expect(
        () => patchPatrolIosTextInputSource(changed),
        throwsA(
            isA<StateError>().having((error) => error.message, 'message', contains('text-input source is missing'))));
  });

  test('incomplete previous patch fails with regeneration guidance', () {
    final patched =
        patchPatrolIosTextInputSource(upstream).replaceFirst('guard usable.count == 1', 'guard usable.count > 0');
    expect(() => patchPatrolIosTextInputSource(patched), throwsStateError);
  });

  test('patches only generated native source, idempotently', () {
    final root = Directory.systemTemp.createTempSync('patrol-text-input-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/$_sourcePath');
    source.parent.createSync(recursive: true);
    source.writeAsStringSync(upstream);
    expect(hasPatrolIosTextInputPatch(root), isFalse);
    patchPatrolIosTextInput(root);
    expect(hasPatrolIosTextInputPatch(root), isTrue);
    final patched = source.readAsStringSync();
    final unchangedTime = DateTime.utc(2000);
    source.setLastModifiedSync(unchangedTime);
    patchPatrolIosTextInput(root);
    expect(source.readAsStringSync(), patched);
    expect(source.lastModifiedSync().toUtc(), unchangedTime);
    source.writeAsStringSync(patched.replaceFirst('guard usable.count == 1', 'guard usable.count > 0'));
    expect(hasPatrolIosTextInputPatch(root), isFalse);
  });

  test('missing source fails with the missing path', () {
    final root = Directory.systemTemp.createTempSync('patrol-text-input-missing-');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(hasPatrolIosTextInputPatch(root), isFalse);
    expect(() => patchPatrolIosTextInput(root), throwsA(isA<FileSystemException>()));
  });

  test('patched upstream Swift compiles and executes input fixture behavior', () async {
    final root = Directory.systemTemp.createTempSync('patrol-text-input-swift-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/main.swift');
    final harness = File('$_fixtureRoot/harness.swift').readAsStringSync();
    source.writeAsStringSync(
        harness.replaceFirst('// INSERT_ACTUAL_PATCHED_UPSTREAM_METHODS', patchPatrolIosTextInputSource(upstream)));
    final executable = '${root.path}/fixture';
    final compiled = await Process.run('/usr/bin/swiftc', [source.path, '-o', executable]);
    expect(compiled.exitCode, 0, reason: '${compiled.stdout}\n${compiled.stderr}');
    if (compiled.exitCode != 0) {
      return;
    }
    final run = await Process.run(executable, []);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('SWIFT_INPUT_FIXTURE_PASSED 15'));
  }, testOn: 'mac-os');
}
