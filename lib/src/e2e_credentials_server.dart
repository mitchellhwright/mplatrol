import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/credentials/credential_provider.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/e2e_sign_in_slot.dart';
import 'package:mplatrol/src/e2e_user_pool.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/it_variant.dart';
import 'package:mplatrol/src/lt_user_session_cap.dart';
import 'package:path/path.dart' as p;

const e2eCredentialsPortEnv = 'MPLATROL_E2E_CREDENTIALS_PORT';

/// Env var: the user type the run's logins must have (see [CredentialRequest.userType]); unset for any.
const e2eUserTypeEnv = 'MPLATROL_E2E_USER_TYPE';

/// Env var: the one-time code served for logins that have none of their own (e.g. a test backend that accepts a
/// fixed code). Empty by default.
const e2eFallbackOneTimeCodeEnv = 'MPLATROL_E2E_FALLBACK_OTP';
const e2eCredentialsServerCacheFile = '.mplatrol/e2e_creds_server.json';

/// Path a device session calls with `?holder=<id>` when its test finished
/// (passed, failed or skipped), so its verified user and sign-in slot are free
/// at once instead of after [e2eUserLeaseIdle].
const e2eSessionEndRoute = '/mplatrol-session-end';

/// Env var: the file holding the credential server's endpoint (token and
/// port) instead of the checkout's [e2eCredentialsServerCacheFile]. Builds
/// compile the endpoint in, so checkouts that share this file (and a port)
/// build identical apps and can reuse each other's uploads.
const e2eCredentialsEndpointFileEnv = 'MPLATROL_E2E_CREDENTIALS_ENDPOINT_FILE';

class E2eCredentialsServer {
  /// Creates a credentials server that listens on the port cached for the
  /// checkout, else [e2eCredentialsPortEnv], else an OS-assigned port.
  E2eCredentialsServer();

  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  FileSystem get _fileSystem => getDep<FileSystem>();

  /// Serves the logins [CredentialProvider] supplies for [tenant] on [environment], so no secret is compiled
  /// into the app, plus the run's [E2eSignInSlot] on [e2eSignInSlotRoute], and frees a finished session's user on
  /// [e2eSessionEndRoute]. Returns null when the provider has no login.
  Future<E2eCredentialsServerHandle?> start({
    required String repo,
    required Map<String, String> env,
    required String tenant,
    required String environment,
    String? userType,
    bool reuseLast = false,
  }) async {
    final logins = await getDep<CredentialProvider>().logins(CredentialRequest(
      repo: repo,
      tenant: tenant,
      environment: environment,
      userType: userType,
      env: env,
    ));
    if (logins.isEmpty) {
      return null;
    }
    final fallbackCode = (env[e2eFallbackOneTimeCodeEnv] ?? '').trim();
    final seen = <String>{};
    final users = [
      for (final login in logins)
        if (seen.add(login.username.toLowerCase())) login.toPayload(fallbackOneTimeCode: fallbackCode),
    ];
    if (users.length > 1) {
      _logger.info('[e2e-creds] ${users.length} logins for parallel device sessions');
    }
    // Uploaded artifacts retain this endpoint token; only the payload is refreshed.
    final endpointFile = _endpointFile(repo, env);
    final cached = _readCachedServer(endpointFile);
    if (reuseLast && cached == null) {
      _logger.err(
        '[e2e-creds] --reuse-last needs the previous runtime credential '
        'server token at $endpointFile. Run once without '
        '--reuse-last to rebuild/cache credentials.',
      );
      return null;
    }
    final token = cached?.token ?? _generateToken();
    final HttpServer server;
    try {
      server = await _bindServer(
        cached == null ? env : {...env, e2eCredentialsPortEnv: '${cached.port}'},
      );
    } on SocketException {
      if (cached != null) {
        _logger.err(
          '[e2e-creds] port ${cached.port} cached in $endpointFile is in use, '
          'probably by an `mplatrol` run in another checkout. Builds from this checkout call '
          'that port, so it is not changed silently: stop the other run, or delete '
          '$endpointFile to start a new endpoint (the next build is rebuilt, '
          'not reused).',
        );
      }
      rethrow;
    }
    if (cached == null) {
      _writeCachedServer(endpointFile, token: token, port: server.port);
    }
    final handle = E2eCredentialsServerHandle._(
      server: server,
      token: token,
      users: users,
      shared: _sharedDirectory(env),
      logger: _logger,
    );
    server.listen(handle._handle);
    _logger.info(
      '[e2e-creds] runtime credential server listening on '
      'localhost.lambdatest.com:${server.port}',
    );
    return handle;
  }

  /// [e2eCredentialsEndpointFileEnv] when set, else the checkout's
  /// [e2eCredentialsServerCacheFile].
  String _endpointFile(String repo, Map<String, String> env) {
    final shared = (env[e2eCredentialsEndpointFileEnv] ?? '').trim();
    return shared.isEmpty ? p.join(repo, e2eCredentialsServerCacheFile) : shared;
  }

  _CachedCredentialsServer? _readCachedServer(String path) {
    if (!_fileSystem.fileExistsSync(path)) {
      return null;
    }
    try {
      final decoded = jsonDecode(_fileSystem.readAsStringSync(path));
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final token = (decoded['token'] as String?)?.trim() ?? '';
      final port = decoded['port'] is int ? decoded['port'] as int : int.tryParse('${decoded['port']}') ?? 0;
      if (token.isEmpty || port < 0) {
        return null;
      }
      return _CachedCredentialsServer(token: token, port: port);
    } catch (_) {
      return null;
    }
  }

  void _writeCachedServer(
    String path, {
    required String token,
    required int port,
  }) {
    Directory(p.dirname(path)).createSync(recursive: true);
    _fileSystem.writeAsStringSync(
      filePath: path,
      newContent: '${jsonEncode({'token': token, 'port': port})}\n',
    );
  }

  /// `~/.mplatrol`, where the runs on this machine share user
  /// sessions and sign-in slots; null without a `HOME`.
  String? _sharedDirectory(Map<String, String> env) {
    final home = (env['HOME'] ?? '').trim();
    return home.isEmpty ? null : p.join(home, '.mplatrol');
  }

  /// Binds the configured port exactly, otherwise an OS-assigned one. A new
  /// endpoint never starts on a shared fixed port: the port is cached per
  /// checkout, so a shared default would pin every checkout to one port and
  /// block concurrent runs from separate checkouts.
  Future<HttpServer> _bindServer(Map<String, String> env) {
    final configuredPort = int.tryParse((env[e2eCredentialsPortEnv] ?? '').trim());
    return HttpServer.bind(InternetAddress.anyIPv4, configuredPort ?? 0);
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _CachedCredentialsServer {
  const _CachedCredentialsServer({required this.token, required this.port});

  final String token;
  final int port;
}

class E2eCredentialsServerHandle {
  E2eCredentialsServerHandle._({
    required HttpServer server,
    required String token,
    required List<Map<String, String>> users,
    required String? shared,
    required MplatrolLogger logger,
  })  : _server = server,
        _token = token,
        _users = [for (final user in users) Map.unmodifiable(user)],
        _userKeys = [for (final user in users) _userKey(user)],
        _shared = shared,
        _logger = logger {
    _pool = E2eUserPool(_userKeys, directory: shared == null ? null : p.join(shared, 'e2e-users'));
  }

  static const _routes = {'/e2e-credentials', e2eSignInSlotRoute, e2eSessionEndRoute};

  final HttpServer _server;
  final String _token;

  /// The logins handed to sessions; the first is the run's own.
  final List<Map<String, String>> _users;

  /// Stable, secret-free keys of [_users], shared by every run on the machine.
  final List<String> _userKeys;
  final String? _shared;
  late final E2eUserPool _pool;
  final MplatrolLogger _logger;

  /// One sign-in slot per user, shared by every run on the machine: only
  /// sessions sharing a user take turns.
  final _signInSlots = <int, E2eSignInSlot>{};

  static String _userKey(Map<String, String> user) => (FingerprintBuilder()
        ..addString(user['E2E_ENVIRONMENT']!.trim().toLowerCase())
        ..addString(user['E2E_USERNAME']!.toLowerCase()))
      .finish();

  /// [baseEnv] with this server's credentials URL for [variant], and the keys of its verified users
  /// ([e2eUserKeysEnv]) so LambdaTest legs cap their device sessions per user (see [LtUserSessionCap]).
  Map<String, String> envFor(ItVariant variant, Map<String, String> baseEnv) {
    return {...baseEnv, e2eCredentialsUrlEnv: _urlFor(variant), e2eUserKeysEnv: _userKeys.join(',')};
  }

  Future<void> close() => _server.close(force: true);

  String _urlFor(ItVariant variant) {
    final baseUrl = switch (variant) {
      ItVariant.androidLocal => 'http://10.0.2.2:${_server.port}',
      ItVariant.iosLocal => 'http://127.0.0.1:${_server.port}',
      ItVariant.ltAndroid || ItVariant.ltIos => 'http://localhost.lambdatest.com:${_server.port}',
    };
    return '$baseUrl/e2e-credentials?token=$_token';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method != 'GET' || !_routes.contains(path)) {
        _writeJson(request, HttpStatus.notFound, {'error': 'not found'});
        return;
      }
      if (request.uri.queryParameters['token'] != _token) {
        _writeJson(request, HttpStatus.forbidden, {'error': 'forbidden'});
        return;
      }
      if (path == e2eSignInSlotRoute || path == e2eSessionEndRoute) {
        _handleHolderRoute(request, path);
        return;
      }
      _writeJson(request, HttpStatus.ok, _credentialsFor(request));
    } catch (error) {
      // A client disconnect while the framework writes the response is the only
      // practical way to enter this fallback.
      // coverage:ignore-start
      _logger.warn('[e2e-creds] runtime credential request failed: $error');
      _writeJson(request, HttpStatus.internalServerError, {'error': 'internal server error'});
      // coverage:ignore-end
    }
  }

  /// The run's own login, or with `?holder=<session id>` the login of the
  /// user [E2eUserPool] gives that session.
  Map<String, String> _credentialsFor(HttpRequest request) {
    final holder = request.uri.queryParameters['holder'] ?? '';
    if (holder.isEmpty || _users.length == 1) {
      return _users.first;
    }
    final user = _pool.assign(holder);
    _logger.info('[e2e-creds] session $holder signs in as user ${user + 1}/${_users.length}');
    return _users[user];
  }

  /// Routes that act for one session: `?holder=<id>`, 1-[e2eSignInSlotMaxHolderLength] printable ASCII
  /// characters, else 400.
  void _handleHolderRoute(HttpRequest request, String path) {
    final holder = request.uri.queryParameters['holder'] ?? '';
    if (holder.length > e2eSignInSlotMaxHolderLength || !RegExp(r'^[\x20-\x7E]+$').hasMatch(holder)) {
      _writeJson(request, HttpStatus.badRequest,
          {'error': 'holder must be 1-$e2eSignInSlotMaxHolderLength printable ASCII characters'});
      return;
    }
    _writeJson(request, HttpStatus.ok, path == e2eSessionEndRoute ? _endSession(holder) : _signInSlot(request, holder));
  }

  /// The slot of the user [holder] signs in as: `{"granted": true, "holdSeconds": n}`,
  /// or `{"granted": false, "retryAfterMs": n}` while another holder has it.
  /// `&release=1` frees it: `{"released": bool}`.
  Map<String, Object> _signInSlot(HttpRequest request, String holder) {
    final slot = _slotOf(_pool.userOf(holder));
    if (request.uri.queryParameters['release'] == '1') {
      return {'released': slot.release(holder)};
    }
    final grant = slot.acquire(holder);
    if (grant.granted) {
      _logger.info('[e2e-creds] sign-in slot granted to $holder');
    }
    return grant.granted
        ? {'granted': true, 'holdSeconds': slot.hold.inSeconds}
        : {'granted': false, 'retryAfterMs': grant.wait.inMilliseconds};
  }

  /// Frees the user and, if it still holds it, the sign-in slot of the finished session [holder]:
  /// `{"released": bool, "slotReleased": bool}`. An unknown holder frees nothing.
  Map<String, Object> _endSession(String holder) {
    final user = _pool.userOf(holder);
    final slotReleased = _slotOf(user).release(holder);
    final released = _pool.release(holder);
    if (released || slotReleased) {
      _logger.info('[e2e-creds] session $holder ended; user ${user + 1}/${_users.length} is free');
    }
    return {'released': released, 'slotReleased': slotReleased};
  }

  E2eSignInSlot _slotOf(int user) {
    final shared = _shared;
    return _signInSlots.putIfAbsent(user,
        () => E2eSignInSlot(file: shared == null ? null : p.join(shared, 'sign-in-slots', '${_userKeys[user]}.json')));
  }

  void _writeJson(HttpRequest request, int statusCode, Map<String, Object?> body) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }
}
