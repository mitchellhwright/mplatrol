import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol_harness/src/credentials/e2e_credentials.dart';

/// Default time limit for each phase of one credential server request.
const defaultRuntimeServerTimeout = Duration(seconds: 5);

/// GETs JSON objects from the `mplatrol` runtime credential server.
///
/// Each request opens its own [HttpClient] and closes it afterwards, so a
/// dropped tunnel never leaves a pooled connection behind.
class RuntimeServerTransport {
  /// Creates a transport.
  ///
  /// Args:
  ///   timeout: Limit for connecting, for the response headers, and for the body.
  ///   findProxy: Proxy selection as for [HttpClient.findProxy], e.g.
  ///     `PROXY host:port; DIRECT` when the device routes traffic through a proxy.
  const RuntimeServerTransport({this.timeout = defaultRuntimeServerTimeout, this.findProxy});

  /// Limit for each phase of one request.
  final Duration timeout;

  /// Proxy selection for every request; null connects directly.
  final String Function(Uri uri)? findProxy;

  /// One GET of [uri], decoded as a JSON object.
  ///
  /// Throws:
  ///   E2eCredentialsException: The server answered with a status other than 200,
  ///     or with a body that is not a JSON object.
  ///   SocketException, HttpException, TimeoutException: The request did not complete.
  Future<Map<String, Object?>> getJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final proxy = findProxy;
    if (proxy != null) {
      client.findProxy = proxy;
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await utf8.decodeStream(response).timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw E2eCredentialsException(uri.path, 'HTTP ${response.statusCode}', statusCode: response.statusCode);
      }
      try {
        return decodeJsonObject(body);
      } on FormatException catch (error) {
        throw E2eCredentialsException(uri.path, 'HTTP 200 with ${error.message}; is a proxy or tunnel misrouted?');
      }
    } finally {
      client.close(force: true);
    }
  }
}
