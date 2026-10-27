import 'dart:io';

import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('e2e_defines');
  });

  tearDown(() {
    if (repo.existsSync()) {
      repo.deleteSync(recursive: true);
    }
  });

  test('returns no defines when the credential file is absent', () {
    expect(e2eDartDefineArgs(repo.path, const {}), isEmpty);
    expect(e2eDartDefineFlags(repo.path, const {}), isEmpty);
  });

  test('uses an explicit relative credential path when present', () {
    File(p.join(repo.path, 'tmp', 'e2e.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"E2E_ENVIRONMENT": "UAT"}');

    final args = e2eDartDefineArgs(repo.path, const {e2eDartDefineFileEnv: 'tmp/e2e.json'});

    expect(args, ['--dart-define=E2E_ENVIRONMENT=UAT']);
  });

  test('supports the fallback env key', () {
    final source = File(p.join(repo.path, 'fallback.json'))..writeAsStringSync('{"E2E_ENVIRONMENT": "Neo"}');

    final flags = e2eDartDefineFlags(repo.path, {e2eDartDefineFileFallbackEnv: source.path});

    expect(flags, " '--dart-define=E2E_ENVIRONMENT=Neo'");
  });

  test('enables the app proxy only while a USB phone is routed through this Mac', () {
    expect(e2eDartDefineArgs(repo.path, const {e2eDeviceProxyEnv: 'true'}),
        contains('--dart-define=E2E_ENABLE_DEVELOPER_PROXY=true'));
    expect(e2eDartDefineArgs(repo.path, const {e2eDeviceProxyEnv: 'false'}).join(' '),
        isNot(contains('E2E_ENABLE_DEVELOPER_PROXY')));
    expect(e2eDartDefineArgs(repo.path, const {}).join(' '), isNot(contains('E2E_ENABLE_DEVELOPER_PROXY')));
  });

  test('returns direct non-secret dart define args for Patrol', () {
    File(p.join(repo.path, defaultE2eDartDefineFile))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"E2E_ENVIRONMENT": "Dev", "E2E_PASSWORD": "pass"}');

    final args = e2eDartDefineArgs(repo.path, const {e2eCredentialsUrlEnv: 'http://10.0.2.2:49782/e2e?token=abc'});

    expect(args, contains('--dart-define=E2E_ENVIRONMENT=Dev'));
    expect(
      args,
      contains(
        '--dart-define=E2E_CREDENTIALS_URL='
        'http://10.0.2.2:49782/e2e?token=abc',
      ),
    );
    expect(args.join(' '), isNot(contains('E2E_PASSWORD')));
  });

  test('writes the shared runtime asset without secrets or a callback URL', () {
    File(p.join(repo.path, defaultE2eDartDefineFile))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  "E2E_ENVIRONMENT": "Dev",
  "E2E_USERNAME": "user",
  "E2E_PASSWORD": "pass",
  "E2E_MFA_CODE": "123456"
}
''');

    final path = writeE2eRuntimeAssetConfig(repo.path, const {
      e2eCredentialsUrlEnv: 'http://10.0.2.2:49782/e2e?token=abc',
    });

    expect(path, p.join(repo.path, runtimeE2eAssetConfigFile));
    final content = File(path!).readAsStringSync();
    expect(content, contains('E2E_ENVIRONMENT'));
    // A concurrent variant with a different callback host builds from the
    // same asset, so the URL travels only as a per-build define.
    expect(content, isNot(contains('E2E_CREDENTIALS_URL')));
    expect(content, isNot(contains('E2E_USERNAME')));
    expect(content, isNot(contains('E2E_PASSWORD')));
  });

  test('removes stale runtime asset config when no runtime values exist', () {
    final stale = File(p.join(repo.path, runtimeE2eAssetConfigFile))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"E2E_CREDENTIALS_URL":"stale"}');

    final path = writeE2eRuntimeAssetConfig(repo.path, const {});

    expect(path, isNull);
    expect(stale.existsSync(), isFalse);
  });
}
