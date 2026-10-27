import 'dart:io';

import 'package:meta/meta.dart';
import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The file every `mplatrol` command reads its project settings from, at the app's root.
const mplatrolConfigFileName = 'mplatrol.yaml';

/// Env var naming a config file to use instead of `<app>/mplatrol.yaml`.
const mplatrolConfigEnv = 'MPLATROL_CONFIG';

/// The project settings from `mplatrol.yaml`. Every key is optional.
///
/// ```yaml
/// app:
///   path: .
/// prepare:
///   command: ./tool/configure_tenant.sh "$MPLATROL_TENANT"
///   patch-patrol: true
/// tenant: default
/// environment: staging
/// target: patrol_test/app_test.dart
/// lambdatest:
///   tunnel-name: my-tunnel
///   android-devices: ['Pixel 8-14|Galaxy S24-14']
///   ios-devices: ['iPhone 15-17']
///   android-max-parallel: 5
///   ios-max-parallel: 5
///   idle-timeout: 360
///   required-env: [PRIVATE_REGISTRY_TOKEN]
/// credentials:
///   provider: env          # env | file
///   prefix: MPLATROL_CRED_
///   file: .mplatrol/credentials.json
/// coverage:
///   packages: ^(my_app|my_shared_.+)$
/// network:
///   proxied-domains: ['.example.com']
///   probe-url: https://www.example.com/
/// lessons:
///   - name: paymentsSandboxDown
///     category: env-failure
///     pattern: 'payments sandbox returned 503'
///     symptom: The payments sandbox answers HTTP 503
///     remedy: The sandbox is down; rerun when its status page is green.
/// reporting:
///   sinks:
///     - type: junit
///       path: build/mplatrol/junit.xml
///     - type: json
///       path: build/mplatrol/results.json
/// ```
class MplatrolConfig {
  /// Settings parsed from [yaml] (a decoded `mplatrol.yaml`, or null for all defaults).
  @visibleForTesting
  MplatrolConfig.fromYaml(dynamic yaml, {this.sourcePath})
      : appPath = _string(yaml, ['app', 'path']),
        prepareCommand = _string(yaml, ['prepare', 'command']),
        patchPatrol = _string(yaml, ['prepare', 'patch-patrol']) != 'false',
        coveragePackages = _string(yaml, ['coverage', 'packages']),
        it = ItOptions(yaml),
        credentials = CredentialsOptions(_section(yaml, 'credentials')),
        reporting = ReportingOptions(_section(yaml, 'reporting')),
        network = NetworkOptions(_section(yaml, 'network')),
        lessonsYaml = _section(yaml, 'lessons');

  /// Reads `mplatrol.yaml` from [mplatrolConfigEnv], else the nearest folder at or above the current
  /// directory that holds one. No file means all defaults.
  ///
  /// Throws:
  ///   FormatException: the file exists but is not valid YAML.
  factory MplatrolConfig.load() {
    final path = configFilePath(Platform.environment, Directory.current.path);
    if (path == null) {
      return MplatrolConfig.fromYaml(null);
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('$mplatrolConfigEnv names a config file that does not exist', path);
    }
    try {
      return MplatrolConfig.fromYaml(loadYaml(file.readAsStringSync()), sourcePath: path);
    } on YamlException catch (error) {
      throw FormatException('$path is not valid YAML: ${error.message}');
    }
  }

  /// The config file [env] names, else the nearest `mplatrol.yaml` at or above [start], else null.
  static String? configFilePath(Map<String, String> env, String start) {
    final explicit = (env[mplatrolConfigEnv] ?? '').trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }
    for (var dir = p.normalize(p.absolute(start));; dir = p.dirname(dir)) {
      final candidate = p.join(dir, mplatrolConfigFileName);
      if (File(candidate).existsSync()) {
        return candidate;
      }
      if (dir == p.dirname(dir)) {
        return null;
      }
    }
  }

  /// The file these settings came from, or null when no file was found.
  final String? sourcePath;

  /// `app.path`: the Flutter app's root, relative to the config file. Null: find it from the current directory.
  final String? appPath;

  /// `prepare.command`: a shell command run in the app before each tenant's builds (see `PrepareHook`), or null.
  final String? prepareCommand;

  /// `prepare.patch-patrol` (default true): resolve `patrol` to mplatrol's patched copy before builds.
  final bool patchPatrol;

  /// `coverage.packages`: the package-name regex `run --coverage` keeps; null keeps the app's own package.
  final String? coveragePackages;

  /// Integration-test run defaults.
  final ItOptions it;

  /// Where test credentials come from.
  final CredentialsOptions credentials;

  /// Where results are written besides the console.
  final ReportingOptions reporting;

  /// How local phones reach the test environment through this machine.
  final NetworkOptions network;

  /// The raw `lessons:` block; see [lessons].
  final Object? lessonsYaml;

  /// The project lessons of the `lessons:` block, each `{name, category, pattern, symptom, remedy}`, with
  /// `category` a result category name such as `test-data-failure` or `env-failure`.
  ///
  /// Throws:
  ///   FormatException: the block is not a list of such maps, or a category name is unknown.
  ///   ArgumentError: a lesson is invalid (see [TestLesson.custom]).
  List<TestLesson> get lessons {
    final block = lessonsYaml;
    if (block == null) {
      return const [];
    }
    if (block is! List) {
      throw const FormatException('lessons: in $mplatrolConfigFileName must be a list.');
    }
    return [
      for (final entry in block)
        if (entry is Map) _lesson(entry) else throw const FormatException('every lessons: entry must be a map'),
    ];
  }

  static TestLesson _lesson(Map<dynamic, dynamic> entry) {
    String field(String key) {
      final value = entry[key]?.toString().trim() ?? '';
      if (value.isEmpty) {
        throw FormatException('lessons: entry ${entry['name'] ?? '(no name)'} needs a non-empty "$key".');
      }
      return value;
    }

    final categoryName = field('category');
    final category = ItResultCategory.named(categoryName);
    if (category == null) {
      throw FormatException('lessons: entry ${field('name')} has an unknown category "$categoryName"; use one of '
          '${ItResultCategory.values.map((category) => category.docName).join(', ')}.');
    }
    return TestLesson.custom(
      name: field('name'),
      category: category,
      symptom: field('symptom'),
      remedy: field('remedy'),
      pattern: field('pattern'),
    );
  }

  /// The app root [appPath] names, resolved against the config file's folder, or null when unset.
  String? resolvedAppPath() {
    final path = appPath;
    if (path == null) {
      return null;
    }
    final base = sourcePath == null ? getDep<FileSystem>().currentDir.path : p.dirname(sourcePath!);
    return p.normalize(p.join(base, path));
  }
}

Object? _section(dynamic yaml, String key) => yaml is Map ? yaml[key] : null;

String? _string(dynamic yaml, List<String> keys) {
  Object? node = yaml;
  for (final key in keys) {
    node = node is Map ? node[key] : null;
  }
  return node?.toString();
}

/// LambdaTest Android device specs (`Name-OSVersion`) one job may take when no `lambdatest.android-devices`
/// are configured: recent Pixel and Galaxy S phones, so a job takes whichever is free instead of queueing.
const defaultLtAndroidDevicePool = [
  'Galaxy S23-13',
  'Galaxy S23-14',
  'Galaxy S24-14',
  'Galaxy S25-15',
  'Galaxy S24 Ultra-14',
  'Pixel 9-15',
  'Pixel 9-16',
  'Pixel 8-14',
  'Pixel 7-13',
];

/// LambdaTest iOS device specs one job may take when no `lambdatest.ios-devices` are configured: iPhones on
/// iOS 17 and later.
const defaultLtIosDevicePool = [
  'iPhone 16 Pro-18',
  'iPhone 16-18',
  'iPhone 15 Pro-18',
  'iPhone 15 Pro-17',
  'iPhone 15-17',
  'iPhone 14-18',
  'iPhone SE (2020)-17',
];

/// Default `lambdatest.ios-max-parallel` and `lambdatest.android-max-parallel`.
const defaultLtMaxParallel = 10;

/// Defaults for `mplatrol run` and `mplatrol matrix`.
class ItOptions {
  /// Options from the top level and the `lambdatest:` block of a decoded `mplatrol.yaml`.
  @visibleForTesting
  ItOptions(dynamic yaml)
      : tenant = _string(yaml, ['tenant']) ?? 'default',
        tenantConfigured = _string(yaml, ['tenant']) != null,
        target = _string(yaml, ['target']) ?? 'patrol_test/app_test.dart',
        environment = _string(yaml, ['environment']) ?? 'staging',
        environmentConfigured = _string(yaml, ['environment']) != null,
        tunnelName = _string(yaml, ['lambdatest', 'tunnel-name']),
        ltAndroidDevices = _list(yaml, 'android-devices') ?? [defaultLtAndroidDevicePool.join('|')],
        ltIosDevices = _list(yaml, 'ios-devices') ?? [defaultLtIosDevicePool.join('|')],
        idleTimeout = int.tryParse(_string(yaml, ['lambdatest', 'idle-timeout']) ?? '') ?? 360,
        ltIosMaxParallel =
            int.tryParse(_string(yaml, ['lambdatest', 'ios-max-parallel']) ?? '') ?? defaultLtMaxParallel,
        ltAndroidMaxParallel =
            int.tryParse(_string(yaml, ['lambdatest', 'android-max-parallel']) ?? '') ?? defaultLtMaxParallel,
        ltRequiredEnv = _list(yaml, 'required-env') ?? const [];

  /// The tenant (white-label flavor) the app is built and tested for; passed to the app as `E2E_TENANT`.
  final String tenant;

  /// Whether `tenant` was set in the config (otherwise `run` may ask for one).
  final bool tenantConfigured;

  /// The Patrol test file passed to patrol.
  final String target;

  /// The backend environment the tests run against; passed to the app as `E2E_ENVIRONMENT`.
  final String environment;

  /// Whether `environment` was set in the config.
  final bool environmentConfigured;

  /// The LambdaTest tunnel name to use verbatim. Null lets LambdaTest generate one.
  final String? tunnelName;

  /// LambdaTest Android device specs (`Name-OSVersion`), one HyperExecute job each; a spec may be a
  /// `|`-separated pool.
  final List<String> ltAndroidDevices;

  /// LambdaTest iOS device specs, as [ltAndroidDevices].
  final List<String> ltIosDevices;

  /// Per-test idle timeout in seconds for LambdaTest runs.
  final int idleTimeout;

  /// Most LambdaTest iOS devices one job holds at once (`MPLATROL_LT_IOS_MAX_PARALLEL` overrides it).
  final int ltIosMaxParallel;

  /// Most LambdaTest Android devices one job holds at once (`MPLATROL_LT_ANDROID_MAX_PARALLEL` overrides it).
  final int ltAndroidMaxParallel;

  /// Env vars a LambdaTest build needs besides the LambdaTest ones (e.g. private package registry tokens); a
  /// LambdaTest run refuses to start while one is unset.
  final List<String> ltRequiredEnv;

  static List<String>? _list(dynamic yaml, String key) {
    final lambdaTest = yaml is Map ? yaml['lambdatest'] : null;
    final value = lambdaTest is Map ? lambdaTest[key] : null;
    return value is YamlList || value is List ? [for (final item in value as List) item.toString()] : null;
  }
}

/// The `credentials:` block: which [CredentialProvider] supplies test logins.
class CredentialsOptions {
  /// Options from a decoded `credentials:` block (null for defaults).
  CredentialsOptions(dynamic yaml)
      : provider = _string(yaml, ['provider']) ?? 'env',
        prefix = _string(yaml, ['prefix']) ?? 'MPLATROL_CRED_',
        file = _string(yaml, ['file']);

  /// `env` (environment variables) or `file` (a JSON file).
  final String provider;

  /// Env var prefix the `env` provider reads (`<prefix>USERNAME`, `<prefix>PASSWORD`, ...).
  final String prefix;

  /// The JSON file the `file` provider reads.
  final String? file;
}

/// The `reporting:` block: result sinks besides the console summary.
class ReportingOptions {
  /// Options from a decoded `reporting:` block (null for defaults).
  ReportingOptions(dynamic yaml) : sinks = _sinks(yaml);

  /// Each sink's settings, e.g. `{type: junit, path: build/mplatrol/junit.xml}`.
  final List<Map<String, String>> sinks;

  static List<Map<String, String>> _sinks(dynamic yaml) {
    final sinks = yaml is Map ? yaml['sinks'] : null;
    if (sinks is! List) {
      return const [];
    }
    return [
      for (final sink in sinks)
        if (sink is Map) {for (final entry in sink.entries) entry.key.toString(): entry.value.toString()},
    ];
  }
}

/// The `network:` block: what a physical iPhone sends through this machine's egress proxy.
class NetworkOptions {
  /// Options from a decoded `network:` block (null for defaults).
  NetworkOptions(dynamic yaml)
      : proxiedDomains = [
          if (yaml is Map && yaml['proxied-domains'] is List)
            for (final domain in yaml['proxied-domains'] as List) domain.toString(),
        ],
        probeUrl = _string(yaml, ['probe-url']) ?? 'https://example.com/';

  /// Domain suffixes (`.example.com`) routed through this machine; empty routes every host.
  final List<String> proxiedDomains;

  /// The page a route check opens on the phone.
  final String probeUrl;
}
