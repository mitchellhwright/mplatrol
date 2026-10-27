import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/credentials/credential_provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CredentialRequest _request(
        {String tenant = 'acme',
        String environment = 'staging',
        String? userType,
        Map<String, String> env = const {},
        String repo = '/repo'}) =>
    CredentialRequest(repo: repo, tenant: tenant, environment: environment, userType: userType, env: env);

void main() {
  group('EnvCredentialProvider', () {
    test('reads the primary login and numbered extra logins until one is missing', () async {
      final logins = await const EnvCredentialProvider().logins(_request(env: const {
        'MPLATROL_CRED_USERNAME': ' first ',
        'MPLATROL_CRED_PASSWORD': 'p1',
        'MPLATROL_CRED_OTP': '123456',
        'MPLATROL_CRED_2_USERNAME': 'second',
        'MPLATROL_CRED_2_PASSWORD': 'p2',
        'MPLATROL_CRED_4_USERNAME': 'skipped-gap',
        'MPLATROL_CRED_4_PASSWORD': 'p4',
      }));

      expect([for (final login in logins) login.username], ['first', 'second']);
      expect(logins.first.oneTimeCode, '123456');
      expect(logins.first.environment, 'staging');
    });

    test('has no login without a username or password, and honours its prefix', () async {
      expect(await const EnvCredentialProvider().logins(_request(env: const {'MPLATROL_CRED_USERNAME': 'u'})), isEmpty);
      final logins = await const EnvCredentialProvider(prefix: 'APP_')
          .logins(_request(env: const {'APP_USERNAME': 'u', 'APP_PASSWORD': 'p'}));
      expect(logins.single.username, 'u');
    });
  });

  group('FileCredentialProvider', () {
    late Directory repo;
    setUp(() => repo = Directory.systemTemp.createTempSync('credential_file'));
    tearDown(() => repo.deleteSync(recursive: true));

    void write(Object? json, {String path = '.mplatrol/credentials.json'}) => File(p.join(repo.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(json));

    test('keeps the logins whose tenant, environment and user type match, in file order', () async {
      write({
        'logins': [
          {'tenant': 'acme', 'environment': 'staging', 'username': 'a1', 'password': 'p', 'otp': '111111'},
          {'tenant': 'globex', 'username': 'g1', 'password': 'p'},
          {
            'username': 'any',
            'password': 'p',
            'extra': {'ACCOUNT': 1234}
          },
          {'tenant': 'ACME', 'environment': 'qa', 'username': 'qa-only', 'password': 'p'},
          {'tenant': 'acme', 'userType': 'business', 'username': 'biz', 'password': 'p'},
        ],
      });
      const provider = FileCredentialProvider();

      final logins = await provider.logins(_request(repo: repo.path));
      expect([for (final login in logins) login.username], ['a1', 'any', 'biz']);
      expect(logins[1].extra, {'ACCOUNT': '1234'});
      final business = await provider.logins(_request(repo: repo.path, userType: 'business'));
      expect([for (final login in business) login.username], ['a1', 'any', 'biz']);
      final retail = await provider.logins(_request(repo: repo.path, userType: 'retail'));
      expect([for (final login in retail) login.username], ['a1', 'any']);
    });

    test('a missing file has no logins; an absolute path is read as is', () async {
      expect(await const FileCredentialProvider().logins(_request(repo: repo.path)), isEmpty);
      write({
        'logins': [
          {'username': 'u', 'password': 'p'}
        ]
      }, path: 'elsewhere.json');
      final logins =
          await FileCredentialProvider(path: p.join(repo.path, 'elsewhere.json')).logins(_request(repo: '/nowhere'));
      expect(logins.single.username, 'u');
    });

    for (final (name, json) in [
      ('no logins list', {'users': []}),
      (
        'a login that is not an object',
        {
          'logins': ['u']
        }
      ),
      (
        'a login without a password',
        {
          'logins': [
            {'username': 'u'}
          ]
        }
      ),
    ]) {
      test('rejects $name', () async {
        write(json);
        await expectLater(const FileCredentialProvider().logins(_request(repo: repo.path)), throwsFormatException);
      });
    }
  });

  test('TestLogin serves the fallback code only when it has none of its own', () {
    const withCode = TestLogin(environment: 'qa', username: 'u', password: 'p', oneTimeCode: ' 222222 ');
    const without = TestLogin(environment: 'qa', username: 'u', password: 'p', extra: {'K': 'v'});

    expect(withCode.toPayload(fallbackOneTimeCode: '000000')['E2E_MFA_CODE'], '222222');
    expect(without.toPayload(fallbackOneTimeCode: '000000'), {
      'K': 'v',
      'E2E_ENVIRONMENT': 'qa',
      'E2E_USERNAME': 'u',
      'E2E_PASSWORD': 'p',
      'E2E_MFA_CODE': '000000',
    });
  });

  test('CredentialProvider.fromConfig picks the configured provider', () {
    expect(CredentialProvider.fromConfig(CredentialsOptions(null)), isA<EnvCredentialProvider>());
    expect(CredentialProvider.fromConfig(CredentialsOptions({'provider': 'file', 'file': 'c.json'})),
        isA<FileCredentialProvider>().having((provider) => provider.path, 'path', 'c.json'));
    expect(() => CredentialProvider.fromConfig(CredentialsOptions({'provider': 'vault'})), throwsArgumentError);
  });
}
