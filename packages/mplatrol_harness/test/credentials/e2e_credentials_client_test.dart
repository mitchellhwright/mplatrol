import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mplatrol_harness/mplatrol_harness.dart';

typedef _Answer = ({int status, Object body});

/// A local stand-in for the `mplatrol` credential server that answers from a script.
class _FakeServer {
  _FakeServer._(this._server) {
    _server.listen((request) {
      requests.add(request.uri);
      final answer = respond(request.uri);
      request.response
        ..statusCode = answer.status
        ..headers.contentType = ContentType.json
        ..write(answer.body is String ? answer.body : jsonEncode(answer.body))
        ..close();
    });
  }

  static Future<_FakeServer> start() async => _FakeServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <Uri>[];
  _Answer Function(Uri uri) respond = (_) => (status: 404, body: {'error': 'not found'});

  Uri get credentialsUrl => Uri.parse('http://127.0.0.1:${_server.port}/e2e-credentials?token=tok3n');

  Iterable<Uri> on(String path) => requests.where((uri) => uri.path == path);

  Future<void> close() => _server.close(force: true);
}

/// A timer that never fires on its own; tests call [fire].
class _ManualTimer implements Timer {
  _ManualTimer(this.every, this._tick);

  final Duration every;
  final void Function(Timer timer) _tick;
  var cancelled = false;

  void fire() => _tick(this);

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void main() {
  late _FakeServer server;
  late List<String> log;
  late List<Duration> pauses;
  late DateTime now;
  late List<_ManualTimer> timers;

  E2eCredentialsClient client({int fetchAttempts = 3}) => E2eCredentialsClient(
        serverUri: server.credentialsUrl,
        holder: 'session-1',
        fallbackEnvironment: 'staging',
        fetchAttempts: fetchAttempts,
        log: log.add,
        clock: () => now,
        pause: (pause) async {
          pauses.add(pause);
          now = now.add(pause);
        },
        periodic: (every, tick) {
          final timer = _ManualTimer(every, tick);
          timers.add(timer);
          return timer;
        },
      );

  setUp(() async {
    server = await _FakeServer.start();
    log = [];
    pauses = [];
    now = DateTime(2026);
    timers = [];
  });

  tearDown(() => server.close());

  group('constructor', () {
    test('rejects a holder the server would refuse', () {
      expect(() => E2eCredentialsClient(serverUri: server.credentialsUrl, holder: ''), throwsArgumentError);
      expect(() => E2eCredentialsClient(serverUri: server.credentialsUrl, holder: 'a\nb'), throwsArgumentError);
      expect(() => E2eCredentialsClient(serverUri: server.credentialsUrl, holder: 'x' * 129), throwsArgumentError);
    });

    test('rejects fewer than one fetch attempt', () {
      expect(() => client(fetchAttempts: 0), throwsArgumentError);
    });

    test('defaults the holder to the process holder', () {
      final defaulted = E2eCredentialsClient(serverUri: server.credentialsUrl);
      expect(defaulted.holder, E2eCredentialsClient.processHolder);
      expect(defaulted.holder.length, lessThanOrEqualTo(e2eHolderMaxLength));
    });
  });

  group('route URLs', () {
    test('keep the token and add the holder', () {
      final subject = client();
      expect(subject.credentialsUri.queryParameters, {'token': 'tok3n', 'holder': 'session-1'});
      expect(subject.signInSlotUri().path, '/mplatrol-sign-in-slot');
      expect(subject.signInSlotUri(release: true).queryParameters['release'], '1');
      expect(subject.sessionEndUri.path, '/mplatrol-session-end');
      expect(subject.sessionEndUri.queryParameters['token'], 'tok3n');
    });
  });

  group('fetchCredentials', () {
    test('returns the login the server assigns to the holder', () async {
      server.respond = (_) => (status: 200, body: {'E2E_USERNAME': 'u1', 'E2E_PASSWORD': 'p1', 'E2E_EXTRA': 'x'});
      final credentials = await client().fetchCredentials();
      expect(credentials.username, 'u1');
      expect(credentials.environment, 'staging');
      expect(credentials.extra, {'E2E_EXTRA': 'x'});
      expect(server.requests.single.queryParameters['holder'], 'session-1');
    });

    test('retries a 5xx answer at once and then succeeds', () async {
      var calls = 0;
      server.respond = (_) => ++calls == 1
          ? (status: 503, body: {'error': 'busy'})
          : (status: 200, body: {'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'p'});
      expect((await client().fetchCredentials()).username, 'u');
      expect(calls, 2);
      expect(pauses, isEmpty);
    });

    test('gives up after the attempts with the route but not the token', () async {
      server.respond = (_) => (status: 500, body: {'error': 'internal server error'});
      await expectLater(
        client(fetchAttempts: 2).fetchCredentials(),
        throwsA(isA<E2eCredentialsException>()
            .having((error) => error.toString(), 'text', allOf(contains('2 attempts'), isNot(contains('tok3n'))))),
      );
      expect(server.requests, hasLength(2));
    });

    test('does not retry a refused token', () async {
      server.respond = (_) => (status: 403, body: {'error': 'bad token'});
      await expectLater(
        client().fetchCredentials(),
        throwsA(isA<E2eCredentialsException>().having((error) => error.statusCode, 'statusCode', 403)),
      );
      expect(server.requests, hasLength(1));
    });

    test('fails on a 200 that is not JSON', () async {
      server.respond = (_) => (status: 200, body: '<html>captive portal</html>');
      await expectLater(
        client().fetchCredentials(),
        throwsA(isA<E2eCredentialsException>().having((error) => error.reason, 'reason', contains('not JSON'))),
      );
    });

    test('fails on an answer without a password', () async {
      server.respond = (_) => (status: 200, body: {'E2E_USERNAME': 'u'});
      await expectLater(client().fetchCredentials(), throwsA(isA<E2eCredentialsException>()));
    });

    test('fails when nothing listens, without the token in the message', () async {
      final url = server.credentialsUrl;
      await server.close();
      final subject = E2eCredentialsClient(serverUri: url, holder: 'h', fetchAttempts: 2);
      await expectLater(
        subject.fetchCredentials(),
        throwsA(isA<E2eCredentialsException>().having((error) => error.toString(), 'text', isNot(contains('tok3n')))),
      );
    });
  });

  group('credentials', () {
    test('caches the login until forgotten', () async {
      server.respond = (_) => (status: 200, body: {'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'p'});
      final subject = client();
      await subject.credentials();
      await subject.credentials();
      expect(server.requests, hasLength(1));
      subject.forgetCredentials();
      await subject.credentials();
      expect(server.requests, hasLength(2));
    });

    test('does not cache a failure', () async {
      var calls = 0;
      server.respond = (_) => ++calls == 1
          ? (status: 403, body: {'error': 'bad token'})
          : (status: 200, body: {'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'p'});
      final subject = client();
      await expectLater(subject.credentials(), throwsA(isA<E2eCredentialsException>()));
      expect((await subject.credentials()).username, 'u');
    });
  });

  group('acquireSignInSlot', () {
    test('returns a held lease that renews at a third of the hold', () async {
      server.respond = (_) => (status: 200, body: {'granted': true, 'holdSeconds': 60});
      final lease = await client().acquireSignInSlot();
      expect(lease.isHeld, isTrue);
      expect(lease.renewEvery, const Duration(seconds: 20));
      expect(timers.single.every, const Duration(seconds: 20));
      expect(log.single, startsWith('E2E_SIGN_IN_SLOT granted holder=session-1'));
    });

    test('waits the retryAfterMs the server sends', () async {
      var calls = 0;
      server.respond = (_) => ++calls < 3
          ? (status: 200, body: {'granted': false, 'retryAfterMs': 1500})
          : (status: 200, body: {'granted': true, 'holdSeconds': 60});
      final lease = await client().acquireSignInSlot();
      expect(lease.isHeld, isTrue);
      expect(pauses, [const Duration(milliseconds: 1500), const Duration(milliseconds: 1500)]);
    });

    test('pauses at least the minimum when the server says zero', () async {
      var calls = 0;
      server.respond = (_) => ++calls == 1
          ? (status: 200, body: {'granted': false, 'retryAfterMs': 0})
          : (status: 200, body: {'granted': true, 'holdSeconds': 60});
      await client().acquireSignInSlot();
      expect(pauses, [minSignInSlotRetryPause]);
    });

    test('stops at maxWait and signs in without the slot', () async {
      server.respond = (_) => (status: 200, body: {'granted': false, 'retryAfterMs': 4000});
      final lease = await client().acquireSignInSlot(maxWait: const Duration(seconds: 10));
      expect(lease.isHeld, isFalse);
      expect(pauses, [
        const Duration(seconds: 4),
        const Duration(seconds: 4),
        const Duration(seconds: 2),
      ]);
      expect(log.last, startsWith('E2E_SIGN_IN_SLOT_TIMEOUT holder=session-1 waited=10s'));
    });

    test('signs in without the slot when the server has no slot route', () async {
      final lease = await client().acquireSignInSlot();
      expect(lease.isHeld, isFalse);
      expect(pauses, isEmpty);
      expect(log.single, contains('unavailable'));
      expect(log.single, isNot(contains('tok3n')));
    });

    test('signs in without the slot when the answer has no retryAfterMs', () async {
      server.respond = (_) => (status: 200, body: {'granted': false});
      final lease = await client().acquireSignInSlot();
      expect(lease.isHeld, isFalse);
      expect(pauses, isEmpty);
    });

    test('after a failed request waits the last retryAfterMs and asks again', () async {
      var calls = 0;
      server.respond = (_) => switch (++calls) {
            1 => (status: 200, body: {'granted': false, 'retryAfterMs': 700}),
            2 => (status: 502, body: {'error': 'tunnel'}),
            _ => (status: 200, body: {'granted': true, 'holdSeconds': 60}),
          };
      final lease = await client().acquireSignInSlot();
      expect(lease.isHeld, isTrue);
      expect(pauses, [const Duration(milliseconds: 700), const Duration(milliseconds: 700)]);
      expect(log, contains(startsWith('E2E_SIGN_IN_SLOT retry holder=session-1')));
    });
  });

  group('E2eSignInSlotLease', () {
    test('renewal logs a lost grant and release frees the slot once', () async {
      var renewals = 0;
      server.respond = (uri) {
        if (uri.queryParameters['release'] == '1') {
          return (status: 200, body: {'released': true});
        }
        return ++renewals == 1
            ? (status: 200, body: {'granted': true, 'holdSeconds': 30})
            : (status: 200, body: {'granted': false, 'retryAfterMs': 100});
      };
      final lease = await client().acquireSignInSlot();
      timers.single.fire();
      await lease.release();
      await lease.release();
      expect(log, contains(startsWith('E2E_SIGN_IN_SLOT_LOST holder=session-1')));
      expect(server.requests.where((uri) => uri.queryParameters['release'] == '1'), hasLength(1));
      expect(timers.single.cancelled, isTrue);
      expect(lease.isHeld, isFalse);
    });

    test('release never throws when the server is gone', () async {
      server.respond = (_) => (status: 200, body: {'granted': true, 'holdSeconds': 60});
      final lease = await client().acquireSignInSlot();
      await server.close();
      await lease.release();
      expect(log.last, startsWith('E2E_SIGN_IN_SLOT release_failed holder=session-1'));
    });

    test('a none lease releases nothing', () async {
      final lease = E2eSignInSlotLease.none();
      expect(lease.isHeld, isFalse);
      await lease.release();
    });
  });

  group('endSession', () {
    test('reports what the server freed and forgets the login', () async {
      server.respond = (uri) => uri.path == e2eSessionEndRoute
          ? (status: 200, body: {'released': true, 'slotReleased': false})
          : (status: 200, body: {'E2E_USERNAME': 'u', 'E2E_PASSWORD': 'p'});
      final subject = client();
      await subject.credentials();
      final result = await subject.endSession();
      expect(result?.userReleased, isTrue);
      expect(result?.slotReleased, isFalse);
      await subject.credentials();
      expect(server.on(e2eCredentialsRoute), hasLength(2));
      expect(server.on(e2eSessionEndRoute).single.queryParameters['holder'], 'session-1');
    });

    test('returns null and never throws when the route fails', () async {
      expect(await client().endSession(), isNull);
      expect(log.single, startsWith('E2E_SESSION_END unavailable holder=session-1'));
    });

    test('endSessionAtTearDown registers once until the teardown ran', () async {
      server.respond = (_) => (status: 200, body: {'released': true, 'slotReleased': true});
      final callbacks = <dynamic Function()>[];
      final subject = client();
      subject.endSessionAtTearDown(register: callbacks.add);
      subject.endSessionAtTearDown(register: callbacks.add);
      expect(callbacks, hasLength(1));
      await callbacks.single();
      expect(server.on(e2eSessionEndRoute), hasLength(1));
      subject.endSessionAtTearDown(register: callbacks.add);
      expect(callbacks, hasLength(2));
    });
  });

  group('fromEnvironment', () {
    test('is null in a build without a credential URL', () async {
      expect(await E2eCredentialsClient.fromEnvironment(), isNull);
    });
  });
}
