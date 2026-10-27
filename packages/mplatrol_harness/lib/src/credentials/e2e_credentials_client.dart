import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' as flutter_test;
import 'package:mplatrol_harness/src/credentials/e2e_credentials.dart';
import 'package:mplatrol_harness/src/credentials/e2e_runtime_config.dart';
import 'package:mplatrol_harness/src/credentials/e2e_sign_in_slot_lease.dart';
import 'package:mplatrol_harness/src/credentials/runtime_server_transport.dart';

/// Route the credential server hands out a session's login on.
const e2eCredentialsRoute = '/e2e-credentials';

/// Route the credential server serves the per-user sign-in slot on.
const e2eSignInSlotRoute = '/mplatrol-sign-in-slot';

/// Route the credential server frees a finished session's user on.
const e2eSessionEndRoute = '/mplatrol-session-end';

/// The longest holder id the credential server accepts.
const e2eHolderMaxLength = 128;

/// Default limit for queueing for the sign-in slot before signing in without it.
const defaultSignInSlotMaxWait = Duration(seconds: 90);

/// Shortest pause between two slot requests, whatever `retryAfterMs` the server sent.
const minSignInSlotRetryPause = Duration(milliseconds: 100);

/// Registers a teardown callback of the running test; injectable for tests.
typedef TearDownRegistrar = void Function(dynamic Function() callback);

/// Waits for [pause]; injectable so tests run without real time passing.
typedef RetryPause = Future<void> Function(Duration pause);

/// What the credential server freed when a session ended.
class E2eSessionEndResult {
  /// Creates a result.
  const E2eSessionEndResult({required this.userReleased, required this.slotReleased});

  /// Whether the server freed the user it had assigned to the session.
  final bool userReleased;

  /// Whether the session still held its sign-in slot, which the server then freed.
  final bool slotReleased;
}

final _printableAscii = RegExp(r'^[\x20-\x7E]+$');

/// Client of the `mplatrol` runtime credential server for one device session.
///
/// The server gives each [holder] its own login when the tenant has several,
/// serialises sign-ins of sessions that share a login ([acquireSignInSlot]),
/// and frees the login when the session ends ([endSession]). Secrets are
/// fetched at test runtime, so built apps never contain them.
class E2eCredentialsClient {
  /// Creates a client for the server at [serverUri], which carries the `token` query parameter.
  ///
  /// Args:
  ///   serverUri: The credential URL `mplatrol` passes as `E2E_CREDENTIALS_URL`.
  ///   holder: This session's id; defaults to [processHolder].
  ///   fallbackEnvironment: Environment for answers that name none.
  ///   transport: Performs the HTTP requests.
  ///   fetchAttempts: Requests per credential fetch; later attempts follow a
  ///     connection failure, a timeout or a 5xx answer immediately, without a pause.
  ///   log: Receives the `E2E_*` device-log lines.
  ///   clock: Current time, for the slot wait deadline.
  ///   pause: Waits between slot requests.
  ///   periodic: Starts slot renewal timers.
  ///
  /// Throws:
  ///   ArgumentError: [holder] is not 1-[e2eHolderMaxLength] printable ASCII characters,
  ///     or [fetchAttempts] is below 1.
  E2eCredentialsClient({
    required this.serverUri,
    String? holder,
    this.fallbackEnvironment = '',
    this.transport = const RuntimeServerTransport(),
    this.fetchAttempts = 3,
    void Function(String line) log = print,
    DateTime Function() clock = DateTime.now,
    RetryPause pause = _pause,
    PeriodicTimer periodic = Timer.periodic,
  })  : holder = holder ?? processHolder,
        _log = log,
        _clock = clock,
        _pauseFor = pause,
        _periodic = periodic {
    if (this.holder.length > e2eHolderMaxLength || !_printableAscii.hasMatch(this.holder)) {
      throw ArgumentError.value(this.holder, 'holder', 'must be 1-$e2eHolderMaxLength printable ASCII characters');
    }
    if (fetchAttempts < 1) {
      throw ArgumentError.value(fetchAttempts, 'fetchAttempts', 'must be at least 1');
    }
  }

  /// A client for the server this build was given, or null when it was given none.
  ///
  /// Reads [E2eRuntimeConfig.load]: the bundled runtime config asset over the
  /// `E2E_CREDENTIALS_URL` and `E2E_ENVIRONMENT` defines.
  ///
  /// Throws:
  ///   FormatException: The bundled config asset or the credential URL is malformed.
  static Future<E2eCredentialsClient?> fromEnvironment({
    AssetBundle? bundle,
    RuntimeServerTransport transport = const RuntimeServerTransport(),
    void Function(String line) log = print,
  }) async {
    final config = await E2eRuntimeConfig.load(bundle: bundle);
    if (config.credentialsUrl.isEmpty) {
      return null;
    }
    return E2eCredentialsClient(
      serverUri: Uri.parse(config.credentialsUrl),
      fallbackEnvironment: config.environment,
      transport: transport,
      log: log,
    );
  }

  /// This process's session id: unique per app launch.
  static final String processHolder = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${Random.secure().nextInt(1 << 32).toRadixString(36)}';

  /// The credential URL, token included.
  final Uri serverUri;

  /// This session's id towards the server.
  final String holder;

  /// Environment for answers that name none.
  final String fallbackEnvironment;

  /// Performs the HTTP requests.
  final RuntimeServerTransport transport;

  /// Requests per credential fetch.
  final int fetchAttempts;

  final void Function(String line) _log;
  final DateTime Function() _clock;
  final RetryPause _pauseFor;
  final PeriodicTimer _periodic;
  Future<E2eCredentials>? _credentials;
  var _endPending = false;

  /// The login URL for [holder].
  Uri get credentialsUri => _route(e2eCredentialsRoute);

  /// The sign-in slot URL for [holder]; with [release] the URL that frees the slot.
  Uri signInSlotUri({bool release = false}) => _route(e2eSignInSlotRoute, release: release);

  /// The session-end URL for [holder].
  Uri get sessionEndUri => _route(e2eSessionEndRoute);

  Uri _route(String path, {bool release = false}) => serverUri.replace(
        path: path,
        queryParameters: {...serverUri.queryParameters, 'holder': holder, if (release) 'release': '1'},
      );

  /// This session's login, fetched once until [forgetCredentials] or [endSession].
  ///
  /// Throws:
  ///   E2eCredentialsException: See [fetchCredentials]. A failed fetch is not cached.
  Future<E2eCredentials> credentials() => _credentials ??= fetchCredentials().catchError((Object error) {
        _credentials = null;
        throw error;
      });

  /// Drops the login [credentials] cached, so the next call asks the server again.
  void forgetCredentials() => _credentials = null;

  /// Fetches this session's login from the server, without caching.
  ///
  /// Throws:
  ///   E2eCredentialsException: The server is unreachable after [fetchAttempts]
  ///     requests, refused the request, or sent an answer without a username or password.
  Future<E2eCredentials> fetchCredentials() async {
    Object? lastError;
    for (var attempt = 1; attempt <= fetchAttempts; attempt++) {
      try {
        final json = await transport.getJson(credentialsUri);
        return E2eCredentials.fromJson(json, fallbackEnvironment: fallbackEnvironment);
      } on FormatException catch (error) {
        throw E2eCredentialsException(e2eCredentialsRoute, error.message);
      } on Object catch (error) {
        if (!_isRetryable(error)) {
          throw _asCredentialsError(e2eCredentialsRoute, error);
        }
        lastError = error;
      }
    }
    throw E2eCredentialsException(
      e2eCredentialsRoute,
      'unreachable at ${describeServerUrl(serverUri.toString())} after $fetchAttempts attempts: '
      '${_redact(lastError)}',
    );
  }

  /// Waits for this session's sign-in slot and returns its lease.
  ///
  /// Call it right before submitting the password and release the lease once
  /// sign-in finished or failed. Best effort, never throws: when the server
  /// never answers, or answers without the slot route, or [maxWait] runs out
  /// (`E2E_SIGN_IN_SLOT_TIMEOUT`), the session signs in without the slot.
  ///
  /// Between requests it waits the `retryAfterMs` the server sent (at least
  /// [minSignInSlotRetryPause], never past [maxWait]); after a failed request it
  /// waits the last `retryAfterMs` the server sent. It never pauses otherwise.
  Future<E2eSignInSlotLease> acquireSignInSlot({Duration maxWait = defaultSignInSlotMaxWait}) async {
    final queuedAt = _clock();
    final deadline = queuedAt.add(maxWait);
    Duration? retryAfter;
    while (true) {
      final Map<String, Object?> answer;
      try {
        answer = await transport.getJson(signInSlotUri());
      } on Object catch (error) {
        if (retryAfter == null) {
          _log('E2E_SIGN_IN_SLOT unavailable holder=$holder error=${_redact(error)}; signing in without it');
          return E2eSignInSlotLease.none();
        }
        _log('E2E_SIGN_IN_SLOT retry holder=$holder error=${_redact(error)}');
        if (!await _pauseBeforeRetry(retryAfter, deadline, maxWait)) {
          return E2eSignInSlotLease.none();
        }
        continue;
      }
      if (answer['granted'] == true) {
        _log('E2E_SIGN_IN_SLOT granted holder=$holder waitedMs=${_clock().difference(queuedAt).inMilliseconds}');
        return _lease(answer['holdSeconds']);
      }
      final retryAfterMs = answer['retryAfterMs'];
      if (answer['granted'] != false || retryAfterMs is! int) {
        _log('E2E_SIGN_IN_SLOT unavailable holder=$holder: the server answered without a grant or retryAfterMs; '
            'signing in without it');
        return E2eSignInSlotLease.none();
      }
      retryAfter = Duration(milliseconds: retryAfterMs);
      if (!await _pauseBeforeRetry(retryAfter, deadline, maxWait)) {
        return E2eSignInSlotLease.none();
      }
    }
  }

  /// Waits [retryAfter], cut to what is left before [deadline]; false when nothing is left.
  Future<bool> _pauseBeforeRetry(Duration retryAfter, DateTime deadline, Duration maxWait) async {
    final remaining = deadline.difference(_clock());
    if (remaining <= Duration.zero) {
      _log('E2E_SIGN_IN_SLOT_TIMEOUT holder=$holder waited=${maxWait.inSeconds}s; signing in without the slot');
      return false;
    }
    final atLeast = retryAfter < minSignInSlotRetryPause ? minSignInSlotRetryPause : retryAfter;
    await _pauseFor(atLeast < remaining ? atLeast : remaining);
    return true;
  }

  /// A held lease that renews three times per server hold (at least every second).
  E2eSignInSlotLease _lease(Object? holdSeconds) {
    final hold = Duration(seconds: holdSeconds is int && holdSeconds > 0 ? holdSeconds : 60);
    final third = hold ~/ 3;
    return E2eSignInSlotLease.held(
      holder: holder,
      renew: _renewSignInSlot,
      release: () => transport.getJson(signInSlotUri(release: true)),
      renewEvery: third < const Duration(seconds: 1) ? const Duration(seconds: 1) : third,
      periodic: _periodic,
      log: _log,
    );
  }

  /// Asks for the slot again as its holder, which extends the grant. A refusal
  /// means the grant lapsed and another session took it; that is logged, not thrown.
  Future<void> _renewSignInSlot() async {
    try {
      final answer = await transport.getJson(signInSlotUri());
      if (answer['granted'] != true) {
        _log('E2E_SIGN_IN_SLOT_LOST holder=$holder: the grant lapsed and another session holds the slot');
      }
    } on Object catch (error) {
      _log('E2E_SIGN_IN_SLOT renew_failed holder=$holder error=${_redact(error)}');
    }
  }

  /// Tells the server this session finished and forgets the cached login, so
  /// a later test in this process asks for a login again.
  ///
  /// Best effort, never throws: on failure the server frees the login after
  /// its idle expiry. Returns what the server freed, or null when the request failed.
  Future<E2eSessionEndResult?> endSession() async {
    forgetCredentials();
    try {
      final answer = await transport.getJson(sessionEndUri);
      final result = E2eSessionEndResult(
        userReleased: answer['released'] == true,
        slotReleased: answer['slotReleased'] == true,
      );
      _log('E2E_SESSION_END ended holder=$holder userReleased=${result.userReleased} '
          'slotReleased=${result.slotReleased}');
      return result;
    } on Object catch (error) {
      _log('E2E_SESSION_END unavailable holder=$holder error=${_redact(error)}; '
          'the server frees the user after its idle expiry');
      return null;
    }
  }

  /// Ends this session ([endSession]) when the running test tears down, which
  /// happens after a pass, a failure and a skip alike.
  ///
  /// Call it before the test fetches credentials; later calls before that
  /// teardown register nothing.
  void endSessionAtTearDown({TearDownRegistrar register = flutter_test.addTearDown}) {
    if (_endPending) {
      return;
    }
    _endPending = true;
    register(() async {
      _endPending = false;
      await endSession();
    });
  }

  bool _isRetryable(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      (error is E2eCredentialsException && (error.statusCode ?? 0) >= 500);

  E2eCredentialsException _asCredentialsError(String route, Object error) =>
      error is E2eCredentialsException ? error : E2eCredentialsException(route, _redact(error));

  /// [error] as text with the server token replaced, since client exceptions may quote the URL.
  String _redact(Object? error) {
    final text = '$error';
    final token = serverUri.queryParameters['token'] ?? '';
    return token.isEmpty ? text : text.replaceAll(token, '<token>');
  }
}

Future<void> _pause(Duration pause) => Future<void>.delayed(pause);
