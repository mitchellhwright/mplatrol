import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:mplatrol_harness/src/native/native_element_visibility.dart';
import 'package:patrol/patrol.dart';

/// Page object for the OS permission dialogs (location, camera, notifications...) a journey meets.
///
/// It only taps actions it can identify by stable OS resource ids (Android) or
/// SpringBoard button labels (iOS), and refuses to guess when a match is ambiguous.
class SystemPermissionDialogPage {
  /// Creates the page for [platform]; a null [platform] makes every action a no-op.
  ///
  /// [denyNotifications] answers Android notification prompts with Don't allow
  /// while every other prompt is still allowed. A journey that needs a denied
  /// POST_NOTIFICATIONS fixture opts in; the default keeps the allow behaviour.
  SystemPermissionDialogPage(this.platform, {this.denyNotifications = false});

  /// Native automation of the running app; null when the test has none.
  final PlatformAutomator? platform;

  /// Whether Android notification prompts are answered with Don't allow.
  final bool denyNotifications;
  int _androidDiagnosticCount = 0;
  String? _lastAndroidDiagnostic;
  int _permissionEventCount = 0;
  final Stopwatch _permissionClock = Stopwatch();

  static const _iosSpringboardId = 'com.apple.springboard';

  /// Cap for one permission query + tap. A native tap waits for the system UI
  /// to idle (SpringBoard on iOS, UiAutomator on Android); on cloud devices that
  /// alone took about 2 s after a camera grant, so a 2 s cap timed out taps that
  /// had succeeded. An absent dialog returns at once, and an earlier caller
  /// deadline still wins.
  static const _nativeCallTimeout = Duration(seconds: 6);
  static const _allowButtonLabels = <String>[
    'Allow While Using App',
    'Allow While Using the App',
    'While Using the App',
    'While using the app',
    'Allow Once',
    'Only this time',
    'Only This Time',
    // iOS asks to upgrade While Using to Always after the foreground grant;
    // keeping foreground-only access is the least-privileged answer.
    'Keep Only While Using',
    'Allow',
    'ALLOW',
  ];
  static const _androidPermissionPackages = <String>{
    'com.google.android.permissioncontroller',
    'com.android.permissioncontroller',
    'com.android.packageinstaller',
  };
  static const _androidPermissionActions = <String>[
    'permission_allow_foreground_only_button',
    'permission_allow_one_time_button',
    'permission_allow_button',
  ];
  // The second request shows only the don't-ask-again variant; prefer it when present.
  static const _androidDenyActions = <String>[
    'permission_deny_and_dont_ask_again_button',
    'permission_deny_button',
  ];

  /// Taps one confirmed OS permission action within a single operation budget.
  ///
  /// Args:
  ///   deadline: Optional earlier deadline owned by the calling journey phase.
  ///
  /// Returns:
  ///   False only when no native connection or matching visible OS action exists.
  ///
  /// Throws:
  ///   StateError: An OS permission action is ambiguous.
  ///   TimeoutException: The shared operation budget expires.
  ///   Native query and action errors propagate unchanged, without fallback.
  Future<bool> tapAllowIfVisible({DateTime? deadline}) async {
    final automator = platform;
    if (automator == null) {
      return false;
    }
    _permissionClock
      ..reset()
      ..start();
    final localDeadline = DateTime.now().add(_nativeCallTimeout);
    final until = deadline != null && deadline.isBefore(localDeadline) ? deadline : localDeadline;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _tapAndroidPermissionActionIfVisible(automator, until, deny: false);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _tapIosPermissionActionIfVisible(automator, until);
    }
    throw UnsupportedError('System permission handling requires Android or iOS.');
  }

  /// Taps Don't allow on the visible Android OS permission prompt.
  ///
  /// Args:
  ///   deadline: Optional earlier deadline owned by the calling journey phase.
  ///
  /// Returns:
  ///   False only when no native connection or matching visible deny action exists.
  ///
  /// Throws:
  ///   UnsupportedError: Called on a platform other than Android.
  ///   StateError: An OS permission action is ambiguous.
  ///   TimeoutException: The shared operation budget expires.
  Future<bool> tapDenyIfVisible({DateTime? deadline}) async {
    final automator = platform;
    if (automator == null) {
      return false;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Denying a system permission prompt is implemented for Android only.');
    }
    _permissionClock
      ..reset()
      ..start();
    final localDeadline = DateTime.now().add(_nativeCallTimeout);
    final until = deadline != null && deadline.isBefore(localDeadline) ? deadline : localDeadline;
    return _tapAndroidPermissionActionIfVisible(automator, until, deny: true);
  }

  /// Lists labelled SpringBoard and app native elements for failure reports.
  ///
  /// System alerts are absent from some cloud iOS screen recordings, so this is the
  /// only record of what was covering the app when a journey stalled.
  Future<String> describeIosNativeLabels() async {
    final automator = platform;
    if (automator == null || defaultTargetPlatform != TargetPlatform.iOS) {
      return 'n/a';
    }
    final parts = <String>[];
    for (final appId in <String?>[_iosSpringboardId, null]) {
      final response = await nativeWithinDeadline(
        () => automator.ios.getNativeViews(
          const IOSSelector(elementType: IOSElementType.window),
          appId: appId,
        ),
        deadline: DateTime.now().add(_nativeCallTimeout),
        operation: 'iOS native label snapshot',
      );
      final labels = <String>{};
      void collect(IOSNativeView view) {
        final label = view.label.trim();
        if (label.isNotEmpty && labels.length < 15) {
          labels.add('${view.elementType.name}:$label');
        }
        view.children.forEach(collect);
      }

      response.roots.forEach(collect);
      parts.add('${appId ?? 'app'}=[${labels.join('|')}]');
    }
    return parts.join(' ');
  }

  Future<bool> _tapIosPermissionActionIfVisible(
    PlatformAutomator automator,
    DateTime deadline,
  ) async {
    final response = await _tracePermission(
      'ios_query',
      () => iosQueryRetryingTransient(
        () => automator.ios.getNativeViews(
          const IOSSelector(elementType: IOSElementType.window),
          appId: _iosSpringboardId,
        ),
        deadline: deadline,
        operation: 'iOS permission snapshot',
      ),
    );
    final buttons = _visibleIosPermissionButtons(response.roots).toList();
    for (final label in _allowButtonLabels) {
      final matches = buttons
          .where(
            (view) => view.label == label && view.isEnabled && view.elementType == IOSElementType.button,
          )
          .toList();
      if (matches.isEmpty) {
        continue;
      }
      if (matches.length != 1) {
        throw StateError(
          'Expected one SpringBoard permission action; '
          'found ${matches.length}; no action tapped',
        );
      }
      _permissionEvent('ios_match owner=springboard resource=allow label="$label" matched=1');
      final selector = IOSSelector(
        elementType: IOSElementType.button,
        label: label,
        isEnabled: true,
      );
      await _tracePermission(
        'ios_action',
        () => nativeWithinDeadline(
          () => automator.tap(selector, appId: _iosSpringboardId),
          deadline: deadline,
          operation: 'iOS system permission action',
        ),
      );
      return true;
    }
    return false;
  }

  Iterable<IOSNativeView> _visibleIosPermissionButtons(List<IOSNativeView> windows) sync* {
    var hasViewport = false;
    for (final window in windows) {
      final viewport = _iosRect(window);
      if (window.bundleId != _iosSpringboardId || window.elementType != IOSElementType.window) {
        throw StateError('Permission snapshot cannot establish scoped SpringBoard window bounds.');
      }
      if (!viewport.isFinite || viewport.isEmpty) {
        continue;
      }
      hasViewport = true;
      yield* _iosButtonsInWindow(window.children, viewport);
    }
    if (windows.isNotEmpty && !hasViewport) {
      throw StateError('Permission snapshot cannot establish current SpringBoard window bounds.');
    }
  }

  Iterable<IOSNativeView> _iosButtonsInWindow(List<IOSNativeView> views, Rect viewport) sync* {
    for (final view in views) {
      final bounds = _iosRect(view);
      if (view.bundleId == _iosSpringboardId &&
          view.elementType == IOSElementType.button &&
          view.isEnabled &&
          bounds.isFinite &&
          !bounds.isEmpty &&
          bounds.overlaps(viewport)) {
        yield view;
      }
      yield* _iosButtonsInWindow(view.children, viewport);
    }
  }

  Rect _iosRect(IOSNativeView view) =>
      Rect.fromLTRB(view.frame.minX, view.frame.minY, view.frame.maxX, view.frame.maxY);

  Future<bool> _tapAndroidPermissionActionIfVisible(
    PlatformAutomator automator,
    DateTime deadline, {
    required bool deny,
  }) async {
    final response = await _tracePermission(
      'android_query',
      () => nativeWithinDeadline(
        () => automator.android.getNativeViews(const AndroidSelector(isClickable: true)),
        deadline: deadline,
        operation: 'Android system permission snapshot',
      ),
    );
    final owned =
        response.roots.where((button) => _androidPermissionPackages.contains(button.applicationPackage)).toList();
    _recordAndroidPermissionSnapshot(owned);
    final actionable = owned.where(_isAndroidPermissionButton).toList();
    if (actionable.map((button) => button.applicationPackage).toSet().length > 1) {
      throw StateError('Permission snapshot has multiple actionable OS owners; no action tapped');
    }
    final denying = deny ||
        (denyNotifications && actionable.isNotEmpty && await _androidNotificationPromptVisible(automator, deadline));
    for (final resource in denying ? _androidDenyActions : _androidPermissionActions) {
      final matches = actionable
          .where(
            (button) => _androidPermissionPackages.any(
              (namespace) => button.resourceName == '$namespace:id/$resource',
            ),
          )
          .toList();
      if (matches.isEmpty) {
        continue;
      }
      return _tapAndroidAction(automator, matches, deadline, useResource: true);
    }
    if (denying) {
      _permissionEvent('android_match owner=none resource=deny matched=0');
      return false;
    }
    // Observed on an Android 13 build without resource ids. Other locales use stable resource identity;
    // unknown translated labels are not guessed or interpreted as permission.
    final fallback = actionable.where((button) => button.text == 'While using the app').toList();
    if (fallback.isEmpty) {
      _permissionEvent('android_match owner=none resource=none matched=0');
      return false;
    }
    return _tapAndroidAction(automator, fallback, deadline, useResource: false);
  }

  /// Whether the OS prompt asks for notifications (`Allow <app> to send you notifications?`).
  ///
  /// English message text only: an unrecognised locale keeps the allow answer, and the
  /// journey that opted in then reports its fixture unavailable rather than guessing.
  Future<bool> _androidNotificationPromptVisible(PlatformAutomator automator, DateTime deadline) async {
    final response = await _tracePermission(
      'android_notification_query',
      () => nativeWithinDeadline(
        () => automator.android.getNativeViews(const AndroidSelector(textContains: 'notifications')),
        deadline: deadline,
        operation: 'Android notification prompt snapshot',
      ),
    );
    return response.roots.any((view) => _androidPermissionPackages.contains(view.applicationPackage));
  }

  Future<bool> _tapAndroidAction(
    PlatformAutomator automator,
    List<AndroidNativeView> matches,
    DateTime deadline, {
    required bool useResource,
  }) async {
    _permissionEvent('android_match matched=${matches.length}');
    if (matches.length != 1) {
      throw StateError(
        'Expected one Android OS permission action; '
        'found ${matches.length}; no action tapped',
      );
    }
    final button = matches.single;
    final resource = useResource ? _safeAndroidResource(button.resourceName) : 'allow_label';
    _permissionEvent('android_owner owner=${button.applicationPackage} resource=$resource');
    final selector = AndroidSelector(
      applicationPackage: button.applicationPackage,
      resourceName: useResource ? button.resourceName : null,
      text: useResource ? null : button.text,
      isEnabled: true,
      isClickable: true,
    );
    await _tracePermission(
      'android_action',
      () => nativeWithinDeadline(
        () => automator.android.tap(
          selector,
          timeout: remainingNativeBudget(deadline, operation: 'Android system permission action'),
        ),
        deadline: deadline,
        operation: 'Android system permission action',
      ),
    );
    return true;
  }

  Future<T> _tracePermission<T>(String operation, Future<T> Function() call) async {
    _permissionEvent('$operation start');
    try {
      final result = await call();
      _permissionEvent('$operation complete');
      return result;
    } catch (error) {
      final category = error is TimeoutException ? 'timeout' : 'native_error';
      _permissionEvent('$operation error=$category');
      rethrow;
    }
  }

  void _permissionEvent(String event) {
    if (_permissionEventCount++ >= 512) {
      return;
    }
    final remaining = (_nativeCallTimeout.inMilliseconds - _permissionClock.elapsedMilliseconds)
        .clamp(0, _nativeCallTimeout.inMilliseconds);
    debugPrint(
      'E2E_PERMISSION_DIAG $event '
      'time_ms=${DateTime.now().millisecondsSinceEpoch} local_cap_remaining_ms=$remaining',
    );
  }

  bool _isAndroidPermissionButton(AndroidNativeView view) {
    if (!view.isEnabled || !view.isClickable) {
      return false;
    }
    final package = view.applicationPackage;
    final bounds = _androidRect(view);
    return _androidPermissionPackages.contains(package) && bounds.isFinite && !bounds.isEmpty;
  }

  Rect _androidRect(AndroidNativeView view) =>
      Rect.fromLTRB(view.visibleBounds.minX, view.visibleBounds.minY, view.visibleBounds.maxX, view.visibleBounds.maxY);

  void _recordAndroidPermissionSnapshot(List<AndroidNativeView> owned) {
    if (owned.isEmpty || _androidDiagnosticCount >= 4) {
      return;
    }
    final summary = owned.take(6).map((view) {
      final bounds = _androidRect(view);
      return 'package=${view.applicationPackage} '
          'resource=${_safeAndroidResource(view.resourceName)} '
          'class=${_safeAndroidClass(view.className)} '
          'enabled=${view.isEnabled} clickable=${view.isClickable} '
          'finite=${bounds.isFinite} area=${!bounds.isEmpty}';
    }).join('; ');
    final diagnostic = 'SYSTEM_PERMISSION_ANDROID count=${owned.length} $summary';
    if (diagnostic != _lastAndroidDiagnostic) {
      _lastAndroidDiagnostic = diagnostic;
      _androidDiagnosticCount++;
      debugPrint(diagnostic);
    }
  }

  String _safeAndroidResource(String? resource) {
    if (resource == null || resource.length > 160 || !RegExp(r'^[a-zA-Z0-9_.]+:id/[a-zA-Z0-9_]+$').hasMatch(resource)) {
      return 'unavailable';
    }
    return _androidPermissionPackages.any((package) => resource.startsWith('$package:id/')) ? resource : 'unrecognized';
  }

  String _safeAndroidClass(String? className) => className != null &&
          className.length <= 160 &&
          RegExp(r'^android\.(widget|view)\.[A-Za-z0-9_$]+$').hasMatch(className)
      ? className
      : 'unrecognized';
}
