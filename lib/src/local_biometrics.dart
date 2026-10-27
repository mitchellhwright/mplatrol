import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';

/// The line a biometric journey prints (to the device log) while it waits for a matching face or finger; the local
/// runner answers it with a matching biometric on the emulator or simulator.
const biometricMatchRequestMarker = 'MPLATROL_BIOMETRIC_MATCH_REQUEST';

/// The screen-lock PIN mplatrol sets on a local emulator: Android enrolls a fingerprint only behind a
/// secure screen lock, and the runner unlocks the keyguard with it.
const emulatorScreenLockPin = '1111';

/// Runs one command and returns its result; a failed command returns its exit code, it does not throw.
typedef BiometricCommand = Future<ProcessResultX> Function(String executable, List<String> arguments,
    {required Duration timeout});

/// Starts a long-running process whose stdout is read line by line.
typedef BiometricProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Gives local emulators and simulators an enrolled biometric and answers the biometric journeys'
/// [biometricMatchRequestMarker] with a matching face or finger, so PROJ-TC-12258, PROJ-TC-7590 and
/// PROJ-TC-7724 run on local legs instead of skipping with `DEVICE_NO_BIOMETRICS`.
///
/// iOS simulator: Face ID enrollment is the `com.apple.BiometricKit.enrollmentChanged` notification
/// state (what Simulator > Features > Face ID > Enrolled sets); a match is the
/// `com.apple.BiometricKit_Sim.pearl.match` notification (`fingerTouch.match` on Touch ID models).
///
/// Android emulator: enrollment goes through Settings (`android.settings.FINGERPRINT_ENROLL`) behind the
/// [emulatorScreenLockPin] screen lock, touching the emulated sensor with `adb emu finger touch`; a
/// match is one more touch. Physical devices and LambdaTest are left alone.
class LocalBiometrics {
  /// Creates the helper; [run], [start] and [pause] are injectable for tests.
  LocalBiometrics({
    BiometricCommand? run,
    BiometricProcessStarter? start,
    Future<void> Function(Duration duration)? pause,
    this.enrollTimeout = const Duration(minutes: 3),
  })  : _run = run ?? _shellRun,
        _start = start ?? Process.start,
        _pause = pause ?? Future<void>.delayed;

  /// How long the Android Settings enrollment may take on a loaded emulator.
  final Duration enrollTimeout;

  final BiometricCommand _run;
  final BiometricProcessStarter _start;
  final Future<void> Function(Duration duration) _pause;

  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  static const _timeout = Duration(seconds: 30);
  static const _unlockAttempts = 3;
  static const _enrollmentNotification = 'com.apple.BiometricKit.enrollmentChanged';
  static const _iosMatchNotifications = [
    'com.apple.BiometricKit_Sim.pearl.match',
    'com.apple.BiometricKit_Sim.fingerTouch.match',
  ];

  static Future<ProcessResultX> _shellRun(String executable, List<String> arguments, {required Duration timeout}) =>
      getDep<MplatrolShell>().runArgs(executable, arguments, throwOnError: false, silent: true, timeout: timeout);

  /// Enrolls Face ID on the booted simulator [udid]. Returns whether it is enrolled.
  Future<bool> enrollIosSimulator(String udid) async {
    final set = await _simctl(udid, ['notifyutil', '-s', _enrollmentNotification, '1']);
    final post = await _simctl(udid, ['notifyutil', '-p', _enrollmentNotification]);
    final state = await _simctl(udid, ['notifyutil', '-g', _enrollmentNotification]);
    final enrolled = set.exitCode == 0 && post.exitCode == 0 && state.outText.trim().endsWith(' 1');
    if (enrolled) {
      _logger.info('[biometrics] Face ID enrolled on simulator $udid');
    } else {
      _logger.warn('[biometrics] could not enroll Face ID on simulator $udid (${state.outText.trim()} '
          '${state.errText.trim()}); biometric journeys will skip with DEVICE_NO_BIOMETRICS');
    }
    return enrolled;
  }

  /// Answers [biometricMatchRequestMarker] lines in the simulator's log with a matching face or finger.
  Future<BiometricResponder> respondOnIosSimulator(String udid) => _respond(
        'xcrun',
        [
          'simctl',
          'spawn',
          udid,
          'log',
          'stream',
          '--style',
          'compact',
          '--predicate',
          'eventMessage CONTAINS "$biometricMatchRequestMarker"'
        ],
        () async {
          for (final notification in _iosMatchNotifications) {
            await _simctl(udid, ['notifyutil', '-p', notification]);
          }
        },
      );

  /// Enrolls a fingerprint on the emulator [serial] unless one is enrolled, setting the
  /// [emulatorScreenLockPin] screen lock it needs, and leaves the screen on and unlocked.
  ///
  /// Returns whether a fingerprint is enrolled. An emulator with another screen lock or without a
  /// fingerprint sensor is left as it is.
  Future<bool> enrollAndroidEmulator(String serial) async {
    final enrolled = await _fingerprints(serial);
    if (enrolled == null) {
      _logger.warn('[biometrics] emulator $serial reports no fingerprint sensor; '
          'biometric journeys will skip with DEVICE_NO_BIOMETRICS');
      return false;
    }
    await _keepScreenOn(serial);
    if (enrolled > 0) {
      await unlockAndroid(serial);
      return true;
    }
    if (!await _setScreenLock(serial)) {
      return false;
    }
    final done = await _enrollThroughSettings(serial);
    await _adb(serial, ['shell', 'input', 'keyevent', 'KEYCODE_HOME']);
    if (done) {
      _logger.info('[biometrics] fingerprint enrolled on emulator $serial (screen lock PIN $emulatorScreenLockPin)');
    } else {
      _logger.warn('[biometrics] fingerprint enrollment on emulator $serial did not finish within '
          '${enrollTimeout.inSeconds}s; biometric journeys will skip with DEVICE_NO_BIOMETRICS');
    }
    return done;
  }

  /// Unlocks the emulator's keyguard with [emulatorScreenLockPin] when it shows: keeps the screen on, wakes
  /// it, swipes up to the PIN bouncer and types the PIN as key events (the bouncer ignores `input text`),
  /// up to [_unlockAttempts] times (a loaded emulator misses keys).
  ///
  /// The keyguard comes back after every system server restart ("PIN is required after device restarts"),
  /// so the match responder calls this again while the run lasts.
  Future<void> unlockAndroid(String serial) async {
    if (!await _keyguardShowing(serial)) {
      return;
    }
    for (var attempt = 1; attempt <= _unlockAttempts; attempt++) {
      await _keepScreenOn(serial);
      await _adb(serial, ['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
      await _adb(serial, ['shell', 'input', 'swipe', '540', '2000', '540', '600', '250']);
      await _pause(const Duration(seconds: 3));
      await _adb(serial, [
        'shell',
        'input',
        'keyevent',
        for (final digit in emulatorScreenLockPin.split('')) 'KEYCODE_$digit',
        'KEYCODE_ENTER',
      ]);
      await _pause(const Duration(seconds: 3));
      if (!await _keyguardShowing(serial)) {
        _logger.info('[biometrics] unlocked the keyguard of emulator $serial');
        return;
      }
    }
    _logger.warn('[biometrics] the keyguard of emulator $serial is still locked after entering the mplatrol '
        'PIN $emulatorScreenLockPin $_unlockAttempts times; unlock it by hand');
  }

  /// Answers [biometricMatchRequestMarker] lines in the emulator's log with a sensor touch, and unlocks
  /// the keyguard every [keyguardCheck] while the run lasts.
  Future<BiometricResponder> respondOnAndroidEmulator(String serial,
          {Duration keyguardCheck = const Duration(seconds: 30)}) =>
      _respond(
        'adb',
        ['-s', serial, 'logcat', '-T', '1', '-e', biometricMatchRequestMarker],
        () => _adb(serial, ['emu', 'finger', 'touch', '1']),
        guard: (every: keyguardCheck, check: () => unlockAndroid(serial)),
      );

  /// Keeps the screen on, so the keyguard does not come back between tests: the emulator reports itself on
  /// battery, where `svc power stayon` does not hold (and a maximal screen timeout still sleeps), so
  /// it is reported on AC power first.
  Future<void> _keepScreenOn(String serial) async {
    await _adb(serial, ['shell', 'dumpsys', 'battery', 'set', 'ac', '1']);
    await _adb(serial, ['shell', 'svc', 'power', 'stayon', 'true']);
  }

  Future<bool> _setScreenLock(String serial) async {
    final set = await _adb(serial, ['shell', 'locksettings', 'set-pin', emulatorScreenLockPin]);
    if (set.exitCode == 0 && set.outText.contains('Pin set')) {
      return true;
    }
    final ours = await _adb(serial, ['shell', 'locksettings', 'verify', '--old', emulatorScreenLockPin]);
    if (ours.exitCode == 0 && !ours.outText.toLowerCase().contains('error')) {
      return true;
    }
    _logger.warn('[biometrics] emulator $serial has a screen lock that is not the mplatrol PIN '
        '$emulatorScreenLockPin, so no fingerprint can be enrolled; remove it (Settings > Security) or '
        'recreate the AVD with `mplatrol devices --setup`');
    return false;
  }

  Future<bool> _enrollThroughSettings(String serial) async {
    await _adb(serial, ['shell', 'am', 'start', '-a', 'android.settings.FINGERPRINT_ENROLL']);
    final deadline = DateTime.now().add(enrollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await _pause(const Duration(seconds: 1));
      if ((await _fingerprints(serial) ?? 0) > 0) {
        return true;
      }
      await _enrollmentStep(serial, await _adb(serial, ['exec-out', 'uiautomator', 'dump', '/dev/tty']));
    }
    return false;
  }

  /// One step of the Settings enrollment: the PIN prompt, a consent button, else a sensor touch.
  Future<void> _enrollmentStep(String serial, ProcessResultX dump) async {
    final buttons = dump.exitCode == 0 ? parseEnrollmentButtons(dump.outText) : <EnrollmentButton>[];
    final action = enrollmentAction(buttons);
    switch (action) {
      case EnrollmentPin():
        await _adb(serial, ['shell', 'input', 'text', emulatorScreenLockPin]);
        await _adb(serial, ['shell', 'input', 'keyevent', 'KEYCODE_ENTER']);
      case EnrollmentTap(:final button):
        await _adb(serial, ['shell', 'input', 'tap', '${button.x}', '${button.y}']);
      case EnrollmentTouch():
        await _adb(serial, ['emu', 'finger', 'touch', '1']);
        await _pause(const Duration(milliseconds: 500));
        await _adb(serial, ['emu', 'finger', 'remove', '1']);
    }
  }

  /// The number of enrolled fingerprints, or null when the emulator has no fingerprint sensor.
  Future<int?> _fingerprints(String serial) async {
    final result = await _adb(serial, ['shell', 'dumpsys', 'fingerprint']);
    return result.exitCode == 0 ? enrolledFingerprints(result.outText) : null;
  }

  Future<bool> _keyguardShowing(String serial) async {
    final result = await _adb(serial, ['shell', 'dumpsys', 'window', 'policy']);
    return result.exitCode == 0 && keyguardShowing(result.outText);
  }

  Future<BiometricResponder> _respond(String executable, List<String> logArguments, Future<void> Function() match,
      {({Duration every, Future<void> Function() check})? guard}) async {
    final process = await _start(executable, logArguments);
    final responder = BiometricResponder._(process, match, _logger, guard);
    unawaited(process.stderr.drain<void>());
    return responder;
  }

  Future<ProcessResultX> _adb(String serial, List<String> arguments) =>
      _run('adb', ['-s', serial, ...arguments], timeout: _timeout);

  Future<ProcessResultX> _simctl(String udid, List<String> arguments) =>
      _run('xcrun', ['simctl', 'spawn', udid, ...arguments], timeout: _timeout);
}

/// Sends a match for every [biometricMatchRequestMarker] line of a device log until [stop]ped, and runs
/// its optional guard check periodically, one at a time.
class BiometricResponder {
  BiometricResponder._(this._process, Future<void> Function() match, MplatrolLogger logger,
      ({Duration every, Future<void> Function() check})? guard) {
    if (guard != null) {
      _guard = Timer.periodic(guard.every, (_) {
        _checking ??= guard.check().whenComplete(() => _checking = null);
      });
    }
    _lines = _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      // `log stream` first echoes its predicate ("Filtering the log data using ... <marker>"), not a request.
      if (!line.contains(biometricMatchRequestMarker) ||
          line.startsWith('Filtering the log data') ||
          _matching != null) {
        return;
      }
      matches++;
      _matching = match().whenComplete(() => _matching = null);
      if (matches == 1) {
        logger.info('[biometrics] answered the first biometric match request');
      }
    });
  }

  final Process _process;
  late final StreamSubscription<String> _lines;
  Timer? _guard;
  Future<void>? _matching;
  Future<void>? _checking;

  /// How many match requests were answered.
  int matches = 0;

  /// Stops reading the log and ends its process.
  Future<void> stop() async {
    _guard?.cancel();
    _process.kill();
    await _lines.cancel();
    await _matching;
    await _checking;
  }
}

/// A clickable node of the enrollment screen, from a `uiautomator dump`: its resource id, text and centre.
typedef EnrollmentButton = ({String id, String text, int x, int y});

final _node = RegExp(r'<node\b[^>]*>');
final _attribute = RegExp(r'([\w-]+)="([^"]*)"');
final _bounds = RegExp(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]');

/// The clickable nodes of a `uiautomator dump` [xml] with the centre of their bounds.
List<EnrollmentButton> parseEnrollmentButtons(String xml) {
  final buttons = <EnrollmentButton>[];
  for (final match in _node.allMatches(xml)) {
    final node = {for (final attribute in _attribute.allMatches(match[0]!)) attribute[1]!: attribute[2]!};
    final bounds = _bounds.firstMatch(node['bounds'] ?? '');
    if (node['clickable'] != 'true' || bounds == null) {
      continue;
    }
    buttons.add((
      id: node['resource-id'] ?? '',
      text: (node['text'] ?? '').replaceAll('&amp;', '&'),
      x: ((int.parse(bounds[1]!) + int.parse(bounds[3]!)) / 2).round(),
      y: ((int.parse(bounds[2]!) + int.parse(bounds[4]!)) / 2).round(),
    ));
  }
  return buttons;
}

/// What the Android Settings fingerprint enrollment needs next.
sealed class EnrollmentAction {
  const EnrollmentAction();
}

/// Enter the screen-lock PIN.
class EnrollmentPin extends EnrollmentAction {
  const EnrollmentPin();
}

/// Tap a consent or progress [button].
class EnrollmentTap extends EnrollmentAction {
  const EnrollmentTap(this.button);

  final EnrollmentButton button;
}

/// Touch the emulated sensor.
class EnrollmentTouch extends EnrollmentAction {
  const EnrollmentTouch();
}

const _enrollmentButtons = ['i agree', 'agree', 'more', 'next', 'continue', 'done', 'ok'];

/// The next enrollment step for the clickable [buttons] of the screen: the PIN when it asks for it,
/// then the first consent or progress button (never "Do it later" or "Cancel"), else a sensor touch.
EnrollmentAction enrollmentAction(List<EnrollmentButton> buttons) {
  if (buttons.any((button) => button.id.endsWith(':id/password_entry'))) {
    return const EnrollmentPin();
  }
  for (final text in _enrollmentButtons) {
    for (final button in buttons) {
      if (button.text.trim().toLowerCase() == text) {
        return EnrollmentTap(button);
      }
    }
  }
  return const EnrollmentTouch();
}

/// The number of enrolled fingerprints in `dumpsys fingerprint` [output] (its `"prints"` JSON), or null
/// when the output lists no sensor.
int? enrolledFingerprints(String output) {
  final counts = RegExp(r'"count"\s*:\s*(\d+)').allMatches(output).map((match) => int.parse(match[1]!)).toList();
  if (counts.isEmpty) {
    return null;
  }
  return counts.fold<int>(0, (sum, count) => sum + count);
}

/// Whether `dumpsys window policy` [output] shows the keyguard (`KeyguardServiceDelegate` `showing=true`).
bool keyguardShowing(String output) {
  final delegate = output.indexOf('KeyguardServiceDelegate');
  return delegate >= 0 && RegExp(r'^\s*showing=true', multiLine: true).hasMatch(output.substring(delegate));
}
