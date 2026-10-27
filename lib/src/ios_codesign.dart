import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:path/path.dart' as p;

/// Auto-derives the iOS code-signing inputs the LambdaTest iOS resign needs, so
/// `mplatrol run lt-ios` works without anyone exporting `CODESIGN_IDENTITY` /
/// `LT_IOS_PROVISIONING_PROFILE` by hand. Mirrors `run_ios_lambdatest_xcui.sh`:
/// the runner re-signs with an Apple Development identity (the resign step needs
/// keychain access — it only runs outside the sandbox) and picks the
/// provisioning profile by `strings`-matching the xctrunner bundle id.
///
/// Each lookup returns null when nothing suitable is found — `mplatrol doctor` surfaces
/// that as a gap and the caller falls back / fails fast with a clear message.
/// Env var: the Apple Developer team id builds sign with.
const iosTeamIdEnv = 'CODESIGN_TEAM';

class IosCodesign {
  /// The Apple Developer team id used for signing and in the resign entitlements: [iosTeamIdEnv], or empty
  /// when it is not set (signing steps that need it then fail with Xcode's own message).
  static String get teamId => (getDep<PlatformWrapper>().environment[iosTeamIdEnv] ?? '').trim();

  MplatrolShell get _shell => getDep<MplatrolShell>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// SHA-1 of an Apple Development signing identity in the keychain (preferring
  /// one whose name contains [teamId]), or null if none is installed. `codesign --sign` accepts the
  /// SHA-1 directly. Override with `CODESIGN_IDENTITY` for a specific cert.
  Future<String?> developerIdentity() async {
    final result = await _shell.runArgs('security', ['find-identity', '-v', '-p', 'codesigning'], throwOnError: false);
    final devLines = result.outLines.where((line) => line.contains('Apple Development')).toList(growable: false);
    final preferred = devLines.firstWhere(
      (line) => teamId.isNotEmpty && line.contains(teamId),
      orElse: () => devLines.isEmpty ? '' : devLines.first,
    );
    return RegExp('([0-9A-F]{40})').firstMatch(preferred)?.group(1);
  }

  /// Path to an installed provisioning profile whose embedded strings include
  /// [bundleId] — the same pick the resign script makes (`strings | grep`), and
  /// sandbox-safe (unlike `security cms`). Searches both the legacy
  /// `Library/MobileDevice` location and Xcode 16's
  /// `Library/Developer/Xcode/UserData`. When [team] is given and no profile
  /// names [bundleId] exactly, falls back to a `<team>.*` wildcard profile —
  /// auto-created XCTRunner bundle ids (`<app id>.uitests.xctrunner`) rarely
  /// have their own profile, and a team wildcard can sign them. Null if none
  /// matches.
  Future<String?> provisioningProfile(String bundleId, {String? team}) async {
    final home = _platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }
    final dirs = [
      Directory('$home/Library/MobileDevice/Provisioning Profiles'),
      Directory('$home/Library/Developer/Xcode/UserData/Provisioning Profiles'),
    ];
    String? wildcard;
    for (final dir in dirs) {
      if (!dir.existsSync()) {
        continue;
      }
      for (final entry in dir.listSync()) {
        if (!entry.path.endsWith('.mobileprovision')) {
          continue;
        }
        final String outText;
        try {
          final result = await _shell.runArgs('strings', [entry.path], throwOnError: false);
          outText = result.outText;
        } on FormatException {
          // Some profiles make `strings` emit byte runs the UTF-8 decoder
          // rejects; an unreadable profile must not abort the scan.
          continue;
        }
        if (outText.contains(bundleId)) {
          return entry.path;
        }
        if (team != null && wildcard == null && outText.contains('<string>$team.*</string>')) {
          wildcard = entry.path;
        }
      }
    }
    return wildcard;
  }

  /// Installed provisioning profile that exactly matches [bundleId].
  ///
  /// This is stricter than [provisioningProfile], which intentionally supports
  /// wildcard fallback for LambdaTest resigning. Local physical iOS builds need
  /// the concrete profile name so Xcode's manual `PROVISIONING_PROFILE_SPECIFIER`
  /// points at a profile that is actually installed.
  Future<IosProvisioningProfile?> installedProfileForBundleId(
    String bundleId, {
    String? team,
  }) async {
    return _installedProfileForBundleId(
      bundleId,
      team: team ?? teamId,
      requireProvisionedDevices: false,
    );
  }

  /// Installed iOS App Development profile that exactly matches [bundleId].
  Future<IosProvisioningProfile?> installedDevelopmentProfileForBundleId(
    String bundleId, {
    String? team,
  }) async {
    return _installedProfileForBundleId(
      bundleId,
      team: team ?? teamId,
      requireProvisionedDevices: true,
    );
  }

  Future<IosProvisioningProfile?> _installedProfileForBundleId(
    String bundleId, {
    required String team,
    required bool requireProvisionedDevices,
  }) async {
    final home = _platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }
    final applicationIdentifier = '$team.${bundleId.trim()}';
    final dirs = [
      Directory('$home/Library/MobileDevice/Provisioning Profiles'),
      Directory('$home/Library/Developer/Xcode/UserData/Provisioning Profiles'),
    ];
    for (final dir in dirs) {
      if (!dir.existsSync()) {
        continue;
      }
      for (final entry in dir.listSync()) {
        if (!entry.path.endsWith('.mobileprovision')) {
          continue;
        }
        final payload = await _profilePayload(entry.path);
        if (payload == null) {
          continue;
        }
        if (requireProvisionedDevices && !payload.contains('<key>ProvisionedDevices</key>')) {
          continue;
        }
        if (!payload.contains('<string>$applicationIdentifier</string>') || _isExpired(payload)) {
          continue;
        }
        final name = _profileNameFromPayload(payload);
        if (name == null || name.isEmpty) {
          continue;
        }
        return IosProvisioningProfile(
          path: entry.path,
          name: name,
          applicationIdentifier: applicationIdentifier,
        );
      }
    }
    return null;
  }

  /// Installed iOS App Development profile that can sign an XCUITest runner.
  ///
  /// Physical-device local Patrol runs need a signed `.xctrunner` host app. In
  /// local environments without an Xcode account, Xcode cannot create this on
  /// demand, so mplatrol reuses any installed development runner profile.
  Future<IosProvisioningProfile?> installedXctrunnerDevelopmentProfile({
    String? team,
  }) async {
    final teamPrefix = '${team ?? teamId}.';
    final home = _platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }
    final dirs = [
      Directory('$home/Library/MobileDevice/Provisioning Profiles'),
      Directory('$home/Library/Developer/Xcode/UserData/Provisioning Profiles'),
    ];
    for (final dir in dirs) {
      if (!dir.existsSync()) {
        continue;
      }
      for (final entry in dir.listSync()) {
        if (!entry.path.endsWith('.mobileprovision')) {
          continue;
        }
        final payload = await _profilePayload(entry.path);
        if (payload == null || !payload.contains('<key>ProvisionedDevices</key>') || _isExpired(payload)) {
          continue;
        }
        final applicationIdentifier = _profileApplicationIdentifier(payload);
        if (applicationIdentifier == null ||
            !applicationIdentifier.startsWith(teamPrefix) ||
            !applicationIdentifier.endsWith('.xctrunner')) {
          continue;
        }
        final name = _profileNameFromPayload(payload);
        if (name == null || name.isEmpty) {
          continue;
        }
        return IosProvisioningProfile(
          path: entry.path,
          name: name,
          applicationIdentifier: applicationIdentifier,
        );
      }
    }
    return null;
  }

  Future<String?> _profilePayload(String path) async {
    final result = await _shell.runArgs(
      'security',
      ['cms', '-D', '-i', path],
      throwOnError: false,
    );
    if (result.exitCode != 0) {
      return null;
    }
    return result.outText;
  }

  String? _profileNameFromPayload(String payload) {
    final match = RegExp(
      r'<key>Name</key>\s*<string>([^<]+)</string>',
      multiLine: true,
    ).firstMatch(payload);
    return match?.group(1)?.trim();
  }

  String? _profileApplicationIdentifier(String payload) {
    final match = RegExp(
      r'<key>application-identifier</key>\s*<string>([^<]+)</string>',
      multiLine: true,
    ).firstMatch(payload);
    return match?.group(1)?.trim();
  }

  /// Whether [identity] can sign **non-interactively** right now. `codesign`
  /// needs the signing key's keychain partition list to authorize `apple-tool`;
  /// a key that isn't authorized fails with `errSecInternalComponent` in a
  /// headless session (or pops a GUI prompt). Probes by re-signing a throwaway
  /// copy of a small system binary. Returns true if it can't probe (no false
  /// alarm), so a missing sample binary never reads as "signing broken".
  Future<bool> canSignHeadless(String identity, {String sampleBinary = '/bin/echo'}) async {
    if (!File(sampleBinary).existsSync()) {
      return true;
    }
    final dir = Directory.systemTemp.createTempSync('codesign_probe');
    try {
      final probe = p.join(dir.path, 'probe');
      File(sampleBinary).copySync(probe);
      final result = await _shell.runArgs('codesign', ['--force', '--sign', identity, probe], throwOnError: false);
      return result.exitCode == 0;
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}

/// Whether the decoded profile [payload] has an `ExpirationDate` in the past.
/// An expired profile still matches its bundle id, so treating it as installed
/// made builds fail with "Provisioning profile ... expired" instead of installing
/// the current one (see `MPLATROL_IOS_SIGNING_COMMAND`). A payload without a date counts as valid.
bool _isExpired(String payload) {
  final match = RegExp(r'<key>ExpirationDate</key>\s*<date>([^<]+)</date>').firstMatch(payload);
  final expires = match == null ? null : DateTime.tryParse(match.group(1)!.trim());
  return expires != null && expires.isBefore(DateTime.now().toUtc());
}

class IosProvisioningProfile {
  const IosProvisioningProfile({
    required this.path,
    required this.name,
    required this.applicationIdentifier,
  });

  final String path;
  final String name;
  final String applicationIdentifier;
}
