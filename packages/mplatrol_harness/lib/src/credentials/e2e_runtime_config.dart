import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mplatrol_harness/src/credentials/e2e_credentials.dart';

/// Asset `mplatrol` writes into the app it builds; declare it under `flutter: assets:` to use it.
///
/// It carries `E2E_ENVIRONMENT` and `E2E_TENANT`, and `E2E_CREDENTIALS_URL` only
/// when a run reuses an already-built app, where it overrides the stale
/// compile-time URL.
const e2eRuntimeConfigAsset = 'assets/mplatrol/e2e_runtime_config.json';

/// Compile-time `--dart-define` key of the credential server URL (it includes `?token=`).
const e2eCredentialsUrlDefine = 'E2E_CREDENTIALS_URL';

/// Compile-time `--dart-define` key of the backend environment.
const e2eEnvironmentDefine = 'E2E_ENVIRONMENT';

/// Compile-time `--dart-define` key of the tenant under test.
const e2eTenantDefine = 'E2E_TENANT';

/// The non-secret runtime wiring `mplatrol` gives a test build.
@immutable
class E2eRuntimeConfig {
  /// Creates a config from its parts; values are trimmed.
  E2eRuntimeConfig({String environment = '', String tenant = '', String credentialsUrl = ''})
      : environment = environment.trim(),
        tenant = tenant.trim(),
        credentialsUrl = credentialsUrl.trim();

  /// The values compiled in with `--dart-define`.
  factory E2eRuntimeConfig.fromDefines() => E2eRuntimeConfig(
        environment: const String.fromEnvironment(e2eEnvironmentDefine),
        tenant: const String.fromEnvironment(e2eTenantDefine),
        credentialsUrl: const String.fromEnvironment(e2eCredentialsUrlDefine),
      );

  /// Parses the [e2eRuntimeConfigAsset] JSON [body].
  ///
  /// Throws:
  ///   FormatException: [body] is not a JSON object.
  factory E2eRuntimeConfig.parse(String body) {
    final json = decodeJsonObject(body);
    String value(String key) => json[key]?.toString() ?? '';
    return E2eRuntimeConfig(
      environment: value(e2eEnvironmentDefine),
      tenant: value(e2eTenantDefine),
      credentialsUrl: value(e2eCredentialsUrlDefine),
    );
  }

  /// The backend environment under test; empty when none was given.
  final String environment;

  /// The tenant under test; empty when none was given.
  final String tenant;

  /// The credential server URL, token included; empty when the build has no server.
  final String credentialsUrl;

  /// This config with every empty value taken from [fallback].
  E2eRuntimeConfig orElse(E2eRuntimeConfig fallback) => E2eRuntimeConfig(
        environment: environment.isEmpty ? fallback.environment : environment,
        tenant: tenant.isEmpty ? fallback.tenant : tenant,
        credentialsUrl: credentialsUrl.isEmpty ? fallback.credentialsUrl : credentialsUrl,
      );

  /// The bundled [e2eRuntimeConfigAsset] over the compile-time defines.
  ///
  /// An app that does not bundle the asset gets the defines alone. An asset that
  /// is present but not a JSON object fails, since it means a broken build.
  ///
  /// Throws:
  ///   FormatException: The bundled asset is not a JSON object.
  static Future<E2eRuntimeConfig> load({AssetBundle? bundle, E2eRuntimeConfig? defines}) async {
    final compiled = defines ?? E2eRuntimeConfig.fromDefines();
    if (bundle == null) {
      WidgetsFlutterBinding.ensureInitialized();
    }
    final String body;
    try {
      body = await (bundle ?? rootBundle).loadString(e2eRuntimeConfigAsset, cache: false);
    } on FlutterError {
      return compiled;
    }
    return E2eRuntimeConfig.parse(body).orElse(compiled);
  }

  /// A description without the server token.
  @override
  String toString() => 'E2eRuntimeConfig(environment: $environment, tenant: $tenant, '
      'credentialsServer: ${describeServerUrl(credentialsUrl)})';
}

/// [url] as `scheme://host:port/path`, without its query (which holds the token).
String describeServerUrl(String url) {
  if (url.trim().isEmpty) {
    return 'none';
  }
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    return 'unparseable';
  }
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port${uri.path}';
}
