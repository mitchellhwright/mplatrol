import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.repo.deleteSync(recursive: true));
  _selectionCases(() => fixture);
  _failureCases(() => fixture);
  _unknownMetadataCases(() => fixture);
  _packageRegistrationCases(() => fixture);
  _bindingCases(() => fixture);
  _journeyWiringCases(() => fixture);
  _descriptionMappingCases(() => fixture);
  _ltNotSelectedCases(() => fixture);
  _manifestShapeCases(() => fixture);
  _preparedEvidenceCases(() => fixture);
  _runtimeConfigCases(() => fixture);
}

/// Requires the vendor journey's wallet to be enabled in the tenant runtime
/// configuration, like the Visa wallet journey, and records [config] as the
/// prepared bundle.
void _requireEnabledWallet(_Fixture fixture, Map<String, Object?> config) {
  final capabilities = fixture.manifest['capabilities']! as Map;
  (capabilities['vendor'] as Map)[runtimeConfigKey] = {
    'android': ['wallet.isEnabled', 'wallet.appId', 'wallet.googlePayEnabled'],
    'ios': ['wallet.isEnabled', 'wallet.appId', 'wallet.applePayEnabled'],
  };
  fixture.saveManifest();
  fixture.write('assets/runtime_configuration/staging/rc_tenant.json', jsonEncode(config));
  fixture.write(
      e2eRuntimeConfigRecordPath,
      jsonEncode({
        'schemaVersion': 1,
        'bundle': 'assets/runtime_configuration/staging/rc_tenant.json',
      }));
}

void _runtimeConfigCases(_Fixture Function() current) {
  // Regression: hooli 2026-10-02 lt-ios scheduled the Visa wallet journey
  // although its runtime configuration disables Visa push provisioning, and the
  // test then skipped at runtime with sdk_or_wallet_not_built.
  test('an SDK the tenant runtime configuration disables is excluded, not a runtime skip', () {
    final fixture = current();
    _requireEnabledWallet(fixture, {
      'wallet': {'isEnabled': false, 'appId': '', 'applePayEnabled': false, 'googlePayEnabled': false},
    });
    for (final platform in ['android', 'ios', 'ios-simulator']) {
      final plan = fixture.plan(platform: platform);
      expect(plan.selectedCount, 2, reason: platform);
      expect(plan.excluded.single.reason, 'SDK not enabled in the tenant runtime configuration: vendor',
          reason: platform);
    }
  });
  test('the runtime configuration is checked per platform', () {
    final fixture = current();
    _requireEnabledWallet(fixture, {
      'wallet': {'isEnabled': true, 'appId': 'visa-app', 'applePayEnabled': false, 'googlePayEnabled': true},
    });
    expect(fixture.plan().selectedCount, 3);
    expect(fixture.plan(platform: 'ios').excluded.single.reason,
        'SDK not enabled in the tenant runtime configuration: vendor');
  });
  test('a platform without runtime configuration paths needs none', () {
    final fixture = current();
    _requireEnabledWallet(fixture, {'wallet': 'not an object'});
    final capability = (fixture.manifest['capabilities']! as Map)['vendor'] as Map;
    capability[runtimeConfigKey] = {'android': <String>[]};
    fixture.saveManifest();
    expect(fixture.plan().selectedCount, 3);
    expect(fixture.plan(platform: 'ios').selectedCount, 3);
  });
  test('the selected runtime configuration is part of the capability digest', () {
    final fixture = current();
    _requireEnabledWallet(fixture, {
      'wallet': {'isEnabled': true, 'appId': 'visa-app', 'googlePayEnabled': true},
    });
    final before = fixture.plan().capabilityDigest;
    fixture.write(
        'assets/runtime_configuration/staging/rc_tenant.json',
        jsonEncode({
          'wallet': {'isEnabled': true, 'appId': 'other', 'googlePayEnabled': true}
        }));
    expect(fixture.plan().capabilityDigest, isNot(before));
  });
  for (final (name, record) in [
    ('missing', null),
    ('unknown schema', {'schemaVersion': 2, 'bundle': 'rc.json'}),
    ('absolute bundle', {'schemaVersion': 1, 'bundle': '/etc/rc.json'}),
    ('escaping bundle', {'schemaVersion': 1, 'bundle': '../rc.json'}),
    ('empty bundle', {'schemaVersion': 1, 'bundle': ''}),
  ]) {
    test('runtime configuration record ($name) fails closed', () {
      final fixture = current();
      _requireEnabledWallet(fixture, {
        'wallet': {'isEnabled': true}
      });
      final file = File(p.join(fixture.repo.path, e2eRuntimeConfigRecordPath));
      if (record == null) {
        file.deleteSync();
      } else {
        file.writeAsStringSync(jsonEncode(record));
      }
      expect(fixture.plan, throwsStateError);
    });
  }
  for (final (name, requirement) in [
    ('non-object', ['wallet.isEnabled']),
    (
      'unknown platform',
      {
        'web': ['wallet.isEnabled']
      }
    ),
    (
      'empty path',
      {
        'android': ['']
      }
    ),
  ]) {
    test('runtime configuration requirement ($name) fails closed', () {
      final fixture = current();
      _requireEnabledWallet(fixture, {
        'wallet': {'isEnabled': true}
      });
      ((fixture.manifest['capabilities']! as Map)['vendor'] as Map)[runtimeConfigKey] = requirement;
      fixture.saveManifest();
      expect(fixture.plan, throwsStateError);
    });
  }
}

void _descriptionMappingCases(_Fixture Function() current) {
  const description = 'opens the configured vendor UI';
  for (final mapping in ['matching', 'missing', 'stale']) {
    test('renamed SDK description with $mapping explicit mapping', () {
      final fixture = current();
      fixture.write('patrol_test/neutral_test.dart', "patrolTest('$description');");
      final declarations = fixture.manifest['tests'] as List;
      final declaration = declarations.last as Map;
      if (mapping == 'missing') {
        declarations.removeLast();
      } else if (mapping == 'matching') {
        declaration['descriptions'] = [description];
      }
      fixture.saveManifest();
      if (mapping != 'matching') {
        expect(() => fixture.plan(sdk: 'vendor'), throwsStateError);
        return;
      }
      expect(declaration['requires'], [
        ['vendor']
      ]);
      final plan = fixture.plan(sdk: 'vendor');
      expect(plan.selectedCount, 1);
      expect(plan.excludedCount, 0);
      fixture.registration('// vendor.SdkRegistration();');
      expect(fixture.plan(sdk: 'vendor').selectedCount, 0);
      expect(fixture.plan(sdk: 'vendor').excludedCount, 1);
    });
  }
}

void _selectionCases(_Fixture Function() current) {
  test('explicit SDK requirements select neutral names, not filename guesses', () {
    final fixture = current();
    final plan = fixture.plan(sdk: 'vendor');
    expect(plan.files.map((file) => file.basename), ['neutral_test']);
    expect(plan.selectedCount, 1);
    expect(plan.excludedCount, 0);
  });
  test('active package/plugin/registration evidence selects every existing test', () {
    final plan = current().plan();
    expect(plan.selectedCount, 3);
    expect(plan.excludedCount, 0);
    expect(plan.toJson()['selectedCount'], 3);
    expect(plan.coverage['matrix_test'], 'aggregate-smoke');
  });
  test('commented registration excludes SDK journey, not a runtime skip', () {
    final fixture = current();
    fixture.registration('// vendor.SdkRegistration();');
    final plan = fixture.plan();
    expect(plan.selectedCount, 2);
    expect(plan.excludedCount, 1);
    expect(plan.excluded.single.reason, 'SDK not registered by the tenant build: vendor');
  });
  test('an inactive registration without a tag is missing journey wiring', () {
    final fixture = current();
    final vendor = (fixture.manifest['capabilities'] as Map)['vendor'] as Map;
    vendor['registrations'] = [
      {'source': 'lib/vendor_wiring.dart', 'symbol': 'vendor.SdkRegistration()'},
    ];
    fixture
      ..write('lib/vendor_wiring.dart', '// vendor.SdkRegistration();')
      ..saveManifest();
    expect(fixture.plan().excluded.single.reason, 'SDK journey wiring missing: vendor');
  });
  test('registration text inside a string does not claim SDK presence', () {
    final fixture = current();
    fixture.registration("print('vendor.SdkRegistration()');");
    expect(fixture.plan().excludedCount, 1);
  });
  test('native_build false excludes the actual SDK requirement', () {
    final fixture = current();
    fixture.plugins(nativeBuild: false);
    expect(fixture.plan().excludedCount, 1);
  });
  test('platform metadata is independent; Android plugin does not prove iOS', () {
    final fixture = current();
    fixture.plugins(ios: false);
    expect(fixture.plan().selectedCount, 3);
    final ios = fixture.plan(platform: 'ios');
    expect(ios.selectedCount, 2);
    expect(ios.excludedCount, 1);
  });
  test('unsupported simulator platform is excluded, not registered and skipped', () {
    final fixture = current();
    final declaration = (fixture.manifest['tests'] as List).last as Map;
    declaration['platforms'] = ['android', 'ios'];
    fixture.saveManifest();
    final plan = fixture.plan(platform: 'ios-simulator');
    expect(plan.excluded.single.reason, 'unsupported platform: ios-simulator');
  });
  for (final platform in ['android', 'ios']) {
    test('a localOnly file is excluded from $platform LambdaTest selection', () {
      final fixture = current();
      (fixture.manifest['tests'] as List).cast<Map>().first['localOnly'] = true;
      fixture.saveManifest();
      final plan = fixture.plan(platform: platform);
      expect(plan.files.map((file) => file.basename), ['matrix_test', 'neutral_test']);
      expect(plan.excluded.single,
          (file: 'core_test', description: 'core', reason: 'local-only (not scheduled on LambdaTest)'));
    });
  }
  test('names the files that need a certificate-pinning SDK', () {
    final repo = Directory.systemTemp.createTempSync('pinning-');
    addTearDown(() => repo.deleteSync(recursive: true));
    expect(patrolCertificatePinningFiles(repo.path), isEmpty, reason: 'no manifest');
    File(p.join(repo.path, patrolSdkRequirementsPath))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        certificatePinningSdksKey: ['pinnedsdk'],
        'tests': [
          _declaration('pinnedsdk_accounts_journey_test', 'a', [
            ['pinnedsdk']
          ]),
          _declaration('either_test', 'b', [
            ['othersdk'],
            ['paysdk', 'pinnedsdk']
          ]),
          _declaration('vendor_test', 'c', [
            ['vendor']
          ]),
          _declaration('core_test', 'd', []),
        ],
      }));

    expect(patrolCertificatePinningFiles(repo.path), {'pinnedsdk_accounts_journey_test', 'either_test'});
  });

  test('localOnly false keeps the file selected', () {
    final fixture = current();
    (fixture.manifest['tests'] as List).cast<Map>().first['localOnly'] = false;
    fixture.saveManifest();
    expect(fixture.plan().selectedCount, 3);
  });
  test('missing SDK package with no active registration is an explicit exclusion', () {
    final fixture = current();
    fixture.registration('// vendor.SdkRegistration();');
    fixture.packages(includeSdk: false);
    expect(fixture.plan().excludedCount, 1);
  });
}

void _journeyWiringCases(_Fixture Function() current) {
  test(
      'prepared native PushSdk whose tenant prepare step leaves its tagged service commented is not registered by the tenant',
      () {
    final fixture = current();
    _configurePushSdk(fixture);
    final plan = fixture.plan(sdk: 'pushsdk');
    expect(plan.selectedCount, 0);
    expect(plan.excludedCount, 1);
    expect(plan.excluded.single.reason, 'SDK not registered by the tenant build: pushsdk');
    expect(plan.files, isEmpty);
    expect((plan.toJson()['excluded'] as List).single,
        containsPair('reason', 'SDK not registered by the tenant build: pushsdk'));
  });
  test('PushSdk wiring exclusion keeps native discovery and Dart bundle aligned', () {
    final fixture = current();
    _configurePushSdk(fixture);
    final plan = fixture.plan();
    expect(plan.selectedCount, 2);
    final files = discoverPatrolTestFiles(fixture.repo.path, selection: plan);
    expect(files.map((file) => file.basename), isNot(contains('neutral_test')));
    final target =
        retargetPatrolTestBundle(fixture.repo.path, target: null, targetRegex: null, sdk: null, selection: plan);
    expect(File(p.join(fixture.repo.path, target)).readAsStringSync(), isNot(contains('neutral_test.main()')));
  });
  for (final missing in ['package', 'native plugin']) {
    test('PushSdk keys alone cannot replace missing $missing evidence', () {
      final fixture = current();
      _configurePushSdk(fixture, includeSdk: missing != 'package', nativeBuild: missing != 'native plugin');
      fixture.write('assets/build_configuration.json', '{"pushsdkKey":"fixture-key"}');
      final plan = fixture.plan(sdk: 'pushsdk');
      expect(plan.selectedCount, 0);
      expect(plan.excluded.single.reason, 'SDK not built: pushsdk');
    });
  }
  test('wiring text in a string does not enable a prepared PushSdk journey', () {
    final fixture = current();
    _configurePushSdk(fixture);
    fixture.write(
        'lib/core/feature_registrations.dart',
        '// BEGIN MPLATROL TAG: example_push_notifications_registration\n'
            "print('example_push.FeatureRegistration()');\n"
            '// END MPLATROL TAG: example_push_notifications_registration\n');
    expect(fixture.plan().excluded.single.reason, 'SDK not registered by the tenant build: pushsdk');
  });
  test('an available alternative still satisfies the whole journey requirement', () {
    final fixture = current();
    fixture.registration('// vendor.SdkRegistration();');
    final definitions = fixture.manifest['capabilities'] as Map;
    definitions['alternative'] = <String, Object>{
      ...(definitions['vendor'] as Map<String, Object>),
      'registrations': [
        {'source': 'lib/alternative.dart', 'symbol': 'Alternative.register()'},
      ],
    };
    fixture.write('lib/alternative.dart', 'Alternative.register();');
    ((fixture.manifest['tests'] as List).last as Map)['requires'] = [
      ['vendor', 'alternative'],
    ];
    fixture.saveManifest();
    expect(fixture.plan().selectedCount, 3);
    expect(fixture.plan().excludedCount, 0);
  });
}

void _configurePushSdk(_Fixture fixture, {bool includeSdk = true, bool nativeBuild = true}) {
  fixture.manifest['capabilities'] = {
    'pushsdk': {
      'packages': ['example_push_notifications', 'pushsdk_flutter'],
      'nativePlugins': {
        'android': ['pushsdk_flutter'],
        'ios': ['pushsdk_flutter'],
      },
      'registrations': [
        {
          'source': 'lib/core/feature_registrations.dart',
          'tag': 'example_push_notifications_registration',
          'symbol': 'example_push.FeatureRegistration()',
        },
      ],
    },
  };
  ((fixture.manifest['tests'] as List).last as Map)['requires'] = [
    ['pushsdk'],
  ];
  fixture.write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          if (includeSdk)
            for (final name in ['example_push_notifications', 'pushsdk_flutter'])
              {'name': name, 'rootUri': '../', 'packageUri': 'lib/'},
        ],
      }));
  fixture.write(
      '.flutter-plugins-dependencies',
      jsonEncode({
        'plugins': {
          for (final platform in ['android', 'ios'])
            platform: [
              {'name': 'pushsdk_flutter', 'native_build': nativeBuild}
            ],
        },
      }));
  fixture.write(
      'lib/core/feature_registrations.dart',
      '// BEGIN MPLATROL TAG: example_push_notifications_registration\n'
          '// example_push.FeatureRegistration();\n'
          '// END MPLATROL TAG: example_push_notifications_registration\n');
  fixture.saveManifest();
}

void _failureCases(_Fixture Function() current) {
  for (final path in [
    '.dart_tool/package_config.json',
    '.flutter-plugins-dependencies',
    'pubspec.lock',
    'lib/core/feature_registrations.dart',
    patrolSdkRequirementsPath,
  ]) {
    test('missing $path fails closed', () {
      final fixture = current();
      File(p.join(fixture.repo.path, path)).deleteSync();
      expect(fixture.plan, throwsStateError);
    });
  }
  test('malformed package metadata fails closed', () {
    final fixture = current();
    fixture.write('.dart_tool/package_config.json', '{');
    expect(() => fixture.plan(target: 'patrol_test/core_test.dart'), throwsStateError);
  });
  test('missing native platform list fails closed even for core selection', () {
    final fixture = current();
    fixture.write('.flutter-plugins-dependencies', '{"plugins":{}}');
    expect(() => fixture.plan(target: 'patrol_test/core_test.dart'), throwsStateError);
  });
  test('active registration without resolved packages is unknown, not absent', () {
    final fixture = current();
    fixture.packages(includeSdk: false);
    expect(fixture.plan, throwsStateError);
  });
  test('unknown SDK does not fall back to substring selection', () {
    expect(() => current().plan(sdk: 'vend'), throwsStateError);
  });
  test('new undeclared test cannot disappear from native coverage', () {
    final fixture = current();
    fixture.write('patrol_test/new_test.dart', "patrolTest('new journey');");
    expect(fixture.plan, throwsStateError);
  });
  test('renamed description requires its manifest declaration to change', () {
    final fixture = current();
    fixture.write('patrol_test/neutral_test.dart', "patrolTest('renamed');");
    expect(fixture.plan, throwsStateError);
  });
  test('undefined SDK requirement fails closed even when its file is not targeted', () {
    final fixture = current();
    final declaration = (fixture.manifest['tests'] as List).last as Map;
    declaration['requires'] = [
      ['unknown']
    ];
    fixture.saveManifest();
    expect(fixture.plan, throwsStateError);
  });
  test('active SDK with unresolved metadata cannot silently exclude a variant', () {
    final fixture = current();
    fixture.manifest['unresolvedRegistrations'] = [
      {
        'source': 'lib/core/feature_registrations.dart',
        'tag': 'vendor_registration',
        'symbol': 'vendor.SdkRegistration()',
        'reason': 'metadata not established'
      },
    ];
    fixture.saveManifest();
    expect(fixture.plan, throwsStateError);
  });
}

void _bindingCases(_Fixture Function() current) {
  test('native discovery and Dart bundle consume exactly the same plan', () {
    final fixture = current();
    fixture.registration('// vendor.SdkRegistration();');
    final plan = fixture.plan();
    final files = discoverPatrolTestFiles(fixture.repo.path, selection: plan);
    expect(identical(files, plan.files), isTrue);
    final target =
        retargetPatrolTestBundle(fixture.repo.path, target: null, targetRegex: null, sdk: null, selection: plan);
    final bundle = File(p.join(fixture.repo.path, target)).readAsStringSync();
    expect(bundle, contains('core_test.main()'));
    expect(bundle, contains('matrix_test.main()'));
    expect(bundle, isNot(contains('neutral_test')));
  });
  test('changed capability input invalidates a prepared plan before generation', () {
    final fixture = current();
    final plan = fixture.plan();
    fixture.plugins(nativeBuild: false);
    expect(() => discoverPatrolTestFiles(fixture.repo.path, selection: plan), throwsStateError);
    expect(() => fixture.plan().capabilityDigest, returnsNormally);
    expect(fixture.plan().capabilityDigest, isNot(plan.capabilityDigest));
  });
  test('changed manifest invalidates old selection and changes its digest', () {
    final fixture = current();
    final plan = fixture.plan();
    final declaration = (fixture.manifest['tests'] as List).last as Map;
    declaration['platforms'] = ['ios'];
    fixture.saveManifest();
    expect(() => discoverPatrolTestFiles(fixture.repo.path, selection: plan), throwsStateError);
    expect(fixture.plan().requirementsDigest, isNot(plan.requirementsDigest));
    expect(fixture.plan().selectionDigest, isNot(plan.selectionDigest));
  });
  test('plan cannot be reused with another target or SDK filter', () {
    final fixture = current();
    final plan = fixture.plan();
    expect(() => discoverPatrolTestFiles(fixture.repo.path, target: 'patrol_test/core_test.dart', selection: plan),
        throwsStateError);
    expect(() => discoverPatrolTestFiles(fixture.repo.path, sdk: 'vendor', selection: plan), throwsStateError);
  });
  test('partial file regex selection is rejected instead of registering a superset', () {
    final fixture = current();
    fixture.write('patrol_test/core_test.dart', "patrolTest('core'); patrolTest('other');");
    final declaration = (fixture.manifest['tests'] as List).first as Map;
    declaration['descriptions'] = ['core', 'other'];
    fixture.saveManifest();
    expect(() => fixture.plan(targetRegex: '^core\$'), throwsStateError);
  });
}

void _unknownMetadataCases(_Fixture Function() current) {
  test('nonliteral registration cannot be silently omitted from the source inventory', () {
    final fixture = current();
    fixture.write('patrol_test/dynamic_test.dart', 'void main() { registerJourneys(); }');
    expect(fixture.plan, throwsStateError);
  });
  test('a source added after planning invalidates native discovery', () {
    final fixture = current();
    final plan = fixture.plan();
    fixture.write('patrol_test/new_test.dart', "patrolTest('new');");
    expect(() => discoverPatrolTestFiles(fixture.repo.path, selection: plan), throwsStateError);
  });
  test('unknown native_build is not guessed to mean included or absent', () {
    final fixture = current();
    fixture.write('.flutter-plugins-dependencies', '{"plugins":{"android":[{"name":"vendor_plugin"}],"ios":[]}}');
    expect(fixture.plan, throwsStateError);
  });
  test('a duplicate native plugin cannot supply ambiguous capability evidence', () {
    final fixture = current();
    fixture.write(
        '.flutter-plugins-dependencies',
        jsonEncode({
          'plugins': {
            'android': [
              {'name': 'vendor_plugin', 'native_build': true},
              {'name': 'vendor_plugin', 'native_build': false},
            ],
            'ios': [],
          }
        }));
    expect(fixture.plan, throwsStateError);
  });
  test('mutating a native method invalidates selection instead of changing the artifact suite', () {
    final fixture = current();
    final plan = fixture.plan();
    plan.files.first.tests.first.method = 'different_native_method';
    expect(() => discoverPatrolTestFiles(fixture.repo.path, selection: plan), throwsStateError);
  });
}

class _Fixture {
  _Fixture() {
    write('pubspec.yaml', 'name: app\npatrol:\n  test_directory: patrol_test\n');
    write('pubspec.lock', 'packages: {}');
    write('patrol_test/core_test.dart', "patrolTest('core');");
    write('patrol_test/matrix_test.dart', "patrolTest('matrix');");
    write('patrol_test/neutral_test.dart', "patrolTest('contact journey');");
    packages();
    plugins();
    registration('vendor.SdkRegistration();');
    saveManifest();
  }

  final Directory repo = Directory.systemTemp.createTempSync('sdk-selection-');
  final Map<String, Object?> manifest = {
    'schema': 1,
    'capabilities': {
      'vendor': {
        'packages': ['vendor_api', 'vendor_plugin'],
        'nativePlugins': {
          'android': ['vendor_plugin'],
          'ios': ['vendor_plugin']
        },
        'registrations': [
          {
            'source': 'lib/core/feature_registrations.dart',
            'tag': 'vendor_registration',
            'symbol': 'vendor.SdkRegistration()'
          },
        ],
      },
    },
    'unresolvedRegistrations': <Object?>[],
    'tests': [
      _declaration('core_test', 'core', []),
      _declaration('matrix_test', 'matrix', [], coverage: 'aggregate-smoke'),
      _declaration('neutral_test', 'contact journey', [
        ['vendor']
      ]),
    ],
  };

  PatrolSelectionPlan plan(
          {String platform = 'android', String? target, String? targetRegex, String? sdk, String? tenant}) =>
      planPatrolSdkSelection(repo.path,
          platform: platform, target: target, targetRegex: targetRegex, sdk: sdk, tenant: tenant);

  void write(String path, String contents) => File(p.join(repo.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  void saveManifest() => write(patrolSdkRequirementsPath, jsonEncode(manifest));

  void packages({bool includeSdk = true}) => write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          if (includeSdk)
            for (final name in ['vendor_api', 'vendor_plugin']) {'name': name, 'rootUri': '../', 'packageUri': 'lib/'},
        ]
      }));

  void plugins({bool nativeBuild = true, bool ios = true}) => write(
      '.flutter-plugins-dependencies',
      jsonEncode({
        'plugins': {
          'android': [
            {'name': 'vendor_plugin', 'native_build': nativeBuild}
          ],
          'ios': [
            if (ios) {'name': 'vendor_plugin', 'native_build': nativeBuild}
          ],
        }
      }));

  void registration(String body) => write(
      'lib/core/feature_registrations.dart',
      '// BEGIN MPLATROL TAG: vendor_registration\n'
          '$body\n// END MPLATROL TAG: vendor_registration\n');
}

Map<String, Object?> _declaration(String name, String description, List<Object?> requires,
        {String coverage = 'journey'}) =>
    {
      'file': 'patrol_test/$name.dart',
      'descriptions': [description],
      'platforms': ['android', 'ios', 'ios-simulator'],
      'requires': requires,
      'coverage': coverage,
    };

void _packageRegistrationCases(_Fixture Function() current) {
  for (final suffix in ['', '/']) {
    test('resolved package registration uses its actual library directory (suffix="$suffix")', () {
      final fixture = current();
      fixture.write('packages/vendor_api/lib/feature.dart', 'vendor.SdkRegistration();');
      fixture.write(
          '.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'vendor_api', 'rootUri': '../packages/vendor_api$suffix', 'packageUri': 'lib/'},
              {'name': 'vendor_plugin', 'rootUri': '../', 'packageUri': 'lib/'},
            ],
          }));
      final definitions = fixture.manifest['capabilities'] as Map;
      (definitions['vendor'] as Map)['registrations'] = [
        {'source': 'package:vendor_api/feature.dart', 'symbol': 'vendor.SdkRegistration()'},
      ];
      fixture.saveManifest();
      expect(fixture.plan().selectedCount, 3);
      fixture.write('packages/vendor_api/lib/feature.dart', '// vendor.SdkRegistration();');
      expect(fixture.plan().excludedCount, 1);
    });
  }
}

Matcher _failsWith(String message) =>
    throwsA(isA<StateError>().having((error) => error.message, 'message', contains(message)));

Map<String, Object?> _vendor(_Fixture fixture) =>
    (fixture.manifest['capabilities'] as Map)['vendor'] as Map<String, Object?>;

Map<String, Object?> _lastDeclaration(_Fixture fixture) =>
    (fixture.manifest['tests'] as List).last as Map<String, Object?>;

void _setRegistration(_Fixture fixture, Map<String, Object?> registration) {
  _vendor(fixture)['registrations'] = [registration];
  fixture.saveManifest();
}

void _manifestShapeCases(_Fixture Function() current) {
  test('unknown selection platform fails closed before reading metadata', () {
    expect(() => current().plan(platform: 'windows'), _failsWith('Unknown SDK selection platform'));
  });
  test('unsupported manifest schema fails closed', () {
    final fixture = current();
    fixture.manifest['schema'] = 2;
    fixture.saveManifest();
    expect(fixture.plan, _failsWith('Unsupported SDK requirements schema'));
  });
  test('non-object capabilities fail closed', () {
    final fixture = current();
    fixture.manifest['capabilities'] = <Object?>[];
    fixture.saveManifest();
    expect(fixture.plan, _failsWith('invalid SDK capabilities'));
  });
  test('duplicate test requirement fails closed', () {
    final fixture = current();
    (fixture.manifest['tests'] as List).add(_declaration('core_test', 'core', []));
    fixture.saveManifest();
    expect(fixture.plan, _failsWith('Duplicate SDK test requirement'));
  });
  for (final file in ['/abs/patrol_test/core_test.dart', 'lib/core_test.dart']) {
    test('requirement outside the Patrol directory fails closed ($file)', () {
      final fixture = current();
      _lastDeclaration(fixture)['file'] = file;
      fixture.saveManifest();
      expect(fixture.plan, _failsWith('must be inside the Patrol source directory'));
    });
  }
  test('requirement for an undiscovered file fails closed', () {
    final fixture = current();
    _lastDeclaration(fixture)['file'] = 'patrol_test/ghost_test.dart';
    fixture.saveManifest();
    expect(fixture.plan, _failsWith('has no discovered Patrol registration'));
  });
  _declarationFieldCases(current);
}

void _declarationFieldCases(_Fixture Function() current) {
  final cases = <String, (String, Object?, String)>{
    'empty platform list': ('platforms', <Object?>[], 'Invalid explicit Patrol platform'),
    'unknown platform': ('platforms', ['web'], 'Invalid explicit Patrol platform'),
    'duplicate platform': ('platforms', ['android', 'android'], 'Duplicate supported platforms'),
    'unknown coverage': ('coverage', 'smoke', 'Unknown Patrol coverage classification'),
    'non-list requires': ('requires', 'vendor', 'Missing explicit SDK requirement groups'),
    'empty requirement group': ('requires', [<Object?>[]], 'Unknown or empty SDK requirement'),
    'non-list descriptions': ('descriptions', 'contact journey', 'invalid Patrol descriptions'),
    'blank description': ('descriptions', [' '], 'invalid Patrol descriptions'),
    'non-boolean localOnly': (
      'localOnly',
      'yes',
      '"localOnly" for "patrol_test/neutral_test.dart" '
          'must be true or false'
    ),
  };
  for (final MapEntry(key: name, value: (field, value, message)) in cases.entries) {
    test('declaration with $name fails closed', () {
      final fixture = current();
      _lastDeclaration(fixture)[field] = value;
      fixture.saveManifest();
      expect(fixture.plan, _failsWith(message));
    });
  }
}

void _preparedEvidenceCases(_Fixture Function() current) {
  test('unknown package_config version fails closed', () {
    final fixture = current();
    fixture.write('.dart_tool/package_config.json', '{"configVersion":1,"packages":[]}');
    expect(fixture.plan, _failsWith('Unknown prepared package metadata version'));
  });
  test('duplicate resolved package fails closed', () {
    final fixture = current();
    const package = {'name': 'vendor_api', 'rootUri': '../', 'packageUri': 'lib/'};
    fixture.write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [package, package],
      }),
    );
    expect(fixture.plan, _failsWith('Duplicate resolved package "vendor_api"'));
  });
  for (final field in ['packages', 'registrations']) {
    test('capability with empty $field fails closed', () {
      final fixture = current();
      _vendor(fixture)[field] = <Object?>[];
      fixture.saveManifest();
      expect(fixture.plan, _failsWith('lacks package or active registration evidence'));
    });
  }
  final registrations = <String, (Map<String, Object?>, String)>{
    'package source without a path': (
      {'source': 'package:vendor_api', 'symbol': 'vendor.SdkRegistration()'},
      'Invalid SDK registration package source',
    ),
    'package source with parent segments': (
      {'source': 'package:vendor_api/../x.dart', 'symbol': 'vendor.SdkRegistration()'},
      'Invalid SDK registration package source',
    ),
    'unresolved package source': (
      {'source': 'package:unknown_pkg/feature.dart', 'symbol': 'vendor.SdkRegistration()'},
      'Unknown SDK registration package',
    ),
    'source escaping the checkout': (
      {'source': '../outside.dart', 'symbol': 'vendor.SdkRegistration()'},
      'escapes the app checkout',
    ),
    'missing registration tag': (
      {
        'source': 'lib/core/feature_registrations.dart',
        'tag': 'absent_registration',
        'symbol': 'vendor.SdkRegistration()',
      },
      'Missing or ambiguous SDK registration tag "absent_registration"',
    ),
    'blank registration symbol': (
      {'source': 'lib/core/feature_registrations.dart', 'symbol': ''},
      'invalid registration symbol',
    ),
  };
  for (final MapEntry(key: name, value: (registration, message)) in registrations.entries) {
    test('registration with $name fails closed', () {
      final fixture = current();
      _setRegistration(fixture, registration);
      expect(fixture.plan, _failsWith(message));
    });
  }
}

void _ltNotSelectedCases(_Fixture Function() current) {
  for (final platform in ['android', 'ios']) {
    test('a mock of another tenant is not selected on a $platform LambdaTest leg', () {
      final fixture = current();
      fixture.write('patrol_test/core_test.dart',
          "final _mock = MockTarget(\n  'https://mock.test',\n  tenant: 'soylent',\n);\npatrolTest('core');");
      final plan = fixture.plan(platform: platform, tenant: 'hooli');
      expect(plan.files.map((file) => file.basename), ['matrix_test', 'neutral_test']);
      expect(plan.excluded.single, (
        file: 'core_test',
        description: 'core',
        reason: 'mock data belongs to soylent, not the leg tenant hooli (MOCK_TENANT_MISMATCH)'
      ));
    });
  }
  test('a mock of the leg tenant, or a run without a known tenant, keeps the mock selected', () {
    final fixture = current();
    fixture.write('patrol_test/core_test.dart',
        "MockTarget _mock(String key) => MockTarget(key, testCaseKey: key, tenant: \"CYBERDYNE\");\npatrolTest('core');");
    expect(fixture.plan(tenant: 'cyberdyne').selectedCount, 3);
    expect(fixture.plan().selectedCount, 3);
  });
  for (final (marker, reason) in [
    ('mock_required', 'needs a mock run (mock_required); mplatrol run configures no mock (MOCK_NOT_CONFIGURED)'),
    ('no_enrolled_biometrics', 'LambdaTest devices have no enrolled biometrics (DEVICE_NO_BIOMETRICS)'),
    ('device_locale_not_spanish', 'LambdaTest devices are never set to Spanish (DEVICE_LOCALE_MISMATCH)'),
  ]) {
    test('a test that can only skip with $marker on LambdaTest is not selected', () {
      final fixture = current();
      fixture.write('patrol_test/matrix_test.dart', "patrolTest('matrix', () => markTestSkipped('TAG $marker'));");
      final plan = fixture.plan(platform: 'ios', tenant: 'initech');
      expect(plan.excluded.single, (file: 'matrix_test', description: 'matrix', reason: reason));
    });
  }
  test('a marker inside a longer word does not exclude the test', () {
    final fixture = current();
    fixture.write('patrol_test/matrix_test.dart', "patrolTest('matrix', () => print('xmock_required'));");
    expect(fixture.plan(tenant: 'initech').selectedCount, 3);
  });
}
