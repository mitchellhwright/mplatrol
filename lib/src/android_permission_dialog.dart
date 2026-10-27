import 'package:mplatrol/src/android_screen_recorder.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/test_lessons.dart';

/// The device-log marker an app test prints to steer the permission watcher: `<marker>=deny:all` makes it tap
/// every dialog's deny button instead of allow, `<marker>=deny:<PERMISSION>` (e.g. `deny:POST_NOTIFICATIONS`)
/// makes it leave every dialog to the test (it cannot tell which permission a dialog asks for), and
/// `<marker>=allow` restores the default. The last marker in the device log wins.
const androidPermissionWatcherMarker = 'MPLATROL_PERMISSION_WATCHER';

/// The adb shell command whose output [AndroidPermissionWatcher.answer] reads: only the focus lines of
/// `dumpsys window displays`, filtered on the device, so the window manager lock is held as briefly as possible.
const androidFocusCommand = 'dumpsys window displays | grep -E "mCurrentFocus|mFocusedApp"';

/// A button of the focused window, placed on the screen.
typedef AndroidDialogButton = ({String id, int x, int y});

const _allowIds = [
  'com.android.permissioncontroller:id/permission_allow_button',
  'com.android.permissioncontroller:id/permission_allow_foreground_only_button',
  'com.android.permissioncontroller:id/permission_allow_one_time_button',
];
const _denyIds = [
  'com.android.permissioncontroller:id/permission_deny_button',
  'com.android.permissioncontroller:id/permission_deny_and_dont_ask_again_button',
];

/// Answers Android runtime permission dialogs during a local Patrol run by tapping the dialog's own button,
/// found by resource id in the permission controller's `dumpsys activity top` view hierarchy and placed on the
/// screen by its window's frame from `dumpsys window windows`; never a fixed point of the screen (a fixed point
/// landed on "Don't allow" on Android 16, regression r8).
///
/// It never runs `uiautomator dump`: Patrol's instrumentation holds the device's only UiAutomation connection,
/// so the dump always fails ("UiAutomationService already registered", a crashing process per poll), and when
/// it slips in while the next test's instrumentation connects, that instrumentation crashes ("Cannot call
/// disconnect() while connecting UiAutomation").
///
/// It taps allow (`permission_allow_button`, then the foreground-only and one-time buttons) unless the test
/// asked for a denial with [androidPermissionWatcherMarker]. A dialog that stays focused without a button it
/// can place for [unansweredPolls] polls in a row is left alone and logged once with
/// `PERMISSION_DIALOG_UNANSWERED`; a dialog that is only closing is not reported.
class AndroidPermissionWatcher {
  /// Creates a watcher for [deviceId] that runs adb through [adb].
  AndroidPermissionWatcher({
    required this.deviceId,
    required AndroidAdbCall adb,
    required MplatrolLogger logger,
    this.unansweredPolls = 3,
  })  : _adb = adb,
        _logger = logger;

  /// The adb serial of the device.
  final String deviceId;

  /// How many polls in a row a dialog must stay focused without a known button before it is reported.
  final int unansweredPolls;

  final AndroidAdbCall _adb;
  final MplatrolLogger _logger;
  String? _androidVersion;
  var _unansweredInARow = 0;
  var _reportedUnanswered = false;
  var _reportedNotResponding = false;
  final _notes = <String>[];

  /// The `PERMISSION_DIALOG_UNANSWERED` and `SYSTEM_NOT_RESPONDING` lines this watcher logged, as lesson
  /// evidence.
  List<String> get notes => List.unmodifiable(_notes);

  static const _timeout = Duration(seconds: 5);

  /// Answers the permission dialog when [focus] (the [androidFocusCommand] output) shows one focused.
  /// Returns whether it tapped a button.
  Future<bool> answer(String focus) async {
    _noteNotResponding(focus);
    if (!permissionDialogFocused(focus)) {
      _unansweredInARow = 0;
      _reportedUnanswered = false;
      return false;
    }
    final request = await _denyRequest();
    if (request != null && request != 'ALL') {
      return false;
    }
    final deny = request == 'ALL';
    final button = pickPermissionButton(await _dialogButtons(), allow: !deny);
    final version = await _version();
    if (button == null) {
      _noteUnanswered(version, deny: deny);
      return false;
    }
    final tap = await _adb(['shell', 'input', 'tap', '${button.x}', '${button.y}'], timeout: _timeout);
    if (tap.exitCode != 0) {
      return false;
    }
    _unansweredInARow = 0;
    _reportedUnanswered = false;
    _logger.info('[android-permissions] tapped ${button.id} at ${button.x},${button.y} on Android $version'
        '${deny ? ' as the test asked' : ''}');
    return true;
  }

  void _noteUnanswered(String version, {required bool deny}) {
    _unansweredInARow++;
    if (_reportedUnanswered || _unansweredInARow < unansweredPolls) {
      return;
    }
    _reportedUnanswered = true;
    final note = '[android-permissions] $permissionDialogUnansweredMarker: a permission dialog stayed focused on '
        '$deviceId (Android $version) for $_unansweredInARow polls but shows no ${deny ? 'deny' : 'allow'} '
        'button mplatrol can place; not tapping.';
    _logger.warn(note);
    _notes.add(note);
  }

  /// Logs once per episode a focused "`<app>` isn't responding" system dialog. It is not tapped: without
  /// `uiautomator dump` (see the class docs) its Wait button cannot be found by element. On Android 16
  /// emulators it means System UI or the system server is hanging under load.
  void _noteNotResponding(String focus) {
    if (!systemNotRespondingFocused(focus)) {
      _reportedNotResponding = false;
      return;
    }
    if (_reportedNotResponding) {
      return;
    }
    _reportedNotResponding = true;
    final note = '[android-permissions] $systemNotRespondingMarker: a "not responding" system dialog is focused '
        'on $deviceId; the emulator is overloaded or hanging. Cold-boot it (mplatrol devices --setup) and run '
        'fewer lanes at once.';
    _logger.warn(note);
    _notes.add(note);
  }

  /// The permission dialog's buttons from `dumpsys activity top`, placed on the screen by the permission
  /// window's frame; none when the frame is not found, so nothing is tapped at window-relative coordinates.
  Future<List<AndroidDialogButton>> _dialogButtons() async {
    final windows = await _adb(['shell', 'dumpsys', 'window', 'windows'], timeout: _timeout);
    final origin = windows.exitCode == 0 ? permissionWindowOrigin(windows.outText) : null;
    if (origin == null) {
      return const [];
    }
    final top = await _adb(['shell', 'dumpsys', 'activity', 'top'], timeout: _timeout);
    return top.exitCode == 0 ? parseViewHierarchyButtons(top.outText, left: origin.x, top: origin.y) : const [];
  }

  Future<String> _version() async {
    final cached = _androidVersion;
    if (cached != null) {
      return cached;
    }
    final result = await _adb(['shell', 'getprop', 'ro.build.version.release'], timeout: _timeout);
    final version = result.exitCode == 0 ? result.outText.trim() : '';
    return _androidVersion = version.isEmpty ? 'unknown' : version;
  }

  /// The permission the test asked the watcher to deny (`ALL` for every one), from the last
  /// [androidPermissionWatcherMarker] in the device log; null when it asked for none or for `allow`.
  Future<String?> _denyRequest() async {
    final log = await _adb(['logcat', '-d', '-e', '$androidPermissionWatcherMarker='], timeout: _timeout);
    return log.exitCode == 0 ? watcherDenyRequest(log.outText) : null;
  }
}

/// Whether [focus] shows an Android "`<app>` isn't responding" (ANR) dialog focused.
bool systemNotRespondingFocused(String focus) =>
    (RegExp('mCurrentFocus=([^\n]+)').firstMatch(focus)?.group(1) ?? '').contains('Application Not Responding');

/// Whether [focus] (`dumpsys window` focus lines) shows the permission controller focused.
bool permissionDialogFocused(String focus) {
  final focusedWindow = RegExp('mCurrentFocus=([^\n]+)', caseSensitive: false).firstMatch(focus)?.group(1);
  final focusedApp = RegExp('mFocusedApp=([^\n]+)', caseSensitive: false).firstMatch(focus)?.group(1);
  return '${focusedWindow ?? ''}\n${focusedApp ?? ''}'.toLowerCase().contains('permissioncontroller');
}

final _windowHeader = RegExp(r'^\s*Window #\d+ Window\{[^}\n]*\}:', multiLine: true);
final _frame = RegExp(r'Frames:[^\n]*?\sframe=\[(-?\d+),(-?\d+)\]');

/// The screen position of the permission controller window's top-left corner, from the `Frames:` line of its
/// block in `dumpsys window windows` [output] (Android 12+); null when no such window or frame is listed.
({int x, int y})? permissionWindowOrigin(String output) {
  final headers = _windowHeader.allMatches(output).toList();
  for (var index = 0; index < headers.length; index++) {
    if (!headers[index][0]!.contains('permissioncontroller')) {
      continue;
    }
    final end = index + 1 < headers.length ? headers[index + 1].start : output.length;
    final frame = _frame.firstMatch(output.substring(headers[index].end, end));
    if (frame != null) {
      return (x: int.parse(frame[1]!), y: int.parse(frame[2]!));
    }
  }
  return null;
}

final _viewLine = RegExp(r'^(\s*)\S+\{\S+ (\S)\S* \S+ (-?\d+),(-?\d+)-(-?\d+),(-?\d+)(?: #[0-9a-f]+ (\S+))?\}');
final _activityLine = RegExp(r'^\s*ACTIVITY ', multiLine: true);

/// The visible views with an id in the permission controller's `View Hierarchy` of a `dumpsys activity
/// top` [output], placed on screen: each view's bounds are relative to its parent, and the window's
/// content starts at [left],[top]. Views of activities listed after it are not read.
List<AndroidDialogButton> parseViewHierarchyButtons(String output, {required int left, required int top}) {
  final start = output.indexOf(RegExp('ACTIVITY com.(?:google.)?android.permissioncontroller/'));
  if (start < 0) {
    return const [];
  }
  final next = _activityLine.allMatches(output, start + 1).firstOrNull;
  final buttons = <AndroidDialogButton>[];
  final parents = <({int indent, int x, int y})>[];
  for (final line in output.substring(start, next?.start ?? output.length).split('\n')) {
    final view = _viewLine.firstMatch(line);
    if (view == null) {
      continue;
    }
    final indent = view[1]!.length;
    while (parents.isNotEmpty && parents.last.indent >= indent) {
      parents.removeLast();
    }
    final x = (parents.isEmpty ? left : parents.last.x) + int.parse(view[3]!);
    final y = (parents.isEmpty ? top : parents.last.y) + int.parse(view[4]!);
    parents.add((indent: indent, x: x, y: y));
    final id = view[7];
    if (id != null && view[2] == 'V') {
      final width = int.parse(view[5]!) - int.parse(view[3]!);
      final height = int.parse(view[6]!) - int.parse(view[4]!);
      buttons.add((
        id: 'com.android.permissioncontroller:${id.substring(id.indexOf(':') + 1)}',
        x: x + width ~/ 2,
        y: y + height ~/ 2,
      ));
    }
  }
  return buttons;
}

/// The button to tap among [buttons]: the first allow (or, with [allow] false, deny) resource id in order of
/// preference; null when none matches.
AndroidDialogButton? pickPermissionButton(List<AndroidDialogButton> buttons, {required bool allow}) {
  for (final id in allow ? _allowIds : _denyIds) {
    for (final button in buttons) {
      if (button.id == id) {
        return button;
      }
    }
  }
  return null;
}

/// The permission the last [androidPermissionWatcherMarker] in [log] asks to deny (`ALL` for every one), or
/// null when there is none or it asks to `allow`.
String? watcherDenyRequest(String log) {
  final markers = RegExp('$androidPermissionWatcherMarker=(allow|deny:([A-Za-z_]+))').allMatches(log).toList();
  return markers.isEmpty ? null : markers.last[2]?.toUpperCase();
}
