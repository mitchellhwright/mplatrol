import 'dart:convert';

import 'package:flutter/foundation.dart';

/// JSON key of the backend environment in a credential server answer.
const e2eEnvironmentKey = 'E2E_ENVIRONMENT';

/// JSON key of the username in a credential server answer.
const e2eUsernameKey = 'E2E_USERNAME';

/// JSON key of the password in a credential server answer.
const e2ePasswordKey = 'E2E_PASSWORD';

/// JSON key of the one-time (MFA) code in a credential server answer.
const e2eOneTimeCodeKey = 'E2E_MFA_CODE';

const _knownKeys = {e2eEnvironmentKey, e2eUsernameKey, e2ePasswordKey, e2eOneTimeCodeKey};

/// A test login handed out by the `mplatrol` runtime credential server.
@immutable
class E2eCredentials {
  /// Creates credentials from their parts.
  const E2eCredentials({
    required this.environment,
    required this.username,
    required this.password,
    this.oneTimeCode = '',
    this.extra = const {},
  });

  /// Parses one credential server answer.
  ///
  /// Values are trimmed; [fallbackEnvironment] is used when the answer has no
  /// environment. Every key other than the four `E2E_*` keys lands in [extra]
  /// with its value as a string; null values are dropped.
  ///
  /// Throws:
  ///   FormatException: The answer has no username or no password.
  factory E2eCredentials.fromJson(Map<String, Object?> json, {String fallbackEnvironment = ''}) {
    String value(String key) => json[key]?.toString().trim() ?? '';
    final username = value(e2eUsernameKey);
    final password = value(e2ePasswordKey);
    final missing = [
      if (username.isEmpty) e2eUsernameKey,
      if (password.isEmpty) e2ePasswordKey,
    ];
    if (missing.isNotEmpty) {
      throw FormatException('Credential server answer has no ${missing.join(' or ')}');
    }
    final environment = value(e2eEnvironmentKey);
    return E2eCredentials(
      environment: environment.isEmpty ? fallbackEnvironment.trim() : environment,
      username: username,
      password: password,
      oneTimeCode: value(e2eOneTimeCodeKey),
      extra: Map.unmodifiable({
        for (final entry in json.entries)
          if (!_knownKeys.contains(entry.key) && entry.value != null) entry.key: entry.value.toString(),
      }),
    );
  }

  /// Parses a credential server response [body].
  ///
  /// Throws:
  ///   FormatException: [body] is not a JSON object, or lacks a username or password.
  factory E2eCredentials.parse(String body, {String fallbackEnvironment = ''}) =>
      E2eCredentials.fromJson(decodeJsonObject(body), fallbackEnvironment: fallbackEnvironment);

  /// The backend environment the login belongs to; empty when unknown.
  final String environment;

  /// The login's username.
  final String username;

  /// The login's password.
  final String password;

  /// The one-time code the backend accepts for this login; empty when none.
  final String oneTimeCode;

  /// Every other value the server sent, keyed as in its answer.
  final Map<String, String> extra;

  /// A description that names the login without its secrets.
  @override
  String toString() => 'E2eCredentials(environment: $environment, username: $username, '
      'oneTimeCode: ${oneTimeCode.isEmpty ? 'none' : 'set'}, extra: ${extra.keys.toList()})';
}

/// Decodes [body] as a JSON object.
///
/// Throws:
///   FormatException: [body] is not JSON, or its top level is not an object.
///     The message never repeats the body, which may hold secrets.
Map<String, Object?> decodeJsonObject(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw FormatException('expected a JSON object, got a body that is not JSON (${error.message})');
  }
  if (decoded is! Map<String, Object?>) {
    throw FormatException('expected a JSON object, got ${decoded.runtimeType}');
  }
  return decoded;
}

/// A credential server request that failed; the message names the route, never the token.
class E2eCredentialsException implements Exception {
  /// Creates an exception for a failed request to [route].
  const E2eCredentialsException(this.route, this.reason, {this.statusCode});

  /// The server route, e.g. `/e2e-credentials`.
  final String route;

  /// What went wrong.
  final String reason;

  /// The HTTP status the server answered with, when it answered with one other than 200.
  final int? statusCode;

  @override
  String toString() => 'E2eCredentialsException($route): $reason';
}
