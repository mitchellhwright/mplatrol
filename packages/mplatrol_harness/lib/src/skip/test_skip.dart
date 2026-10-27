import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Prefix of the device-log line `mplatrol` reads for a runtime skip.
const skipMarkerPrefix = 'MPLATROL_TEST_SKIPPED';

final _codePattern = RegExp(r'^[A-Z][A-Z0-9_]{2,}$');

/// Why a journey could not run.
///
/// [code] is stable: reports and triage key on it. The built-in codes cover
/// reasons any app hits; an app adds its own with `SkipCode('MY_CODE', 'meaning')`.
/// A code is upper-case letters, digits and underscores, starting with a letter
/// and at least three characters long, which is what `mplatrol` parses from the
/// device log.
@immutable
class SkipCode {
  /// Creates a skip code; [code] must match `[A-Z][A-Z0-9_]{2,}`.
  const SkipCode(this.code, this.meaning);

  /// The marker code, e.g. `CREDENTIALS_UNAVAILABLE`.
  final String code;

  /// One-sentence meaning for reports and documentation.
  final String meaning;

  /// The runtime credential server gave the test no credentials.
  static const credentialsUnavailable =
      SkipCode('CREDENTIALS_UNAVAILABLE', 'The runtime credential server gave the test no credentials.');

  /// Credentials were missing, or the backend rejected them at sign-in.
  static const credentialsRejected =
      SkipCode('CREDENTIALS_REJECTED', 'Credentials were missing, or the backend rejected them at sign-in.');

  /// The SDK or route the journey needs is not built into this app.
  static const featureNotBuilt =
      SkipCode('FEATURE_NOT_BUILT', 'The SDK or route the journey needs is not built into this app.');

  /// The tenant's configuration does not enable the feature.
  static const featureNotConfigured =
      SkipCode('FEATURE_NOT_CONFIGURED', "The tenant's configuration does not enable the feature.");

  /// The device has no enrolled biometrics.
  static const deviceNoBiometrics = SkipCode('DEVICE_NO_BIOMETRICS', 'The device has no enrolled biometrics.');

  /// The device locale is not the one the journey checks.
  static const deviceLocaleMismatch =
      SkipCode('DEVICE_LOCALE_MISMATCH', 'The device locale is not the one the journey checks.');

  /// The device OS version cannot run the journey.
  static const deviceOsUnsupported = SkipCode('DEVICE_OS_UNSUPPORTED', 'The device OS version cannot run the journey.');

  /// A native SDK the journey needs does not run on a simulator or emulator.
  static const deviceSimulatorUnsupported =
      SkipCode('DEVICE_SIMULATOR_UNSUPPORTED', 'A native SDK the journey needs does not run on a simulator.');

  /// The device could not be put in the starting state the journey needs.
  static const deviceFixtureUnavailable =
      SkipCode('DEVICE_FIXTURE_UNAVAILABLE', 'The device could not be put in the starting state.');

  /// The runner reinstalls the app per test, so app data cannot carry over.
  static const freshInstallPerTest =
      SkipCode('FRESH_INSTALL_PER_TEST', 'The runner reinstalls the app per test; app data cannot carry over.');

  /// A multi-step journey ran without the step that sets it up.
  static const earlierStepMissing =
      SkipCode('EARLIER_STEP_MISSING', 'A multi-step journey ran without the step that sets it up.');

  /// The test user lacks the data the journey needs.
  static const testDataMissing = SkipCode('TEST_DATA_MISSING', 'The test user lacks the data the journey needs.');

  /// Every built-in code, for documentation and report legends.
  static const List<SkipCode> builtIn = [
    credentialsUnavailable,
    credentialsRejected,
    featureNotBuilt,
    featureNotConfigured,
    deviceNoBiometrics,
    deviceLocaleMismatch,
    deviceOsUnsupported,
    deviceSimulatorUnsupported,
    deviceFixtureUnavailable,
    freshInstallPerTest,
    earlierStepMissing,
    testDataMissing,
  ];

  @override
  bool operator ==(Object other) => other is SkipCode && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'SkipCode($code)';
}

/// The skip message: `<CODE> <reason>`, with [reason] collapsed onto one line.
///
/// Throws:
///   ArgumentError: [code] is not a valid marker code, or [reason] is blank;
///     every skip must say why.
String skipMessage(SkipCode code, String reason) {
  if (!_codePattern.hasMatch(code.code)) {
    throw ArgumentError.value(code.code, 'code', 'must match ${_codePattern.pattern}');
  }
  final oneLine = reason.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty) {
    throw ArgumentError.value(reason, 'reason', 'a ${code.code} skip must say why');
  }
  return '${code.code} $oneLine';
}

/// The device-log line `mplatrol` reads for a skip with [code] and [reason]:
/// `MPLATROL_TEST_SKIPPED <CODE> <reason>`.
///
/// Throws:
///   ArgumentError: See [skipMessage].
String skipMarker(SkipCode code, String reason) => '$skipMarkerPrefix ${skipMessage(code, reason)}';

/// Marks the running test NOT RUN with [code] and [reason] and prints the marker.
///
/// The caller returns at once afterwards; a skipped test is never a pass.
///
/// Args:
///   code: Why the test cannot run.
///   reason: Starts with the test's tag or case key, then says what is missing
///     and what would let the test run.
///   log: Receives the marker line; defaults to [print] so it reaches the device log.
void skipTest(SkipCode code, String reason, {void Function(String line) log = print}) {
  log(skipMarker(code, reason));
  markTestSkipped(skipMessage(code, reason));
}
