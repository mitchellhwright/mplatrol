import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A forwarding HTTP proxy on this Mac that lets a test device use the Mac's
/// network.
///
/// Test environments often only accept traffic from approved networks
/// (the app shows "Unauthorized network location" on a phone's own Wi-Fi). An
/// adb reverse mapping exposes this proxy on the phone, and the phone's system
/// proxy points at it, so the device's traffic leaves through the Mac like
/// emulator and LambdaTest traffic does. It handles `CONNECT` tunnels (HTTPS)
/// and absolute-URI requests (plain HTTP); TLS stays end to end between the
/// device and the server.
///
/// By default it binds loopback only (a USB Android phone reaches it through
/// `adb reverse`). An iPhone reaches it over Wi-Fi, so then it binds the Mac's
/// LAN address, accepts only [allowedPeers], and serves [pac] at `/proxy.pac`
/// for the phone's automatic proxy setting.
class DeviceEgressProxy {
  /// Creates a proxy listening on [bindAddress]:[port] (0 picks a free port).
  /// When [allowedPeers] is set, connections from any other address are
  /// refused. [pac] is served at `GET /proxy.pac` when set.
  DeviceEgressProxy({InternetAddress? bindAddress, this.port = 0, this.allowedPeers, this.pac})
      : bindAddress = bindAddress ?? InternetAddress.loopbackIPv4;

  /// Address the proxy listens on.
  final InternetAddress bindAddress;

  /// Requested port; 0 lets the OS pick one.
  final int port;

  /// IP addresses allowed to connect, or null to allow any (loopback only).
  final Set<String>? allowedPeers;

  /// Proxy auto-config script served at `/proxy.pac`, if any.
  final String? pac;

  /// Addresses refused because they were not in [allowedPeers].
  final Set<String> refusedPeers = <String>{};

  ServerSocket? _server;
  final _connections = <Socket>{};

  /// Hosts the device reached through the proxy, for the run summary.
  final Set<String> hosts = <String>{};

  /// Network errors absorbed while proxying (resets, refused writes). A device
  /// dropping connections is routine; none of them may end the run.
  int errors = 0;

  /// Starts listening on an OS-assigned loopback port and returns it.
  Future<int> start() async {
    final server = await ServerSocket.bind(bindAddress, port);
    _server = server;
    // Socket callbacks run in this zone, so an error no handler anticipated is
    // counted instead of escaping as an unhandled exception that ends mplatrol.
    runZonedGuarded(() => server.listen(_serve), (error, stack) => errors++);
    return server.port;
  }

  /// Stops listening and closes every open tunnel.
  Future<void> close() async {
    await _server?.close();
    _connections.toList().forEach(_drop);
  }

  void _serve(Socket client) {
    final peer = normalizePeerAddress(client.remoteAddress.address);
    if (allowedPeers != null && !allowedPeers!.map(normalizePeerAddress).contains(peer)) {
      refusedPeers.add(peer);
      client.destroy();
      return;
    }
    _track(client);
    final head = BytesBuilder();
    late StreamSubscription<List<int>> subscription;
    subscription = client.listen(
      (chunk) {
        head.add(chunk);
        final bytes = head.toBytes();
        final end = _headerEnd(bytes);
        if (end < 0) {
          return;
        }
        subscription.pause();
        unawaited(_forward(client, subscription, bytes, end));
      },
      // Read-side resets can't be forced reliably over loopback in tests.
      onError: (Object _) => _fail(client), // coverage:ignore-line
      onDone: () => _drop(client),
      cancelOnError: true,
    );
  }

  Future<void> _forward(
    Socket client,
    StreamSubscription<List<int>> clientReads,
    List<int> bytes,
    int headerEnd,
  ) async {
    final head = latin1.decode(bytes.sublist(0, headerEnd));
    final pac = this.pac;
    if (pac != null && head.startsWith('GET /proxy.pac ')) {
      _send(
          client,
          latin1.encode('HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n'
              'Content-Length: ${pac.length}\r\nConnection: close\r\n\r\n$pac'));
      return _finish(client);
    }
    final request = _ProxyRequest.parse(head);
    if (request == null) {
      _send(client, latin1.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
      return _drop(client);
    }
    hosts.add(request.host);
    final Socket upstream;
    try {
      upstream = await Socket.connect(request.host, request.port, timeout: const Duration(seconds: 20));
    } on SocketException {
      _send(client, latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
      return _drop(client);
    }
    _track(upstream);
    if (request.isConnect) {
      _send(client, latin1.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      _send(upstream, bytes.sublist(headerEnd));
    } else {
      _send(upstream, bytes);
    }
    clientReads
      ..onData((data) => _send(upstream, data))
      ..onDone(() => _finish(upstream))
      ..onError((Object _) => _fail(upstream))
      ..resume();
    upstream.listen(
      (data) => _send(client, data),
      onDone: () => _finish(client),
      // Read-side resets can't be forced reliably over loopback in tests.
      onError: (Object _) => _fail(client), // coverage:ignore-line
      cancelOnError: true,
    );
  }

  /// Registers [socket] and absorbs the error its `done` future reports when a
  /// write fails (for example the device reset the connection).
  void _track(Socket socket) {
    _connections.add(socket);
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) => _fail(socket)));
  }

  /// Writes [data] unless [socket] was already closed by the other side.
  void _send(Socket socket, List<int> data) {
    if (_connections.contains(socket)) {
      socket.add(data);
    }
  }

  void _fail(Socket socket) {
    errors++;
    _drop(socket);
  }

  /// Ends [socket] after the other side finished sending: queued bytes are
  /// still delivered before it closes.
  void _finish(Socket socket) {
    if (_connections.remove(socket)) {
      unawaited(socket.close().then<void>((_) {}, onError: (Object _) => errors++));
    }
  }

  /// Tears [socket] down immediately (errors and [close]).
  void _drop(Socket socket) {
    _connections.remove(socket);
    socket.destroy();
  }

  /// Index just past the blank line ending the request head, or -1.
  static int _headerEnd(List<int> bytes) {
    for (var i = 3; i < bytes.length; i++) {
      if (bytes[i - 3] == 13 && bytes[i - 2] == 10 && bytes[i - 1] == 13 && bytes[i] == 10) {
        return i + 1;
      }
    }
    return -1;
  }
}

/// [address] comparable across socket families: an IPv4 client of a
/// dual-stack IPv6 socket appears as `::ffff:a.b.c.d`, and link-local IPv6
/// addresses may carry a `%interface` scope.
String normalizePeerAddress(String address) {
  final unscoped = address.split('%').first.toLowerCase();
  return unscoped.startsWith('::ffff:') && unscoped.contains('.') ? unscoped.substring(7) : unscoped;
}

class _ProxyRequest {
  const _ProxyRequest({required this.host, required this.port, required this.isConnect});

  final String host;
  final int port;
  final bool isConnect;

  /// Parses `CONNECT host:port HTTP/1.1` or `GET http://host[:port]/path HTTP/1.1`.
  static _ProxyRequest? parse(String head) {
    final parts = head.split('\r\n').first.split(' ');
    if (parts.length < 3) {
      return null;
    }
    if (parts[0] == 'CONNECT') {
      final separator = parts[1].lastIndexOf(':');
      final port = separator < 0 ? null : int.tryParse(parts[1].substring(separator + 1));
      return port == null ? null : _ProxyRequest(host: parts[1].substring(0, separator), port: port, isConnect: true);
    }
    final uri = Uri.tryParse(parts[1]);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return null;
    }
    return _ProxyRequest(host: uri.host, port: uri.port, isConnect: false);
  }
}
