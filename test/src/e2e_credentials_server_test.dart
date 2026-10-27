import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/credentials/credential_provider.dart';
import 'package:mplatrol/src/e2e_credentials_server.dart';
import 'package:mplatrol/src/e2e_sign_in_slot.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/lt_user_session_cap.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _Provider implements CredentialProvider {
  _Provider(this.result);

  List<TestLogin> result;
  final requests = <CredentialRequest>[];

  @override
  Future<List<TestLogin>> logins(CredentialRequest request) async {
    requests.add(request);
    return result;
  }
}

TestLogin _login(String user, {String? otp = '111111'}) =>
    TestLogin(environment: 'staging', username: user, password: 'pw-$user', oneTimeCode: otp);

void main() {
  late Directory repo;
  late _Provider provider;

  setUp(() async {
    await scaffoldMockDependencies();
    repo = Directory.systemTemp.createTempSync('e2e_creds_server');
    provider = _Provider([_login('user')]);
    GetIt.I.unregister<CredentialProvider>();
    GetIt.I.registerSingleton<CredentialProvider>(provider);
    _useRealServerCache(repo.path);
  });

  tearDown(() {
    if (repo.existsSync()) {
      repo.deleteSync(recursive: true);
    }
  });

  Future<E2eCredentialsServerHandle?> start(
          {Map<String, String> env = const {e2eCredentialsPortEnv: '0'}, bool reuseLast = false}) =>
      E2eCredentialsServer()
          .start(repo: repo.path, env: env, tenant: 'acme', environment: 'staging', reuseLast: reuseLast);

  String urlOf(E2eCredentialsServerHandle server, [ItVariant variant = ItVariant.iosLocal]) =>
      server.envFor(variant, const {})['MPLATROL_E2E_CREDENTIALS_URL']!;

  Uri loopback(E2eCredentialsServerHandle server, {String? path}) {
    final compiled = Uri.parse(urlOf(server, ItVariant.ltAndroid)).replace(host: '127.0.0.1');
    return path == null ? compiled : compiled.replace(path: path);
  }

  test('asks the provider for the run tenant, environment and user type', () async {
    final server = await E2eCredentialsServer().start(
        repo: repo.path, env: const {e2eCredentialsPortEnv: '0'}, tenant: 'acme', environment: 'qa', userType: 'biz');
    addTearDown(() async => server?.close());

    final request = provider.requests.single;
    expect([request.repo, request.tenant, request.environment, request.userType], [repo.path, 'acme', 'qa', 'biz']);
  });

  test('returns null when the provider has no login', () async {
    provider.result = [];
    expect(await start(), isNull);
  });

  test('serves credentials only with the transport token', () async {
    final server = (await start())!;
    addTearDown(server.close);
    final url = urlOf(server);

    final ok = await _get(url);
    expect(ok.statusCode, HttpStatus.ok);
    expect(jsonDecode(ok.body),
        {'E2E_ENVIRONMENT': 'staging', 'E2E_USERNAME': 'user', 'E2E_PASSWORD': 'pw-user', 'E2E_MFA_CODE': '111111'});
    expect((await _get(url.replaceFirst(RegExp('token=[^&]+'), ''))).statusCode, HttpStatus.forbidden);
    expect((await _get(url.replaceFirst('/e2e-credentials?', '/other?'))).statusCode, HttpStatus.notFound);
  });

  test('serves the fallback one-time code for a login without its own', () async {
    provider.result = [_login('user', otp: null)];
    final server = (await start(env: const {e2eCredentialsPortEnv: '0', e2eFallbackOneTimeCodeEnv: '000000'}))!;
    addTearDown(server.close);

    expect(jsonDecode((await _get(urlOf(server))).body)['E2E_MFA_CODE'], '000000');
  });

  test('uses each variant callback host', () async {
    final server = (await start())!;
    addTearDown(server.close);

    expect(urlOf(server, ItVariant.androidLocal), contains('http://10.0.2.2:'));
    expect(urlOf(server, ItVariant.iosLocal), contains('http://127.0.0.1:'));
    expect(urlOf(server, ItVariant.ltIos), contains('http://localhost.lambdatest.com:'));
  });

  group('sign-in slot', () {
    late E2eCredentialsServerHandle server;

    setUp(() async {
      server = (await start())!;
      addTearDown(server.close);
    });

    Future<({int statusCode, Object? body})> slot(String query) async {
      final response = await _get('${loopback(server, path: e2eSignInSlotRoute)}&$query');
      return (statusCode: response.statusCode, body: jsonDecode(response.body));
    }

    test('lets one device sign in at a time and hands over on release', () async {
      expect((await slot('holder=device-a')).body, {'granted': true, 'holdSeconds': 60});
      final waiting = (await slot('holder=device-b')).body! as Map;
      expect(waiting['granted'], isFalse);
      expect(waiting['retryAfterMs'], inInclusiveRange(1, 60000));
      expect((await slot('holder=device-b&release=1')).body, {'released': false});
      expect((await slot('holder=device-a&release=1')).body, {'released': true});
      expect((await slot('holder=device-b')).body, {'granted': true, 'holdSeconds': 60});
    });

    for (final query in ['holder=', 'holder=%0Aforged', 'holder=${'x' * 129}', 'release=1']) {
      test('rejects a missing, unprintable or oversized holder ($query)', () async {
        final response = await slot(query);
        expect(response.statusCode, HttpStatus.badRequest);
        expect((response.body! as Map)['error'], contains('holder must be 1-128 printable ASCII characters'));
      });
    }
  });

  group('user pool', () {
    late E2eCredentialsServerHandle server;

    Future<void> startWith(List<TestLogin> logins) async {
      provider.result = logins;
      server = (await start())!;
      addTearDown(server.close);
    }

    Future<String> userFor(String? holder) async {
      final url = holder == null ? '${loopback(server)}' : '${loopback(server)}&holder=$holder';
      return (jsonDecode((await _get(url)).body) as Map)['E2E_USERNAME'] as String;
    }

    test('gives parallel sessions different logins, then shares; duplicate users count once', () async {
      await startWith([_login('user'), _login('alice'), _login('USER'), _login('bob')]);

      expect(await userFor('s1'), 'user');
      expect(await userFor('s2'), 'alice');
      expect(await userFor('s3'), 'bob');
      expect(await userFor('s4'), 'user');
      expect(await userFor('s2'), 'alice');
      expect(await userFor(null), 'user');
      verify(() => getDep<MplatrolLogger>().info('[e2e-creds] 3 logins for parallel device sessions')).called(1);
    });

    test('a session that ended frees its user and sign-in slot at once', () async {
      await startWith([_login('user'), _login('alice')]);
      expect([await userFor('s1'), await userFor('s2')], ['user', 'alice']);
      final slot = loopback(server, path: e2eSignInSlotRoute);
      expect(jsonDecode((await _get('$slot&holder=s2')).body), {'granted': true, 'holdSeconds': 60});

      final ended = await _get('${loopback(server, path: e2eSessionEndRoute)}&holder=s2');
      expect(ended.statusCode, HttpStatus.ok);
      expect(jsonDecode(ended.body), {'released': true, 'slotReleased': true});
      expect(await userFor('s3'), 'alice');
    });

    test('tells the legs the user keys, the run login first', () async {
      await startWith([_login('user'), _login('alice')]);
      final keys = server.envFor(ItVariant.ltIos, const {})[e2eUserKeysEnv]!.split(',');
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(2));
    });
  });

  group('endpoint', () {
    test('keeps its token and port across restarts of one checkout', () async {
      final first = (await start(env: const {}))!;
      final url = urlOf(first);
      await first.close();
      final second = (await start(env: const {}))!;
      addTearDown(second.close);

      expect(urlOf(second), url);
    });

    test('--reuse-last needs a cached endpoint', () async {
      expect(await start(reuseLast: true), isNull);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('--reuse-last needs the previous runtime'))))
          .called(1);
    });

    test('fails instead of falling back when the configured port is busy', () async {
      final occupied = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() async => occupied.close(force: true));

      await expectLater(start(env: {e2eCredentialsPortEnv: '${occupied.port}'}), throwsA(isA<SocketException>()));
    });

    test('checkouts sharing an endpoint file serve the same compiled endpoint', () async {
      final endpoint = p.join(repo.path, 'shared', 'endpoint.json');
      _useRealServerCache(endpoint);
      final env = {e2eCredentialsEndpointFileEnv: endpoint};
      final first = (await start(env: env))!;
      final url = urlOf(first);
      await first.close();
      final second = (await start(env: env))!;
      addTearDown(second.close);

      expect(urlOf(second), url);
      expect(File(p.join(repo.path, e2eCredentialsServerCacheFile)).existsSync(), isFalse);
    });
  });
}

/// Backs the mocked [FileSystem] with the real endpoint cache of [repo], or with the endpoint file [repo] when it
/// names a `.json` file.
void _useRealServerCache(String repo) {
  final cache = repo.endsWith('.json') ? repo : p.join(repo, e2eCredentialsServerCacheFile);
  when(() => getDep<FileSystem>().fileExistsSync(cache)).thenAnswer((_) => File(cache).existsSync());
  when(() => getDep<FileSystem>().readAsStringSync(cache)).thenAnswer((_) => File(cache).readAsStringSync());
  when(() => getDep<FileSystem>().writeAsStringSync(filePath: cache, newContent: any(named: 'newContent')))
      .thenAnswer((invocation) => File(cache).writeAsStringSync(invocation.namedArguments[#newContent] as String));
}

Future<({int statusCode, String body})> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return (statusCode: response.statusCode, body: await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
}
