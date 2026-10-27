import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_permission_dialog.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements MplatrolLogger {}

ProcessResultX _result({int exitCode = 0, String stdout = ''}) =>
    ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: '');

/// The [androidFocusCommand] output while the Android 16 permission dialog has focus.
const _focus = '''
  mCurrentFocus=Window{9a1 u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity}
  mFocusedApp=ActivityRecord{77 u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity t281}
''';

/// `dumpsys window windows` in the Android 16 emulator format: the dialog window is not full screen, so its
/// views must be offset by its frame (the 1.13.13 watcher tapped them at window-relative points).
const _windows = '''
WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #0 Window{6949af6 u0 ScreenDecorOverlayBottom}:
    mDisplayId=0 rootTaskId=1 mSession=Session{a 1:1000} mClient=android.os.BinderProxy@b
    InsetsSource id=d4090001 type=navigationBars frame=[0,2361][1080,2424] visible=true
    Frames: parent=[0,0][1080,2424] display=[0,0][1080,2424] frame=[0,2228][1080,2424] last=[0,2228][1080,2424]
  Window #1 Window{9a1 u0 com.google.android.permissioncontroller/.ui.GrantPermissionsActivity}:
    mDisplayId=0 rootTaskId=281 mSession=Session{c 4242:u0a10193} mClient=android.os.BinderProxy@d
    Frames: parent=[0,0][1080,2424] display=[0,0][1080,2424] frame=[28,1040][1052,1900] last=[28,1040][1052,1900]
  Window #2 Window{7978b7e u0 com.demo/com.demo.MainActivity}:
    Frames: parent=[0,0][1080,2424] display=[0,0][1080,2424] frame=[0,0][1080,2424] last=[0,0][1080,2424]
''';

/// `dumpsys activity top` with the dialog between two other activities, ids only, bounds relative to each
/// parent.
const _activityTop = '''
TASK 10 id=1
  ACTIVITY com.google.android.apps.nexuslauncher/.NexusLauncherActivity d28c4c pid=1075 userId=0
    View Hierarchy:
      com.android.internal.policy.DecorView{805f84f V.E...... R.....I. 0,0-1080,2424}[NexusLauncherActivity]
        android.widget.Button{1 VFED..C.. ........ 0,0-100,100 #7f0a0250 app:id/permission_allow_button}
TASK 11 id=281
  ACTIVITY com.google.android.permissioncontroller/.ui.GrantPermissionsActivity 5d1 pid=4242 userId=0
    View Hierarchy:
      com.android.internal.policy.DecorView{11 V.E...... R....... 0,0-1024,860}[GrantPermissionsActivity]
        android.widget.FrameLayout{13 V.E...... ........ 0,0-1024,860 #1020002 android:id/content}
          android.widget.LinearLayout{14 V.E...... ........ 0,400-1024,860 #7f0a0100 app:id/button_group}
            android.widget.Button{15 VFED..C.. ........ 48,40-976,180 #7f0a0250 app:id/permission_allow_button}
            android.widget.Button{16 GFED..C.. ........ 48,180-976,320 #7f0a0252 app:id/permission_allow_one_time_button}
            android.widget.Button{17 VFED..C.. ........ 48,320-976,460 #7f0a0251 app:id/permission_deny_button}
TASK 12 id=276
  ACTIVITY com.demo/.MainActivity 7a1b442 pid=4906 userId=0
    View Hierarchy:
      com.android.internal.policy.DecorView{21 V.E...... ........ 0,0-1080,2424}[MainActivity]
        android.widget.Button{22 VFED..C.. ........ 0,0-50,50 #7f0a0251 app:id/permission_deny_button}
''';

const _allow = 'com.android.permissioncontroller:id/permission_allow_button';
const _deny = 'com.android.permissioncontroller:id/permission_deny_button';

void main() {
  group('parsing', () {
    test('finds the permission window origin in the Frames line of its own window block', () {
      expect(permissionWindowOrigin(_windows), (x: 28, y: 1040));
      expect(permissionWindowOrigin(_windows.replaceAll('permissioncontroller', 'demo2')), isNull);
      expect(
          permissionWindowOrigin('  Window #1 Window{9a1 u0 com.google.android.permissioncontroller/X}:\n'
              '    mDisplayId=0\n  Window #2 Window{b u0 com.demo/Main}:\n'
              '    Frames: parent=[0,0][1080,2424] display=[0,0][1080,2424] frame=[0,0][1080,2424]\n'),
          isNull,
          reason: "another window's frame is never used for the dialog");
    });

    test('places the dialog views on the screen, skips hidden views and stops at the next activity', () {
      expect(parseViewHierarchyButtons(_activityTop, left: 28, top: 1040), [
        (id: 'com.android.permissioncontroller:id/content', x: 540, y: 1470),
        (id: 'com.android.permissioncontroller:id/button_group', x: 540, y: 1670),
        (id: _allow, x: 540, y: 1550),
        (id: _deny, x: 540, y: 1830),
      ]);
      expect(parseViewHierarchyButtons('TASK 1\n  ACTIVITY com.demo/.Main', left: 0, top: 0), isEmpty);
    });

    test('prefers allow ids in order and never picks deny for allow', () {
      AndroidDialogButton button(String id) => (id: id, x: 1, y: 2);
      final foreground = button('com.android.permissioncontroller:id/permission_allow_foreground_only_button');
      final oneTime = button('com.android.permissioncontroller:id/permission_allow_one_time_button');
      expect(pickPermissionButton([oneTime, foreground], allow: true), foreground);
      expect(pickPermissionButton([button(_deny)], allow: true), isNull);
      expect(pickPermissionButton([button(_allow), button(_deny)], allow: false), button(_deny));
    });

    test('reads the last watcher marker the test printed', () {
      expect(watcherDenyRequest(''), isNull);
      expect(
          watcherDenyRequest('I flutter: MPLATROL_PERMISSION_WATCHER=deny:post_notifications'), 'POST_NOTIFICATIONS');
      expect(watcherDenyRequest('MPLATROL_PERMISSION_WATCHER=deny:all'), 'ALL');
      expect(
          watcherDenyRequest('MPLATROL_PERMISSION_WATCHER=deny:POST_NOTIFICATIONS\nMPLATROL_PERMISSION_WATCHER=allow'),
          isNull);
    });

    test('a permission dialog is focused only when the permission controller has focus', () {
      expect(permissionDialogFocused(_focus), isTrue);
      expect(permissionDialogFocused('mFocusedApp=ActivityRecord{com.android.permissioncontroller/X}'), isTrue);
      expect(permissionDialogFocused('mCurrentFocus=Window{a b com.demo/Main}'), isFalse);
    });
  });

  group('AndroidPermissionWatcher', () {
    late _MockLogger logger;
    late List<List<String>> calls;
    late Map<String, ProcessResultX> answers;

    setUp(() {
      logger = _MockLogger();
      calls = [];
      answers = {
        'shell dumpsys window windows': _result(stdout: _windows),
        'shell dumpsys activity top': _result(stdout: _activityTop),
        'shell getprop ro.build.version.release': _result(stdout: '16\n'),
        'logcat -d -e MPLATROL_PERMISSION_WATCHER=': _result(exitCode: 1),
      };
    });

    AndroidPermissionWatcher watcher() => AndroidPermissionWatcher(
          deviceId: 'emulator-5554',
          adb: (arguments, {required timeout, cancelOn}) async {
            calls.add(arguments);
            return answers[arguments.join(' ')] ?? _result();
          },
          logger: logger,
        );

    Iterable<List<String>> taps() => calls.where((call) => call.contains('tap'));

    // Regression 2026-10-15 : the watcher tapped 512,495 (window-relative) 474 times across rounds and
    // never answered a dialog; its uiautomator dumps crashed the next test's instrumentation.
    test('taps allow on the screen position of the dialog window, never through uiautomator', () async {
      final subject = watcher();

      expect(await subject.answer(_focus), isTrue);
      expect(await subject.answer(_focus), isTrue);

      expect(taps().first, ['shell', 'input', 'tap', '540', '1550']);
      expect(calls.where((call) => call.contains('uiautomator')), isEmpty);
      expect(calls.where((call) => call.contains('getprop')), hasLength(1));
      verify(() => logger.info('[android-permissions] tapped $_allow at 540,1550 on Android 16')).called(2);
    });

    test('denies every dialog when the test asked to deny all', () async {
      answers['logcat -d -e MPLATROL_PERMISSION_WATCHER='] =
          _result(stdout: 'I flutter: MPLATROL_PERMISSION_WATCHER=deny:all\n');

      expect(await watcher().answer(_focus), isTrue);

      expect(calls.last, ['shell', 'input', 'tap', '540', '1830']);
      verify(() => logger.info(any(that: allOf(contains(_deny), contains('as the test asked'))))).called(1);
    });

    test('leaves every dialog to the test that asked to deny one permission', () async {
      answers['logcat -d -e MPLATROL_PERMISSION_WATCHER='] =
          _result(stdout: 'I flutter: MPLATROL_PERMISSION_WATCHER=deny:POST_NOTIFICATIONS\n');
      final subject = watcher();

      for (var poll = 0; poll < 4; poll++) {
        expect(await subject.answer(_focus), isFalse);
      }

      expect(taps(), isEmpty);
      expect(calls.where((call) => call.contains('dumpsys')), isEmpty);
      expect(subject.notes, isEmpty);
    });

    test('never taps without the dialog window frame, and reports a dialog that stays unanswered once', () async {
      answers['shell dumpsys window windows'] = _result(stdout: _windows.replaceAll('permissioncontroller', 'x'));
      final subject = watcher();

      for (var poll = 0; poll < 5; poll++) {
        expect(await subject.answer(_focus), isFalse);
      }

      expect(taps(), isEmpty);
      expect(calls.where((call) => call.contains('top')), isEmpty);
      const note = '[android-permissions] PERMISSION_DIALOG_UNANSWERED: a permission dialog stayed focused on '
          'emulator-5554 (Android 16) for 3 polls but shows no allow button mplatrol can place; not tapping.';
      expect(subject.notes, [note]);
      verify(() => logger.warn(any(that: contains('PERMISSION_DIALOG_UNANSWERED')))).called(1);
    });

    test('does not report a dialog that closes before it stays unanswered', () async {
      answers['shell dumpsys activity top'] = _result(exitCode: 1);
      final subject = watcher();

      await subject.answer(_focus);
      await subject.answer(_focus);
      await subject.answer('  mCurrentFocus=Window{a u0 com.demo/Main}\n');
      await subject.answer(_focus);
      await subject.answer(_focus);

      expect(subject.notes, isEmpty);
      verifyNever(() => logger.warn(any()));
    });

    test('reports a focused not-responding dialog once per episode without tapping or dumping', () async {
      const anr = '  mCurrentFocus=Window{cef8770 u0 Application Not Responding: com.android.systemui}\n';
      final subject = watcher();

      expect(await subject.answer(anr), isFalse);
      expect(await subject.answer(anr), isFalse);
      await subject.answer('  mCurrentFocus=Window{a u0 com.demo/Main}\n');
      await subject.answer(anr);

      expect(calls, isEmpty);
      expect(subject.notes, hasLength(2));
      expect(subject.notes.first, contains('SYSTEM_NOT_RESPONDING: a "not responding" system dialog is focused'));
    });

    test('does nothing without a focused permission dialog, and reports a failed tap as not answered', () async {
      final subject = watcher();
      expect(await subject.answer('mCurrentFocus=Window{com.demo/Main}'), isFalse);
      expect(calls, isEmpty);

      answers['shell input tap 540 1550'] = _result(exitCode: 1);
      expect(await subject.answer(_focus), isFalse);
      verifyNever(() => logger.info(any()));
    });
  });
}
