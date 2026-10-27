import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

ProcessResultX _result(String stdout, {int exitCode = 0}) =>
    ProcessResultX.from(ProcessResult(0, exitCode, stdout, ''));

/// Builds a decoded `.mobileprovision` plist payload (what `security cms -D`
/// prints) with the fields the installed-profile pickers key off.
String _payload({
  String? appId,
  String? name = 'Dev Profile',
  bool provisioned = false,
  String? expires,
}) {
  final buf = StringBuffer('<?xml version="1.0"?><plist><dict>');
  if (expires != null) {
    buf.write('<key>ExpirationDate</key><date>$expires</date>');
  }
  if (name != null) {
    buf.write('<key>Name</key><string>$name</string>');
  }
  if (appId != null) {
    buf.write('<key>application-identifier</key><string>$appId</string>');
  }
  if (provisioned) {
    buf.write('<key>ProvisionedDevices</key><array><string>ID</string></array>');
  }
  buf.write('</dict></plist>');
  return buf.toString();
}

// 40-hex SHA-1 identities, the form `security find-identity` prints.
const _exampleSha = '1111111111111111111111111111111111111111';
const _otherSha = '2222222222222222222222222222222222222222';

void main() {
  late MplatrolShell shell;
  late PlatformWrapper platform;

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    platform = getDep<PlatformWrapper>();
  });

  IosCodesign codesign() => IosCodesign();

  /// Stubs `security find-identity` to return [output].
  void stubSecurity(String output) {
    when(
      () => shell.runArgs('security', any(), throwOnError: any(named: 'throwOnError')),
    ).thenAnswer((_) async => _result(output));
  }

  group('developerIdentity', () {
    test('prefers an Example Apple Development cert', () async {
      stubSecurity(
        '  1) $_exampleSha "Apple Development: Example Dev (S23286B229)"\n'
        '  2) $_otherSha "Apple Development: Other Person (ZZZ)"\n'
        '     2 valid identities found\n',
      );

      expect(await codesign().developerIdentity(), _exampleSha);
    });

    test('falls back to the first Apple Development cert when none is Example', () async {
      stubSecurity(
        '  1) $_otherSha "Apple Development: Other Person (ZZZ)"\n'
        '     1 valid identities found\n',
      );

      expect(await codesign().developerIdentity(), _otherSha);
    });

    test('returns null when there is no Apple Development cert', () async {
      stubSecurity(
        '  1) $_exampleSha "Apple Distribution: Example Inc (TEAM)"\n'
        '     1 valid identities found\n',
      );

      expect(await codesign().developerIdentity(), isNull);
    });
  });

  group('provisioningProfile', () {
    late Directory home;
    late Directory profilesDir;

    setUp(() {
      home = Directory.systemTemp.createTempSync('ios_codesign_home');
      profilesDir = Directory(p.join(home.path, 'Library', 'MobileDevice', 'Provisioning Profiles'))
        ..createSync(recursive: true);
      when(() => platform.environment).thenReturn({'HOME': home.path, 'CODESIGN_TEAM': 'TEAMID1234'});
      // `strings` is stubbed to echo the file's own bytes, mirroring the real
      // tool closely enough for the substring match the picker relies on.
      when(() => shell.runArgs('strings', any(), throwOnError: any(named: 'throwOnError'))).thenAnswer((
        invocation,
      ) async {
        final path = (invocation.positionalArguments[1] as List).first as String;
        return _result(File(path).readAsStringSync());
      });
    });

    tearDown(() {
      if (home.existsSync()) {
        home.deleteSync(recursive: true);
      }
    });

    test('returns the profile whose strings contain the bundle id', () async {
      File(p.join(profilesDir.path, 'other.mobileprovision')).writeAsStringSync('com.example.other');
      final match = File(p.join(profilesDir.path, 'match.mobileprovision'))
        ..writeAsStringSync('binary...com.example.app.uitests.xctrunner...more');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner');

      expect(result, match.path);
    });

    test('ignores non-mobileprovision files', () async {
      File(p.join(profilesDir.path, 'README.txt')).writeAsStringSync('com.example.app.uitests.xctrunner');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner');

      expect(result, isNull);
    });

    test('returns null when no profile matches the bundle id', () async {
      File(p.join(profilesDir.path, 'a.mobileprovision')).writeAsStringSync('com.example.a');

      expect(await codesign().provisioningProfile('com.example.nope'), isNull);
    });

    test("finds profiles in Xcode 16's UserData directory", () async {
      // Xcode 16 installs profiles under Library/Developer/Xcode/UserData,
      // not the legacy Library/MobileDevice location.
      final xcodeDir = Directory(
        p.join(home.path, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles'),
      )..createSync(recursive: true);
      final match = File(p.join(xcodeDir.path, 'new.mobileprovision'))
        ..writeAsStringSync('...com.example.app.uitests.xctrunner...');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner');

      expect(result, match.path);
    });

    test('falls back to a team wildcard profile when no exact match exists', () async {
      // Auto-created XCTRunner bundle ids (<app id>.uitests.xctrunner) rarely
      // have their own profile; a team wildcard can sign them.
      final wildcard = File(p.join(profilesDir.path, 'wild.mobileprovision'))
        ..writeAsStringSync('...<string>TEAMID1234.*</string>...');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner', team: 'TEAMID1234');

      expect(result, wildcard.path);
    });

    test('skips profiles whose strings output is not valid UTF-8', () async {
      // Some installed profiles make `strings` emit byte runs the UTF-8
      // decoder rejects; one unreadable file must not abort the scan.
      final bad = File(p.join(profilesDir.path, 'bad.mobileprovision'))..writeAsStringSync('binary');
      when(
        () => shell.runArgs('strings', [bad.path], throwOnError: any(named: 'throwOnError')),
      ).thenThrow(const FormatException('Unexpected extension byte'));
      final xcodeDir = Directory(
        p.join(home.path, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles'),
      )..createSync(recursive: true);
      final match = File(p.join(xcodeDir.path, 'good.mobileprovision'))
        ..writeAsStringSync('...com.example.app.uitests.xctrunner...');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner');

      expect(result, match.path);
    });

    test('prefers an exact bundle-id profile over a team wildcard', () async {
      File(p.join(profilesDir.path, 'a-wild.mobileprovision')).writeAsStringSync('...<string>TEAMID1234.*</string>...');
      final exact = File(p.join(profilesDir.path, 'b-exact.mobileprovision'))
        ..writeAsStringSync('...com.example.app.uitests.xctrunner...');

      final result = await codesign().provisioningProfile('com.example.app.uitests.xctrunner', team: 'TEAMID1234');

      expect(result, exact.path);
    });

    test('returns null when the profiles directory does not exist', () async {
      profilesDir.deleteSync(recursive: true);

      expect(await codesign().provisioningProfile('com.example.app'), isNull);
    });

    test('returns null when HOME is not set', () async {
      when(() => platform.environment).thenReturn(const {});

      expect(await codesign().provisioningProfile('com.example.app'), isNull);
    });
  });

  group('installed profiles', () {
    late Directory home;
    late Directory profilesDir;

    setUp(() {
      home = Directory.systemTemp.createTempSync('ios_codesign_installed');
      profilesDir = Directory(
        p.join(home.path, 'Library', 'MobileDevice', 'Provisioning Profiles'),
      )..createSync(recursive: true);
      when(() => platform.environment).thenReturn({'HOME': home.path, 'CODESIGN_TEAM': 'TEAMID1234'});
      // `security cms -D -i <path>` echoes the decoded payload; the file's own
      // text stands in for the decoded plist, and a missing file resigns to a
      // non-zero exit (payload null).
      when(
        () => shell.runArgs('security', any(), throwOnError: any(named: 'throwOnError')),
      ).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List;
        if (args.isNotEmpty && args.first == 'cms') {
          final file = File(args[3] as String);
          if (!file.existsSync()) {
            return _result('', exitCode: 1);
          }
          return _result(file.readAsStringSync());
        }
        return _result('');
      });
    });

    tearDown(() {
      if (home.existsSync()) {
        home.deleteSync(recursive: true);
      }
    });

    File writeProfile(String fileName, String contents, {Directory? dir}) =>
        File(p.join((dir ?? profilesDir).path, fileName))..writeAsStringSync(contents);

    group('installedProfileForBundleId', () {
      test('returns the profile whose application-identifier matches', () async {
        writeProfile('other.mobileprovision', _payload(appId: 'TEAMID1234.com.other'));
        final match =
            writeProfile('match.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app', name: 'Example App'));

        final result = await codesign().installedProfileForBundleId('com.example.app');

        expect(result, isNotNull);
        expect(result!.path, match.path);
        expect(result.name, 'Example App');
        expect(result.applicationIdentifier, 'TEAMID1234.com.example.app');
      });

      test('skips an expired profile so the signing command can install the current one', () async {
        writeProfile('a.mobileprovision',
            _payload(appId: 'TEAMID1234.com.example.app', name: 'Old', expires: '2026-09-19T15:00:00Z'));

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);

        final current = writeProfile('b.mobileprovision',
            _payload(appId: 'TEAMID1234.com.example.app', name: 'Current', expires: '2099-01-01T00:00:00Z'));
        final result = await codesign().installedProfileForBundleId('com.example.app');
        expect(result?.path, current.path);
        expect(result?.name, 'Current');
      });

      test('does not require ProvisionedDevices', () async {
        writeProfile('m.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app'));

        final result = await codesign().installedProfileForBundleId('com.example.app');

        expect(result, isNotNull);
      });

      test('finds profiles in the Xcode 16 UserData directory', () async {
        final xcodeDir = Directory(
          p.join(home.path, 'Library', 'Developer', 'Xcode', 'UserData', 'Provisioning Profiles'),
        )..createSync(recursive: true);
        final match = writeProfile('u.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app'), dir: xcodeDir);

        final result = await codesign().installedProfileForBundleId('com.example.app');

        expect(result!.path, match.path);
      });

      test('ignores non-mobileprovision files', () async {
        writeProfile('README.txt', _payload(appId: 'TEAMID1234.com.example.app'));

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);
      });

      test('skips a profile whose application-identifier does not match', () async {
        writeProfile('a.mobileprovision', _payload(appId: 'TEAMID1234.com.nope'));

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);
      });

      test('skips a profile that has no Name', () async {
        writeProfile('a.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app', name: ''));

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);
      });

      test('skips a profile whose payload cannot be decoded', () async {
        final bad = writeProfile('bad.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app'));
        when(
          () => shell.runArgs('security', ['cms', '-D', '-i', bad.path], throwOnError: any(named: 'throwOnError')),
        ).thenAnswer((_) async => _result('', exitCode: 1));
        final good = writeProfile('good.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app'));

        final result = await codesign().installedProfileForBundleId('com.example.app');

        expect(result!.path, good.path);
      });

      test('returns null when the profiles directory does not exist', () async {
        profilesDir.deleteSync(recursive: true);

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);
      });

      test('returns null when HOME is not set', () async {
        when(() => platform.environment).thenReturn(const {});

        expect(await codesign().installedProfileForBundleId('com.example.app'), isNull);
      });
    });

    group('installedDevelopmentProfileForBundleId', () {
      test('requires a ProvisionedDevices key', () async {
        writeProfile('nodev.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app'));

        expect(await codesign().installedDevelopmentProfileForBundleId('com.example.app'), isNull);
      });

      test('returns a development profile that matches', () async {
        final match = writeProfile(
            'dev.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app', name: 'Dev', provisioned: true));

        final result = await codesign().installedDevelopmentProfileForBundleId('com.example.app');

        expect(result!.path, match.path);
        expect(result.name, 'Dev');
      });
    });

    group('installedXctrunnerDevelopmentProfile', () {
      test('returns a provisioned team xctrunner profile', () async {
        final match = writeProfile('xc.mobileprovision',
            _payload(appId: 'TEAMID1234.com.example.app.uitests.xctrunner', name: 'XC Runner', provisioned: true));

        final result = await codesign().installedXctrunnerDevelopmentProfile();

        expect(result!.path, match.path);
        expect(result.name, 'XC Runner');
        expect(result.applicationIdentifier, 'TEAMID1234.com.example.app.uitests.xctrunner');
      });

      test('skips an expired xctrunner profile', () async {
        writeProfile(
            'xc_old.mobileprovision',
            _payload(
                appId: 'TEAMID1234.com.example.app.uitests.xctrunner',
                provisioned: true,
                expires: '2026-09-19T15:00:00Z'));

        expect(await codesign().installedXctrunnerDevelopmentProfile(), isNull);
      });

      test('skips profiles without ProvisionedDevices', () async {
        writeProfile('noprov.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app.uitests.xctrunner'));

        expect(await codesign().installedXctrunnerDevelopmentProfile(), isNull);
      });

      test('skips wrong-team, non-xctrunner, no-id, and unnamed profiles', () async {
        writeProfile('noid.mobileprovision', _payload(provisioned: true));
        writeProfile(
            'wrongteam.mobileprovision', _payload(appId: 'OTHER.com.example.app.uitests.xctrunner', provisioned: true));
        writeProfile('notrunner.mobileprovision', _payload(appId: 'TEAMID1234.com.example.app', provisioned: true));
        writeProfile('unnamed.mobileprovision',
            _payload(appId: 'TEAMID1234.com.example.app.uitests.xctrunner', name: '', provisioned: true));

        expect(await codesign().installedXctrunnerDevelopmentProfile(), isNull);
      });

      test('returns null when HOME is not set', () async {
        when(() => platform.environment).thenReturn(const {});

        expect(await codesign().installedXctrunnerDevelopmentProfile(), isNull);
      });

      test('returns null when the profiles directory does not exist', () async {
        profilesDir.deleteSync(recursive: true);

        expect(await codesign().installedXctrunnerDevelopmentProfile(), isNull);
      });
    });
  });

  group('canSignHeadless', () {
    test('returns true when codesign succeeds', () async {
      when(
        () => shell.runArgs('codesign', any(), throwOnError: any(named: 'throwOnError')),
      ).thenAnswer((_) async => _result(''));

      expect(await codesign().canSignHeadless('SHA'), isTrue);
    });

    test('returns false when codesign reports errSecInternalComponent', () async {
      when(
        () => shell.runArgs('codesign', any(), throwOnError: any(named: 'throwOnError')),
      ).thenAnswer((_) async => _result('errSecInternalComponent', exitCode: 1));

      expect(await codesign().canSignHeadless('SHA'), isFalse);
    });

    test('returns true (no false alarm) when the sample binary is absent', () async {
      expect(await codesign().canSignHeadless('SHA', sampleBinary: '/no/such/bin'), isTrue);
    });
  });
}
