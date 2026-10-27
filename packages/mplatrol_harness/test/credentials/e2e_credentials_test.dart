import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mplatrol_harness/mplatrol_harness.dart';

class _Bundle extends AssetBundle {
  _Bundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final asset = assets[key];
    if (asset == null) {
      throw FlutterError('Unable to load asset: "$key".');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(asset)));
  }

  @override
  Future<T> loadStructuredData<T>(String key, Future<T> Function(String value) parser) async =>
      parser(await loadString(key));
}

void main() {
  group('E2eCredentials.fromJson', () {
    test('reads the four keys and keeps the rest as extra strings', () {
      final credentials = E2eCredentials.fromJson({
        'E2E_ENVIRONMENT': ' staging ',
        'E2E_USERNAME': ' user ',
        'E2E_PASSWORD': 'secret',
        'E2E_MFA_CODE': '123456',
        'E2E_ACCOUNT': 42,
        'E2E_FLAG': true,
        'E2E_NONE': null,
      });
      expect(credentials.environment, 'staging');
      expect(credentials.username, 'user');
      expect(credentials.password, 'secret');
      expect(credentials.oneTimeCode, '123456');
      expect(credentials.extra, {'E2E_ACCOUNT': '42', 'E2E_FLAG': 'true'});
    });

    test('uses the fallback environment when the answer names none', () {
      final credentials =
          E2eCredentials.fromJson({'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'p'}, fallbackEnvironment: ' qa ');
      expect(credentials.environment, 'qa');
      expect(credentials.oneTimeCode, isEmpty);
      expect(credentials.extra, isEmpty);
    });

    test('rejects an answer without username or password', () {
      expect(
        () => E2eCredentials.fromJson({'E2E_USERNAME': ' ', 'E2E_PASSWORD': ''}),
        throwsA(isA<FormatException>()
            .having((error) => error.message, 'message', contains('E2E_USERNAME or E2E_PASSWORD'))),
      );
    });

    test('keeps the password out of toString', () {
      final text = E2eCredentials.fromJson({'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'hunter2'}).toString();
      expect(text, isNot(contains('hunter2')));
    });
  });

  group('E2eCredentials.parse', () {
    test('parses a JSON object body', () {
      expect(E2eCredentials.parse('{"E2E_USERNAME":"u","E2E_PASSWORD":"p"}').username, 'u');
    });

    test('rejects a body that is not JSON without repeating it', () {
      expect(
        () => E2eCredentials.parse('<html>secret-page</html>'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', isNot(contains('secret-page')))),
      );
    });

    test('rejects a JSON array', () {
      expect(() => E2eCredentials.parse('[1]'), throwsFormatException);
    });
  });

  group('E2eRuntimeConfig', () {
    test('parse reads the asset keys', () {
      final config = E2eRuntimeConfig.parse('{"E2E_ENVIRONMENT":"staging","E2E_TENANT":"acme",'
          '"E2E_CREDENTIALS_URL":"http://localhost:1/e2e-credentials?token=t"}');
      expect(config.environment, 'staging');
      expect(config.tenant, 'acme');
      expect(config.credentialsUrl, 'http://localhost:1/e2e-credentials?token=t');
    });

    test('toString hides the token', () {
      final config = E2eRuntimeConfig(credentialsUrl: 'http://localhost:9/e2e-credentials?token=abc');
      expect(config.toString(), contains('http://localhost:9/e2e-credentials'));
      expect(config.toString(), isNot(contains('abc')));
    });

    test('load prefers the asset and fills gaps from the defines', () async {
      final config = await E2eRuntimeConfig.load(
        bundle:
            _Bundle({e2eRuntimeConfigAsset: '{"E2E_CREDENTIALS_URL":"http://localhost:2/e2e-credentials?token=new"}'}),
        defines:
            E2eRuntimeConfig(environment: 'staging', credentialsUrl: 'http://localhost:1/e2e-credentials?token=old'),
      );
      expect(config.credentialsUrl, 'http://localhost:2/e2e-credentials?token=new');
      expect(config.environment, 'staging');
    });

    test('load falls back to the defines without the asset', () async {
      final config = await E2eRuntimeConfig.load(bundle: _Bundle({}), defines: E2eRuntimeConfig(tenant: 'acme'));
      expect(config.tenant, 'acme');
      expect(config.credentialsUrl, isEmpty);
    });

    test('load fails on a malformed asset', () async {
      expect(
        E2eRuntimeConfig.load(bundle: _Bundle({e2eRuntimeConfigAsset: 'not json'}), defines: E2eRuntimeConfig()),
        throwsFormatException,
      );
    });

    test('fromDefines is empty in a build without defines', () {
      final config = E2eRuntimeConfig.fromDefines();
      expect(config.credentialsUrl, isEmpty);
      expect(config.environment, isEmpty);
      expect(config.tenant, isEmpty);
    });
  });

  group('describeServerUrl', () {
    test('drops the query', () {
      expect(describeServerUrl('http://localhost:8/e2e-credentials?token=x'), 'http://localhost:8/e2e-credentials');
    });

    test('names an empty URL', () {
      expect(describeServerUrl(' '), 'none');
    });

    test('names an unparseable URL', () {
      expect(describeServerUrl('http://[::1'), 'unparseable');
    });
  });
}
