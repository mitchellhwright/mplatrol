import 'dart:io';

import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('every key is optional', () {
    final config = MplatrolConfig.fromYaml(null);

    expect(config.appPath, isNull);
    expect(config.prepareCommand, isNull);
    expect(config.patchPatrol, isTrue);
    expect(config.coveragePackages, isNull);
    expect(config.it.tenant, 'default');
    expect(config.it.tenantConfigured, isFalse);
    expect(config.it.environment, 'staging');
    expect(config.it.target, 'patrol_test/app_test.dart');
    expect(config.it.ltAndroidDevices, [defaultLtAndroidDevicePool.join('|')]);
    expect(config.it.ltIosDevices, [defaultLtIosDevicePool.join('|')]);
    expect(config.it.ltRequiredEnv, isEmpty);
    expect(config.it.idleTimeout, 360);
    expect(config.credentials.provider, 'env');
    expect(config.credentials.prefix, 'MPLATROL_CRED_');
    expect(config.reporting.sinks, isEmpty);
    expect(config.network.proxiedDomains, isEmpty);
    expect(config.network.probeUrl, 'https://example.com/');
  });

  test('reads every block of mplatrol.yaml', () {
    final config = MplatrolConfig.fromYaml(loadYaml('''
app:
  path: app
prepare:
  command: ./tool/configure_tenant.sh
  patch-patrol: false
coverage:
  packages: ^(shop|shop_.+)\$
tenant: acme
environment: qa
target: patrol_test/smoke_test.dart
lambdatest:
  tunnel-name: shared
  android-devices: ['Pixel 8-14']
  ios-devices: ['iPhone 15-17', 'iPhone 16-18']
  android-max-parallel: 3
  ios-max-parallel: 2
  idle-timeout: 120
  required-env: [REGISTRY_TOKEN]
credentials:
  provider: file
  file: secrets/logins.json
network:
  proxied-domains: ['.example.test']
  probe-url: https://www.example.test/
reporting:
  sinks:
    - type: junit
      path: out/junit.xml
'''), sourcePath: '/work/mplatrol.yaml');

    expect(config.resolvedAppPath(), '/work/app');
    expect(config.prepareCommand, './tool/configure_tenant.sh');
    expect(config.patchPatrol, isFalse);
    expect(config.coveragePackages, r'^(shop|shop_.+)$');
    expect([config.it.tenant, config.it.tenantConfigured, config.it.environment, config.it.target],
        ['acme', true, 'qa', 'patrol_test/smoke_test.dart']);
    expect(config.it.tunnelName, 'shared');
    expect(config.it.ltAndroidDevices, ['Pixel 8-14']);
    expect(config.it.ltIosDevices, ['iPhone 15-17', 'iPhone 16-18']);
    expect([config.it.ltAndroidMaxParallel, config.it.ltIosMaxParallel, config.it.idleTimeout], [3, 2, 120]);
    expect(config.it.ltRequiredEnv, ['REGISTRY_TOKEN']);
    expect([config.credentials.provider, config.credentials.file], ['file', 'secrets/logins.json']);
    expect(config.network.proxiedDomains, ['.example.test']);
    expect(config.reporting.sinks.single, {'type': 'junit', 'path': 'out/junit.xml'});
  });

  group('configFilePath', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('mplatrol_config'));
    tearDown(() => root.deleteSync(recursive: true));

    test('is the env override, else the nearest mplatrol.yaml at or above the start, else null', () {
      final nested = Directory(p.join(root.path, 'a', 'b'))..createSync(recursive: true);
      expect(MplatrolConfig.configFilePath(const {}, nested.path), isNot(startsWith(root.path)));
      File(p.join(root.path, 'a', mplatrolConfigFileName)).writeAsStringSync('tenant: x\n');

      expect(MplatrolConfig.configFilePath(const {}, nested.path), p.join(root.path, 'a', mplatrolConfigFileName));
      expect(MplatrolConfig.configFilePath(const {mplatrolConfigEnv: '/x/custom.yaml'}, nested.path), '/x/custom.yaml');
    });
  });

  group('lessons', () {
    test('parses the lessons block into project lessons', () {
      final config = MplatrolConfig.fromYaml(loadYaml('''
lessons:
  - name: paymentsSandboxDown
    category: env-failure
    pattern: 'payments sandbox returned 50\\d'
    symptom: The payments sandbox answers HTTP 5xx
    remedy: Rerun when the sandbox is up.
  - name: seedDataMissing
    category: test-data-failure
    pattern: SEED_DATA_MISSING
    symptom: The seed data job did not run
    remedy: Run the seed job for the tenant.
'''));

      final lessons = config.lessons;
      expect([for (final lesson in lessons) lesson.name], ['paymentsSandboxDown', 'seedDataMissing']);
      expect([for (final lesson in lessons) lesson.category],
          [ItResultCategory.envFailure, ItResultCategory.testDataFailure]);
      expect(lessons.first.pattern, r'payments sandbox returned 50\d');
      expect(MplatrolConfig.fromYaml(null).lessons, isEmpty);
    });

    for (final (yaml, problem) in [
      ('lessons: {a: 1}', 'must be a list'),
      ('lessons: [x]', 'must be a map'),
      ('lessons: [{name: a, category: nope, pattern: p, symptom: s, remedy: r}]', 'unknown category "nope"'),
      ('lessons: [{name: a, category: lt-failure, symptom: s, remedy: r}]', 'needs a non-empty "pattern"'),
    ]) {
      test('rejects `$yaml`', () {
        expect(() => MplatrolConfig.fromYaml(loadYaml(yaml)).lessons,
            throwsA(isA<FormatException>().having((error) => error.message, 'message', contains(problem))));
      });
    }
  });
}
