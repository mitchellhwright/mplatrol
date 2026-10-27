import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _ConfigFile extends Mock implements File {}

final class _ConfigOverrides extends IOOverrides {
  _ConfigOverrides(this.files);

  final Map<String, File> files;

  @override
  File createFile(String path) => files[path] ?? super.createFile(path);
}

void main() {
  _registerBoundaryTests();
  _registerRealFileTests();
  _registerExistingXcconfigTests();
}

void _registerBoundaryTests() {
  for (final ios in [false, true]) {
    for (final state in ['identical', 'changed', 'missing', 'read error']) {
      test('${ios ? 'xcconfig' : 'runtime asset'} $state exact-byte write', () {
        final repo = Directory.systemTemp.createTempSync('mplatrol-config-boundary-');
        addTearDown(() => repo.deleteSync(recursive: true));
        final paths = _paths(repo.path, ios);
        final expected = _expected(ios);
        final files = <String, File>{};
        final writes = <String, String>{};
        final failure = FileSystemException('Config read denied', paths.first);
        for (final path in paths) {
          final file = _ConfigFile();
          files[path] = file;
          when(file.existsSync).thenReturn(state != 'missing');
          when(file.readAsStringSync).thenReturn(ios ? 'DART_DEFINES=old\n' : 'old');
          if (state == 'identical') {
            when(file.readAsStringSync).thenReturn(expected);
          }
          when(file.readAsBytesSync).thenAnswer((_) {
            if (state == 'read error') {
              throw failure;
            }
            return utf8.encode(state == 'identical' ? expected : 'old');
          });
          when(() => file.writeAsStringSync(any())).thenAnswer((call) {
            writes[path] = call.positionalArguments.single as String;
          });
        }
        IOOverrides.runWithIOOverrides(() {
          if (state == 'read error') {
            expect(() => _write(repo.path, ios), throwsA(same(failure)));
          } else {
            _write(repo.path, ios);
          }
        }, _ConfigOverrides(files));
        if (state == 'identical' || state == 'read error') {
          expect(writes, isEmpty);
        } else {
          expect(writes, {for (final path in paths) path: expected});
        }
      });
    }
  }
}

void _registerRealFileTests() {
  for (final ios in [false, true]) {
    test('${ios ? 'xcconfig' : 'runtime asset'} preserves identical mtime and mode', () {
      final repo = Directory.systemTemp.createTempSync('mplatrol-config-mtime-');
      addTearDown(() => repo.deleteSync(recursive: true));
      _write(repo.path, ios);
      final files = _paths(repo.path, ios).map(File.new).toList();
      final before = <String, FileStat>{};
      for (final file in files) {
        file.setLastModifiedSync(DateTime.utc(2001));
        before[file.path] = file.statSync();
      }
      _write(repo.path, ios);
      for (final file in files) {
        expect(file.readAsBytesSync(), utf8.encode(_expected(ios)));
        expect(file.statSync().modified, before[file.path]!.modified);
        expect(file.statSync().mode, before[file.path]!.mode);
      }
      _write(repo.path, ios, changed: true);
      for (final file in files) {
        expect(file.readAsBytesSync(), utf8.encode(_expected(ios, changed: true)));
        expect(file.statSync().modified, isNot(before[file.path]!.modified));
        expect(file.statSync().mode, before[file.path]!.mode);
      }
    });
  }
}

List<String> _paths(String repo, bool ios) => ios
    ? [
        for (final name in ['Debug', 'Profile', 'Release']) p.join(repo, 'ios', 'Flutter', '$name.xcconfig')
      ]
    : [p.join(repo, runtimeE2eAssetConfigFile)];

String _expected(bool ios, {bool changed = false}) {
  final value = changed ? 'Changed' : 'Staging';
  return ios
      ? 'DART_DEFINES=${base64Encode(utf8.encode('E2E_ENVIRONMENT=$value'))}\n'
      : '${const JsonEncoder.withIndent('  ').convert({'E2E_ENVIRONMENT': value})}\n';
}

void _write(String repo, bool ios, {bool changed = false}) {
  final value = changed ? 'Changed' : 'Staging';
  if (ios) {
    writeIosDartDefines(repo, ['E2E_ENVIRONMENT=$value']);
  } else {
    writeE2eRuntimeAssetConfig(repo, {'E2E_ENVIRONMENT': value});
  }
}

void _registerExistingXcconfigTests() {
  final encoded = base64Encode(utf8.encode('E2E_ENVIRONMENT=Staging'));
  final definition = 'DART_DEFINES=$encoded';
  final cases = <String, (String, String)>{
    'replace': ('HEADER=keep\nDART_DEFINES=old\nTAIL=keep\n', 'HEADER=keep\n$definition\nTAIL=keep\n'),
    'append': ('HEADER=keep\n', 'HEADER=keep\n$definition\n'),
    'CRLF': ('HEADER=keep\r\nDART_DEFINES=old\r\nTAIL=keep\r\n', 'HEADER=keep\r\n$definition\r\nTAIL=keep\r\n'),
    'multiple definitions preserve first-match behavior': (
      'DART_DEFINES=old\nDART_DEFINES=second\n',
      '$definition\nDART_DEFINES=second\n'
    ),
  };
  for (final entry in cases.entries) {
    test('xcconfig ${entry.key} then identical call writes nothing', () {
      final repo = Directory.systemTemp.createTempSync('mplatrol-config-existing-');
      addTearDown(() => repo.deleteSync(recursive: true));
      final paths = _paths(repo.path, true);
      final contents = {for (final path in paths) path: entry.value.$1};
      final counts = {for (final path in paths) path: 0};
      final files = _existingConfigFiles(contents, counts);
      IOOverrides.runWithIOOverrides(() {
        _write(repo.path, true);
        expect(contents, {for (final path in paths) path: entry.value.$2});
        expect(counts.values, everyElement(1));
        _write(repo.path, true);
        expect(contents, {for (final path in paths) path: entry.value.$2});
        expect(counts.values, everyElement(1));
      }, _ConfigOverrides(files));
    });
  }
}

Map<String, File> _existingConfigFiles(Map<String, String> contents, Map<String, int> counts) {
  final files = <String, File>{};
  for (final path in contents.keys) {
    final file = _ConfigFile();
    files[path] = file;
    when(file.existsSync).thenReturn(true);
    when(file.readAsStringSync).thenAnswer((_) => contents[path]!);
    when(file.readAsBytesSync).thenAnswer((_) => utf8.encode(contents[path]!));
    when(() => file.writeAsStringSync(any())).thenAnswer((call) {
      contents[path] = call.positionalArguments.single as String;
      counts[path] = counts[path]! + 1;
    });
  }
  return files;
}
