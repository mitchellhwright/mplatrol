import 'dart:io';

import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/upgrade/upgrade_leg.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _upgradeFile = '''
$upgradeFromMarker
void main() {
  patrolTest('UPGRADE-SETUP previous release records state', (\$) async {});
  patrolTest('PROJ-TC-7765 upgraded app keeps state', (\$) async {});
}
''';

void main() {
  group('UpgradeLeg', () {
    test('fromEnv reads the leg, null when unset or blank', () {
      expect(UpgradeLeg.fromEnv(const {}), isNull);
      expect(UpgradeLeg.fromEnv(const {e2eUpgradeLegEnv: ' '}), isNull);
      expect(UpgradeLeg.fromEnv(const {e2eUpgradeLegEnv: 'setup'}), UpgradeLeg.setup);
      expect(UpgradeLeg.fromEnv(const {e2eUpgradeLegEnv: ' verify '}), UpgradeLeg.verify);
    });

    test('fromEnv rejects a value that is not a leg', () {
      expect(
        () => UpgradeLeg.fromEnv(const {e2eUpgradeLegEnv: 'both'}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('expected setup or verify'))),
      );
    });

    test('setup runs the UPGRADE-SETUP tests and verify runs the rest', () {
      expect(UpgradeLeg.setup.runs('UPGRADE-SETUP x'), isTrue);
      expect(UpgradeLeg.setup.runs('PROJ-TC-7765 x'), isFalse);
      expect(UpgradeLeg.verify.runs('UPGRADE-SETUP x'), isFalse);
      expect(UpgradeLeg.verify.runs('PROJ-TC-7765 x'), isTrue);
    });

    test('declaresUpgradeFrom needs the marker on a line of its own', () {
      expect(declaresUpgradeFrom('$upgradeFromMarker\nlibrary;'), isTrue);
      expect(declaresUpgradeFrom('  $upgradeFromMarker  \n'), isTrue);
      expect(declaresUpgradeFrom('// see $upgradeFromMarker for upgrades'), isFalse);
    });
  });

  group('discovery of upgrade files', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('upgrade_discovery');
      Directory(p.join(repo.path, 'patrol_test')).createSync();
      File(p.join(repo.path, 'patrol_test', 'release_upgrade_journey_test.dart')).writeAsStringSync(_upgradeFile);
      File(p.join(repo.path, 'patrol_test', 'login_test.dart')).writeAsStringSync("patrolTest('login works');");
    });

    tearDown(() => repo.deleteSync(recursive: true));

    List<String> descriptions(Map<String, String> environment, {String? target}) => [
          for (final file in discoverPatrolTestFiles(repo.path, environment: environment, target: target))
            for (final test in file.tests) test.description,
        ];

    test('a normal run leaves the upgrade file out', () {
      expect(descriptions(const {}), ['login works']);
    });

    test('the setup leg runs only the UPGRADE-SETUP tests of upgrade files', () {
      expect(descriptions(const {e2eUpgradeLegEnv: 'setup'}), ['UPGRADE-SETUP previous release records state']);
    });

    test('the verify leg runs only the other tests of upgrade files', () {
      expect(descriptions(const {e2eUpgradeLegEnv: 'verify'}), ['PROJ-TC-7765 upgraded app keeps state']);
    });

    test('everyTest discovers the upgrade file whole, in or outside a leg', () {
      for (final environment in [
        const <String, String>{},
        const {e2eUpgradeLegEnv: 'setup'}
      ]) {
        final files = discoverPatrolTestFiles(repo.path, environment: environment, everyTest: true);
        expect([for (final file in files) file.tests.length], [1, 2]);
      }
    });

    test('an explicit target runs the upgrade file outside a leg', () {
      expect(descriptions(const {}, target: 'patrol_test/release_upgrade_journey_test.dart'), hasLength(2));
    });
  });

  test('the leg reaches the app as E2E_UPGRADE_LEG', () {
    final repo = Directory.systemTemp.createTempSync('upgrade_defines');
    addTearDown(() => repo.deleteSync(recursive: true));
    expect(e2eRuntimeDartDefines(repo.path, const {e2eUpgradeLegEnv: 'verify'}), {e2eUpgradeLegDefine: 'verify'});
    expect(e2eRuntimeDartDefines(repo.path, const {}), isNot(contains(e2eUpgradeLegDefine)));
  });
}
