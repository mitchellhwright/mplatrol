import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/local_biometrics.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

class _MockShell extends Mock implements MplatrolShell {}

ProcessResultX _result({int exitCode = 0, String stdout = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: '');

const _noPrints = '{"service":"FingerprintProvider/default","prints":[{"id":0,"count":0,"accept":0}]}';
const _onePrint = '{"service":"FingerprintProvider/default","prints":[{"id":0,"count":1,"accept":0}]}';
const _locked = '    KeyguardServiceDelegate\n      showing=true\n      deviceHasKeyguard=true\n';
const _unlocked = '    KeyguardServiceDelegate\n      showing=false\n';

String _dump(List<String> nodes) => '<hierarchy>${nodes.join()}</hierarchy>';

String _node(String text, {String id = '', String bounds = '[0,0][100,100]'}) =>
    '<node text="$text" resource-id="$id" clickable="true" bounds="$bounds" />';

/// A scripted device: answers each command from [answer] and records what ran.
class _Device {
  _Device(this.answer);

  final ProcessResultX Function(List<String> command) answer;
  final calls = <List<String>>[];

  Future<ProcessResultX> run(String executable, List<String> arguments, {required Duration timeout}) async {
    final command = [executable, ...arguments];
    calls.add(command);
    return answer(command);
  }

  bool ran(String joined) => calls.any((call) => call.join(' ').contains(joined));
}

class _FakeProcess implements Process {
  final _out = StreamController<List<int>>();
  bool killed = false;

  void emit(String line) => _out.add(utf8.encode('$line\n'));

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    unawaited(_out.close());
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _MockLogger logger;

  setUp(() {
    logger = _MockLogger();
    GetIt.I.registerSingleton<MplatrolLogger>(logger);
  });

  tearDown(GetIt.I.reset);

  LocalBiometrics biometrics(_Device device, {_FakeProcess? process, List<List<String>>? started}) => LocalBiometrics(
        run: device.run,
        start: (executable, arguments) async {
          started?.add([executable, ...arguments]);
          return process ?? _FakeProcess();
        },
        pause: (_) async {},
        enrollTimeout: const Duration(seconds: 2),
      );

  group('parsing', () {
    test('counts enrolled fingerprints and reports a missing sensor as null', () {
      expect(enrolledFingerprints(_noPrints), 0);
      expect(enrolledFingerprints(_onePrint), 1);
      expect(enrolledFingerprints('Fps state: 0'), isNull);
    });

    test('reads the keyguard state of the KeyguardServiceDelegate section only', () {
      expect(keyguardShowing(_locked), isTrue);
      expect(keyguardShowing(_unlocked), isFalse);
      expect(keyguardShowing('showing=true'), isFalse);
    });

    test('reads the clickable nodes of a uiautomator dump with their centres', () {
      const dump = [
        '<hierarchy>',
        '<node text="A &amp; B" resource-id="x:id/a" clickable="true" bounds="[0,0][100,50]" />',
        '<node text="label" clickable="false" bounds="[0,0][1,1]" />',
        '<node text="no bounds" clickable="true" />',
        '</hierarchy>',
      ];
      expect(parseEnrollmentButtons(dump.join()), [(id: 'x:id/a', text: 'A & B', x: 50, y: 25)]);
    });

    test('enters the PIN, taps consent buttons in order and otherwise touches the sensor', () {
      const pin = (id: 'com.android.settings:id/password_entry', text: '', x: 1, y: 1);
      const later = (id: '', text: 'DO IT LATER', x: 1, y: 1);
      const more = (id: '', text: 'MORE', x: 9, y: 9);
      const agree = (id: '', text: 'I agree', x: 5, y: 5);
      expect(enrollmentAction([pin]), isA<EnrollmentPin>());
      expect((enrollmentAction([later, more, agree]) as EnrollmentTap).button, agree);
      expect((enrollmentAction([later, more]) as EnrollmentTap).button, more);
      expect(enrollmentAction([later]), isA<EnrollmentTouch>());
    });
  });

  group('iOS simulator', () {
    test('enrolls Face ID through the enrollment notification', () async {
      final device = _Device((command) =>
          command.contains('-g') ? _result(stdout: 'com.apple.BiometricKit.enrollmentChanged 1') : _result());
      expect(await biometrics(device).enrollIosSimulator('U1'), isTrue);
      expect(device.ran('simctl spawn U1 notifyutil -s com.apple.BiometricKit.enrollmentChanged 1'), isTrue);
      expect(device.ran('simctl spawn U1 notifyutil -p com.apple.BiometricKit.enrollmentChanged'), isTrue);
      verify(() => logger.info(any(that: contains('Face ID enrolled')))).called(1);
    });

    test('warns when the enrollment state does not stick', () async {
      final device = _Device((command) =>
          command.contains('-g') ? _result(stdout: 'com.apple.BiometricKit.enrollmentChanged 0') : _result());
      expect(await biometrics(device).enrollIosSimulator('U1'), isFalse);
      verify(() => logger.warn(any(that: contains('DEVICE_NO_BIOMETRICS')))).called(1);
    });

    test('answers each match request line with Face ID and Touch ID matches, once at a time', () async {
      final process = _FakeProcess();
      final started = <List<String>>[];
      final device = _Device((_) => _result());
      final responder = await biometrics(device, process: process, started: started).respondOnIosSimulator('U1');
      expect(started.single, containsAllInOrder(['xcrun', 'simctl', 'spawn', 'U1', 'log', 'stream']));
      process
        ..emit('Filtering the log data using "eventMessage CONTAINS "$biometricMatchRequestMarker""')
        ..emit('Runner: flutter: unrelated')
        ..emit('Runner: flutter: $biometricMatchRequestMarker');
      await pumpEventQueue();
      process.emit('Runner: flutter: $biometricMatchRequestMarker');
      await pumpEventQueue();
      await responder.stop();
      expect(responder.matches, 2);
      expect(process.killed, isTrue);
      expect(device.calls.where((call) => call.join(' ').contains('pearl.match')), hasLength(2));
      expect(device.ran('fingerTouch.match'), isTrue);
      verify(() => logger.info(any(that: contains('first biometric match')))).called(1);
    });

    test('ignores a request while the previous match still runs', () async {
      final process = _FakeProcess();
      final gate = Completer<void>();
      var matches = 0;
      final responder = await LocalBiometrics(
        run: (executable, arguments, {required timeout}) async {
          matches++;
          await gate.future;
          return _result();
        },
        start: (_, __) async => process,
      ).respondOnIosSimulator('U1');
      process
        ..emit(biometricMatchRequestMarker)
        ..emit(biometricMatchRequestMarker);
      await pumpEventQueue();
      gate.complete();
      await responder.stop();
      expect(responder.matches, 1);
      expect(matches, 2);
    });
  });

  group('Android emulator', () {
    test('keeps an enrolled emulator, keeps its screen on and unlocks its keyguard', () async {
      var locked = true;
      final device = _Device((command) {
        final joined = command.join(' ');
        if (joined.contains('dumpsys fingerprint')) {
          return _result(stdout: _onePrint);
        }
        if (joined.contains('dumpsys window policy')) {
          return _result(stdout: locked ? _locked : _unlocked);
        }
        if (joined.contains('KEYCODE_1 KEYCODE_ENTER')) {
          locked = false;
        }
        return _result();
      });
      expect(await biometrics(device).enrollAndroidEmulator('emulator-5580'), isTrue);
      expect(device.ran('-s emulator-5580 shell dumpsys battery set ac 1'), isTrue);
      expect(device.ran('-s emulator-5580 shell svc power stayon true'), isTrue);
      expect(device.ran('shell input keyevent KEYCODE_1 KEYCODE_1 KEYCODE_1 KEYCODE_1 KEYCODE_ENTER'), isTrue);
      expect(device.ran('locksettings'), isFalse);
      verify(() => logger.info(any(that: contains('unlocked the keyguard')))).called(1);
    });

    test('warns when the keyguard stays locked after the PIN', () async {
      final device = _Device(
          (command) => command.join(' ').contains('dumpsys window policy') ? _result(stdout: _locked) : _result());
      await biometrics(device).unlockAndroid('emulator-5580');
      verify(() => logger.warn(any(that: contains('still locked')))).called(1);
    });

    test('leaves an emulator without a fingerprint sensor alone', () async {
      final device =
          _Device((command) => command.join(' ').contains('dumpsys fingerprint') ? _result(exitCode: 1) : _result());
      expect(await biometrics(device).enrollAndroidEmulator('emulator-5580'), isFalse);
      expect(device.ran('stayon'), isFalse);
      verify(() => logger.warn(any(that: contains('no fingerprint sensor')))).called(1);
    });

    test('does not enroll behind a screen lock it does not know', () async {
      final device = _Device((command) {
        final joined = command.join(' ');
        if (joined.contains('dumpsys fingerprint')) {
          return _result(stdout: _noPrints);
        }
        if (joined.contains('locksettings')) {
          return _result(exitCode: 255, stdout: 'Error while executing command');
        }
        return _result();
      });
      expect(await biometrics(device).enrollAndroidEmulator('emulator-5580'), isFalse);
      expect(device.ran('FINGERPRINT_ENROLL'), isFalse);
      verify(() => logger.warn(any(that: contains('not the mplatrol PIN')))).called(1);
    });

    test('enrolls through Settings: PIN, consent, sensor touches, then home', () async {
      var touches = 0;
      var screen = 'pin';
      final device = _Device((command) {
        final joined = command.join(' ');
        if (joined.contains('dumpsys fingerprint')) {
          return _result(stdout: touches >= 2 ? _onePrint : _noPrints);
        }
        if (joined.contains('locksettings set-pin')) {
          return _result(stdout: "Pin set to '1111'");
        }
        if (joined.contains('uiautomator dump')) {
          return _result(
              stdout: switch (screen) {
            'pin' => _dump([_node('', id: 'com.android.settings:id/password_entry')]),
            'consent' => _dump([_node('DO IT LATER'), _node('I AGREE', bounds: '[800,2200][1000,2300]')]),
            _ => _dump([_node('DO IT LATER')]),
          });
        }
        if (joined.contains('keyevent KEYCODE_ENTER')) {
          screen = 'consent';
        }
        if (joined.contains('input tap 900 2250')) {
          screen = 'sensor';
        }
        if (joined.contains('emu finger touch 1')) {
          touches++;
        }
        return _result();
      });
      expect(await biometrics(device).enrollAndroidEmulator('emulator-5580'), isTrue);
      expect(device.ran('am start -a android.settings.FINGERPRINT_ENROLL'), isTrue);
      expect(device.ran('emu finger remove 1'), isTrue);
      expect(device.calls.last.join(' '), contains('keyevent KEYCODE_HOME'));
      verify(() => logger.info(any(that: contains('fingerprint enrolled')))).called(1);
    });

    test('accepts its own earlier PIN and reports an enrollment that does not finish in time', () async {
      final device = _Device((command) {
        final joined = command.join(' ');
        if (joined.contains('dumpsys fingerprint')) {
          return _result(stdout: _noPrints);
        }
        if (joined.contains('locksettings set-pin')) {
          return _result(exitCode: 255, stdout: 'Old password provided is incorrect');
        }
        if (joined.contains('uiautomator dump')) {
          return _result(exitCode: 1);
        }
        return _result();
      });
      expect(await biometrics(device).enrollAndroidEmulator('emulator-5580'), isFalse);
      expect(device.ran('locksettings verify --old $emulatorScreenLockPin'), isTrue);
      expect(device.ran('emu finger touch 1'), isTrue);
      verify(() => logger.warn(any(that: contains('did not finish')))).called(1);
    });

    test('answers match requests in logcat with a sensor touch', () async {
      final process = _FakeProcess();
      final started = <List<String>>[];
      final device = _Device((_) => _result());
      final responder =
          await biometrics(device, process: process, started: started).respondOnAndroidEmulator('emulator-5580');
      expect(started.single, ['adb', '-s', 'emulator-5580', 'logcat', '-T', '1', '-e', biometricMatchRequestMarker]);
      process.emit('I flutter : $biometricMatchRequestMarker');
      await pumpEventQueue();
      await responder.stop();
      expect(device.calls.single, ['adb', '-s', 'emulator-5580', 'emu', 'finger', 'touch', '1']);
    });

    test('unlocks the keyguard periodically while the responder runs', () async {
      var checks = 0;
      final device = _Device((command) {
        if (command.join(' ').contains('dumpsys window policy')) {
          checks++;
        }
        return _result(stdout: _unlocked);
      });
      final responder = await biometrics(device)
          .respondOnAndroidEmulator('emulator-5580', keyguardCheck: const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await responder.stop();
      expect(checks, greaterThan(1));
      final after = checks;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(checks, after);
    });
  });

  test('runs commands through the injected shell by default', () async {
    final shell = _MockShell();
    GetIt.I.registerSingleton<MplatrolShell>(shell);
    when(() => shell.runArgs(any(), any(),
            throwOnError: any(named: 'throwOnError'), silent: any(named: 'silent'), timeout: any(named: 'timeout')))
        .thenAnswer((_) async => _result(stdout: 'com.apple.BiometricKit.enrollmentChanged 1'));
    expect(await LocalBiometrics().enrollIosSimulator('U1'), isTrue);
    verify(() => shell.runArgs('xcrun', any(that: contains('notifyutil')),
        throwOnError: false, silent: true, timeout: any(named: 'timeout'))).called(3);
  });
}
