import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';

/// Wraps [Platform] to enable testing of platform-dependent code.
class PlatformWrapper {
  /// This should only be used to create one single
  ///   instance in the [Dependencies]
  PlatformWrapper.constructGlobalInstance();

  bool get isWindows => Platform.isWindows;
  bool get isMac => Platform.isMacOS;
  bool get isLinux => Platform.isLinux;
  Map<String, String> get environment => Platform.environment;
  Uri get script => Platform.script;

  /// Whether stdin is a terminal someone can answer a prompt on.
  bool get stdinHasTerminal => stdin.hasTerminal;

  /// Whether stdout is a terminal a prompt can be drawn on (false when output goes to a log file).
  bool get stdoutHasTerminal => stdout.hasTerminal;

  /// The first non-loopback IPv4 address a device on the LAN can reach, or null
  /// if none is available. Prefers `en*` interfaces (the Mac's Wi-Fi/Ethernet).
  ///
  /// Enumerates real host interfaces via [NetworkInterface.list], so it is
  /// injected through this wrapper to keep callers deterministic under test.
  // coverage:ignore-start
  Future<String?> localNetworkHost() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      if (!interface.name.startsWith('en')) {
        continue;
      }
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    return null;
  }
  // coverage:ignore-end
}

/// Detects non-interactive (CI) mode from the environment exposed by [PlatformWrapper].
///
/// Declared as an extension so it reads the (mockable) [PlatformWrapper.environment]
/// rather than [Platform.environment] directly.
extension NonInteractiveMode on PlatformWrapper {
  /// Set to `true` by GitHub Actions, GitLab CI (and most other CI providers).
  static const ciEnv = 'CI';

  /// Explicit opt-in for non-interactive runs outside a CI provider.
  static const nonInteractiveEnv = 'MPLATROL_NON_INTERACTIVE';

  /// Whether the CLI must never prompt or open interactive logins (e.g. `aws sso login`).
  bool get isNonInteractive => _isTrue(ciEnv) || _isTrue(nonInteractiveEnv);

  /// The environment variable that enabled non-interactive mode, for log messages.
  String get nonInteractiveReason => _isTrue(nonInteractiveEnv) ? '$nonInteractiveEnv=true' : '$ciEnv=true';

  bool _isTrue(String name) => environment[name]?.trim().toLowerCase() == 'true';
}
