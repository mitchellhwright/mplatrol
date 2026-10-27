import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:path/path.dart' as p;

/// One login a device session may sign in as.
///
/// The runtime credential server hands it to the app under test as JSON with the keys `E2E_ENVIRONMENT`,
/// `E2E_USERNAME`, `E2E_PASSWORD` and `E2E_MFA_CODE`, plus every [extra] entry, so no secret is compiled into
/// the app.
class TestLogin {
  /// A login for [username] on [environment].
  const TestLogin({
    required this.environment,
    required this.username,
    required this.password,
    this.oneTimeCode,
    this.extra = const {},
  });

  /// The backend environment the login belongs to, e.g. `staging`.
  final String environment;

  /// The user name.
  final String username;

  /// The password.
  final String password;

  /// A fixed one-time code for test users that have one, or null.
  final String? oneTimeCode;

  /// Further values the tests read, e.g. an account number.
  final Map<String, String> extra;

  /// The payload the credential server serves for this login.
  Map<String, String> toPayload({String fallbackOneTimeCode = ''}) => {
        ...extra,
        'E2E_ENVIRONMENT': environment,
        'E2E_USERNAME': username,
        'E2E_PASSWORD': password,
        'E2E_MFA_CODE': (oneTimeCode ?? '').trim().isEmpty ? fallbackOneTimeCode : oneTimeCode!.trim(),
      };
}

/// What a run asks a [CredentialProvider] for.
class CredentialRequest {
  /// A request for logins of [tenant] on [environment].
  const CredentialRequest({
    required this.repo,
    required this.tenant,
    required this.environment,
    required this.env,
    this.userType,
  });

  /// The app checkout the run tests.
  final String repo;

  /// The tenant (white-label flavor) under test.
  final String tenant;

  /// The backend environment under test.
  final String environment;

  /// A user type the tests need (e.g. `business`), or null for any.
  final String? userType;

  /// The run's environment variables.
  final Map<String, String> env;
}

/// Supplies the logins a run's device sessions sign in as.
///
/// Implement this to read logins from your secret store, and register it before the command runs:
///
/// ```dart
/// GetIt.I.registerSingleton<CredentialProvider>(MyVaultCredentialProvider());
/// await MplatrolCommandRunner().run(args);
/// ```
///
/// The first login is the run's primary; parallel device sessions are spread over all of them.
abstract interface class CredentialProvider {
  /// The provider `credentials:` in `mplatrol.yaml` selects: `env` ([EnvCredentialProvider], the default) or
  /// `file` ([FileCredentialProvider]).
  ///
  /// Throws:
  ///   ArgumentError: `provider` names neither.
  factory CredentialProvider.fromConfig(CredentialsOptions options) => switch (options.provider) {
        'env' => EnvCredentialProvider(prefix: options.prefix),
        'file' => FileCredentialProvider(path: options.file),
        _ => throw ArgumentError.value(
            options.provider, 'credentials.provider', 'expected "env" or "file" (or register your own provider)'),
      };

  /// The logins for [request], primary first; empty when there are none.
  Future<List<TestLogin>> logins(CredentialRequest request);
}

/// Reads logins from environment variables: `<prefix>USERNAME`, `<prefix>PASSWORD` and the optional
/// `<prefix>OTP`, then `<prefix>2_USERNAME`, `<prefix>2_PASSWORD`, ... for more users.
class EnvCredentialProvider implements CredentialProvider {
  /// A provider reading variables that start with [prefix].
  const EnvCredentialProvider({this.prefix = 'MPLATROL_CRED_'});

  /// The variable name prefix.
  final String prefix;

  @override
  Future<List<TestLogin>> logins(CredentialRequest request) async {
    final logins = <TestLogin>[];
    for (var index = 1;; index++) {
      final key = index == 1 ? prefix : '$prefix${index}_';
      final username = (request.env['${key}USERNAME'] ?? '').trim();
      final password = request.env['${key}PASSWORD'] ?? '';
      if (username.isEmpty || password.isEmpty) {
        return logins;
      }
      logins.add(TestLogin(
        environment: request.environment,
        username: username,
        password: password,
        oneTimeCode: request.env['${key}OTP'],
      ));
    }
  }
}

/// Reads logins from a JSON file (keep it out of version control):
///
/// ```json
/// {
///   "logins": [
///     {"tenant": "default", "environment": "staging", "username": "u1", "password": "p1", "otp": "123456",
///      "userType": "retail", "extra": {"ACCOUNT": "1234"}}
///   ]
/// }
/// ```
///
/// `tenant`, `environment` and `userType` are optional filters: a login without them matches every request.
class FileCredentialProvider implements CredentialProvider {
  /// A provider reading [path] (relative paths resolve against the app checkout); default
  /// `.mplatrol/credentials.json`.
  const FileCredentialProvider({String? path}) : path = path ?? '.mplatrol/credentials.json';

  /// The credentials file.
  final String path;

  /// Throws:
  ///   FormatException: the file is not a JSON object with a `logins` list of objects.
  @override
  Future<List<TestLogin>> logins(CredentialRequest request) async {
    final file = File(p.isAbsolute(path) ? path : p.join(request.repo, path));
    if (!file.existsSync()) {
      return const [];
    }
    final decoded = jsonDecode(await file.readAsString());
    final entries = decoded is Map ? decoded['logins'] : null;
    if (entries is! List) {
      throw FormatException('${file.path} must be a JSON object with a "logins" list.');
    }
    return [
      for (final entry in entries)
        if (_matches(_object(entry, file.path), request)) _login(_object(entry, file.path), request, file.path),
    ];
  }

  static Map<String, Object?> _object(Object? entry, String source) {
    if (entry is! Map) {
      throw FormatException('$source: every "logins" entry must be an object.');
    }
    return {for (final item in entry.entries) item.key.toString(): item.value};
  }

  static bool _matches(Map<String, Object?> entry, CredentialRequest request) {
    bool same(String key, String? wanted) {
      final value = entry[key]?.toString().trim() ?? '';
      return value.isEmpty || wanted == null || value.toLowerCase() == wanted.toLowerCase();
    }

    return same('tenant', request.tenant) &&
        same('environment', request.environment) &&
        same('userType', request.userType);
  }

  static TestLogin _login(Map<String, Object?> entry, CredentialRequest request, String source) {
    final username = entry['username']?.toString().trim() ?? '';
    final password = entry['password']?.toString() ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw FormatException('$source: every login needs a non-empty "username" and "password".');
    }
    final extra = entry['extra'];
    return TestLogin(
      environment: entry['environment']?.toString() ?? request.environment,
      username: username,
      password: password,
      oneTimeCode: entry['otp']?.toString(),
      extra: extra is Map ? {for (final item in extra.entries) item.key.toString(): item.value.toString()} : const {},
    );
  }
}
