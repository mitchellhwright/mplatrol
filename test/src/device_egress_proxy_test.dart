import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/device_egress_proxy.dart';
import 'package:test/test.dart';

/// Connects to the proxy on [port], sends [request], and collects everything
/// the proxy returns until it closes or [until] matches.
Future<String> _exchange(int port, List<String> request, {Pattern? until}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final received = StringBuffer();
  final done = Completer<void>();
  socket.listen(
    (data) {
      received.write(latin1.decode(data));
      if (until != null && received.toString().contains(until) && !done.isCompleted) {
        done.complete();
      }
    },
    onDone: () => done.isCompleted ? null : done.complete(),
  );
  for (final part in request) {
    socket.write(part);
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await done.future.timeout(const Duration(seconds: 5));
  socket.destroy();
  return received.toString();
}

void main() {
  late DeviceEgressProxy proxy;
  late int port;

  setUp(() async {
    proxy = DeviceEgressProxy();
    port = await proxy.start();
    addTearDown(proxy.close);
  });

  Future<ServerSocket> echoServer() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.listen(socket.add, onDone: socket.destroy));
    return server;
  }

  test('listens on loopback only', () {
    expect(port, greaterThan(0));
  });

  test('tunnels CONNECT traffic, including bytes sent with the request head', () async {
    final upstream = await echoServer();

    final reply = await _exchange(
      port,
      ['CONNECT 127.0.0.1:${upstream.port} HTTP/1.1\r\nHost: x\r\n\r\nhello', ' world'],
      until: 'hello world',
    );

    expect(reply, startsWith('HTTP/1.1 200 Connection Established\r\n\r\n'));
    expect(reply, endsWith('hello world'));
    expect(proxy.hosts, {'127.0.0.1'});
  });

  test('forwards plain HTTP requests with an absolute URI', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(upstream.close);
    upstream.listen((request) => request.response
      ..write('path=${request.uri.path}')
      ..close());

    final reply = await _exchange(port, [
      'GET http://127.0.0.1:${upstream.port}/login HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
    ]);

    expect(reply, startsWith('HTTP/1.1 200'));
    expect(reply, contains('path=/login'));
  });

  test('waits for a request head split across packets', () async {
    final upstream = await echoServer();

    final reply = await _exchange(
      port,
      ['CONNECT 127.0.0.1:${upstream.port} HT', 'TP/1.1\r\n', '\r\nsplit'],
      until: 'split',
    );

    expect(reply, contains('200 Connection Established'));
    expect(reply, endsWith('split'));
  });

  for (final (name, head) in [
    ('a request line without a target', 'GARBAGE\r\n\r\n'),
    ('CONNECT without a port', 'CONNECT example.com HTTP/1.1\r\n\r\n'),
    ('a relative request URI', 'GET /relative HTTP/1.1\r\n\r\n'),
  ]) {
    test('answers 400 to $name', () async {
      expect(await _exchange(port, [head]), 'HTTP/1.1 400 Bad Request\r\n\r\n');
      expect(proxy.hosts, isEmpty);
    });
  }

  test('drops a client that disconnects before finishing its request', () async {
    final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
    client.write('CONNECT 127.0.0.1');
    await client.flush();
    await client.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(proxy.hosts, isEmpty);
    expect(await _exchange(port, ['GARBAGE\r\n\r\n']), 'HTTP/1.1 400 Bad Request\r\n\r\n');
  });

  test('answers 502 when the destination refuses the connection', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unusedPort = closed.port;
    await closed.close();

    expect(
        await _exchange(port, ['CONNECT 127.0.0.1:$unusedPort HTTP/1.1\r\n\r\n']), 'HTTP/1.1 502 Bad Gateway\r\n\r\n');
  });

  test('keeps serving after a client abandons a tunnel mid-transfer', () async {
    final streaming = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(streaming.close);
    streaming.listen((socket) async {
      socket.done.ignore();
      final chunk = List<int>.filled(64 * 1024, 120);
      for (var i = 0; i < 200; i++) {
        try {
          socket.add(chunk);
          await socket.flush();
        } on SocketException {
          return;
        }
      }
    });
    final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final firstBytes = Completer<void>();
    final reads = client.listen((_) => firstBytes.isCompleted ? null : firstBytes.complete(), onError: (Object _) {});
    client.write('CONNECT 127.0.0.1:${streaming.port} HTTP/1.1\r\n\r\n');
    await firstBytes.future.timeout(const Duration(seconds: 5));
    // Stop reading so unread data piles up: closing then sends a TCP reset, as
    // a phone dropping a connection does, and the proxy's next write fails.
    reads.pause();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    client.destroy();
    await reads.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final upstream = await echoServer();
    final reply =
        await _exchange(port, ['CONNECT 127.0.0.1:${upstream.port} HTTP/1.1\r\n\r\nstill up'], until: 'still up');
    expect(reply, endsWith('still up'));
  });

  test('close ends open tunnels and stops accepting connections', () async {
    final upstream = await echoServer();
    final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(client.destroy);
    final closed = Completer<void>();
    client.listen((_) {}, onDone: closed.complete);
    client.write('CONNECT 127.0.0.1:${upstream.port} HTTP/1.1\r\n\r\n');
    await client.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await proxy.close();

    await closed.future.timeout(const Duration(seconds: 5));
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
  });

  test('normalizePeerAddress compares IPv4-mapped and scoped IPv6 addresses', () {
    expect(normalizePeerAddress('::ffff:192.168.1.238'), '192.168.1.238');
    expect(normalizePeerAddress('FE80::1417:1275%en0'), 'fe80::1417:1275');
    expect(normalizePeerAddress('192.168.1.238'), '192.168.1.238');
    expect(normalizePeerAddress('::ffff:abcd'), '::ffff:abcd');
  });
}
