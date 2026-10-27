import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:mplatrol_harness/src/native/native_operation_lifecycle.dart';
import 'package:patrol/patrol.dart';

/// Returns the budget left for an operation without resetting its deadline.
///
/// Args:
///   deadline: Absolute deadline established by the owning journey phase.
///   operation: Controlled operation label, not native response contents.
///
/// Returns:
///   The strictly positive remaining duration.
///
/// Throws:
///   TimeoutException: The operation deadline has expired.
Duration remainingNativeBudget(DateTime deadline, {required String operation}) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    throw TimeoutException('$operation deadline expired before native RPC');
  }
  return remaining;
}

/// Executes one operation under an existing deadline and rejects late completion.
///
/// Args:
///   query: Native operation to invoke only while budget remains.
///   deadline: Absolute deadline shared by all operations in the current phase.
///   operation: Controlled diagnostic label for timeout failures.
///
/// Returns:
///   The operation result. A timeout does not cancel the underlying transport;
///   callers must abort the phase rather than retry an outstanding operation.
///
/// Throws:
///   TimeoutException: The operation exhausts its budget or completes late; the message names
///   [operation] (a bare `Future not completed` hid which wait ran out).
///   Native transport errors propagate unchanged.
Future<T> nativeWithinDeadline<T>(Future<T> Function() query,
    {required DateTime deadline, required String operation}) async {
  final budget = remainingNativeBudget(deadline, operation: operation);
  final result = await trackNativeOperation(query).timeout(
    ceilToWholeMilliseconds(budget),
    onTimeout: () => throw TimeoutException('$operation did not complete within its remaining $budget', budget),
  );
  remainingNativeBudget(deadline, operation: operation);
  return result;
}

/// Rounds [budget] up to whole milliseconds for a timer that must not fire before its deadline.
///
/// The VM timer drops the sub-millisecond part of a duration, so a timeout of exactly the
/// time left can fire while the clock still shows budget, and a poll loop would then retry
/// with its timed-out operation still pending.
Duration ceilToWholeMilliseconds(Duration budget) => Duration(
    milliseconds:
        (budget.inMicroseconds + Duration.microsecondsPerMillisecond - 1) ~/ Duration.microsecondsPerMillisecond);

/// Runs one iteration of a deadline-bounded poll loop.
///
/// A probe cut off because the loop's own [deadline] expired mid-call would
/// otherwise surface as a near-zero `TimeoutException after 0:00:00.0xx`.
///
/// Args:
///   probe: One poll iteration, bounded by [deadline].
///   deadline: The loop's absolute deadline.
///
/// Returns:
///   The probe result, or null when [deadline] expired during the probe so the
///   caller can report its descriptive last-known state instead.
///
/// Throws:
///   TimeoutException: The probe timed out while [deadline] still had budget.
///   Other probe errors propagate unchanged.
Future<T?> pollWithinDeadline<T>(Future<T> Function() probe, DateTime deadline) async {
  try {
    return await probe();
  } on TimeoutException {
    if (DateTime.now().isBefore(deadline)) {
      rethrow;
    }
    return null;
  }
}

/// Queries fresh Android matches using their clipped native geometry.
///
/// Args:
///   android: Connection to the running Android application.
///   selector: Page-owned, appropriately scoped native selector.
///   deadline: Absolute deadline for this probe, not a renewed per-RPC timeout.
///
/// Returns:
///   Fresh on-screen roots. These are not retained across UI transitions and do
///   not establish occlusion or action success.
///
/// Throws:
///   TimeoutException: The probe exceeds [deadline].
///   PatrolActionException: A [isTransientAndroidSnapshotError] answer is still returned when [deadline] runs
///     out. Other native errors propagate unchanged.
Future<List<AndroidNativeView>> nativeAndroidVisibleMatches(AndroidAutomator android, AndroidSelector selector,
    {required DateTime deadline}) async {
  var retries = 0;
  while (true) {
    try {
      final response = await nativeWithinDeadline(() => android.getNativeViews(selector),
          deadline: deadline, operation: 'Android visibility');
      return response.roots.where((view) => _hasArea(view.visibleBounds)).toList();
    } on PatrolActionException catch (error) {
      if (!isTransientAndroidSnapshotError(error) ||
          deadline.difference(DateTime.now()) <= iosTransientQueryRetryDelay) {
        rethrow;
      }
      retries++;
      debugPrint('E2E_ANDROID_QUERY_TRANSIENT_RETRY code=child_disappeared retry=$retries');
      await Future<void>.delayed(iosTransientQueryRetryDelay);
    }
  }
}

/// Whether [error] says a view left the Android accessibility tree while Patrol serialized it
/// (`Native snapshot child disappeared`), as when the system biometric prompt opens or closes. The same
/// query can succeed a moment later.
bool isTransientAndroidSnapshotError(Object error) =>
    error is PatrolActionException && error.message.contains('Native snapshot child disappeared');

/// Pause before re-running a native query that answered with a transient error.
const iosTransientQueryRetryDelay = Duration(milliseconds: 250);

/// Whether [error] is XCTest 10008 ("No matches found for Identity Binding").
///
/// XCTest matched an element and then lost it while building the snapshot, because the
/// app rebuilt that part of its UI (seen on iOS Settings' Allow Notifications switch). The
/// same query can succeed a moment later.
bool isTransientIosQueryError(Object error) =>
    error is PatrolActionException && (error.message.contains('Code=10008') || isIosAutomatorUnreachable(error));

/// Whether [error] says Patrol's on-device iOS automation server did not accept the connection
/// (`503 dial tcp [::1]:8081: connect: connection refused`), as seen on cloud devices while the
/// XCUITest runner is still starting. The same query can succeed once the server is up.
bool isIosAutomatorUnreachable(Object error) =>
    error is PatrolActionException && error.message.contains('connection refused') && error.message.contains(':8081');

/// Queries fresh iOS matches clipped against current native app-window geometry.
///
/// XCTest 10008 answers are retried after [iosTransientQueryRetryDelay] while [deadline]
/// leaves room for another query.
///
/// Args:
///   ios: Connection to the running iOS application.
///   selector: Page-owned, appropriately scoped native selector.
///   deadline: Absolute deadline shared by selector and window queries.
///   appId: Optional application scope, applied to both selector and window queries.
///
/// Returns:
///   Fresh on-screen roots, not paint or hit-test proof. Real actions and their
///   page-specific postconditions must still succeed.
///
/// Throws:
///   StateError: Current app-window geometry cannot be established.
///   TimeoutException: The probe exceeds [deadline].
///   PatrolActionException: A 10008 answer is still returned when [deadline] runs out.
///   Other native errors propagate unchanged.
Future<List<IOSNativeView>> nativeIosVisibleMatches(IOSAutomator ios, IOSSelector selector,
    {required DateTime deadline, String? appId}) async {
  final response = await iosQueryRetryingTransient(
      () => appId == null ? ios.getNativeViews(selector) : ios.getNativeViews(selector, appId: appId),
      deadline: deadline,
      operation: 'iOS visibility');
  final candidates = response.roots.where((view) => _hasArea(view.frame)).toList();
  if (candidates.isEmpty) {
    return [];
  }
  final windows = await iosQueryRetryingTransient(
      () => appId == null
          ? ios.getNativeViews(const IOSSelector(elementType: IOSElementType.window))
          : ios.getNativeViews(const IOSSelector(elementType: IOSElementType.window), appId: appId),
      deadline: deadline,
      operation: 'iOS window visibility');
  final viewport = windows.roots.where((view) => _hasArea(view.frame)).toList();
  if (viewport.isEmpty) {
    throw StateError('Native visibility cannot establish current app window bounds.');
  }
  return candidates.where((view) => viewport.any((window) => _rect(view.frame).overlaps(_rect(window.frame)))).toList();
}

/// Runs an iOS native query, retrying the transient answers [isTransientIosQueryError] names
/// while [deadline] leaves room for another try.
Future<IOSGetNativeViewsResponse> iosQueryRetryingTransient(Future<IOSGetNativeViewsResponse> Function() query,
    {required DateTime deadline, required String operation}) async {
  var retries = 0;
  while (true) {
    try {
      return await nativeWithinDeadline(query, deadline: deadline, operation: operation);
    } on PatrolActionException catch (error) {
      final roomForRetry = deadline.difference(DateTime.now()) > iosTransientQueryRetryDelay;
      if (!isTransientIosQueryError(error) || !roomForRetry) {
        rethrow;
      }
      retries++;
      final code = isIosAutomatorUnreachable(error) ? 'automator_unreachable' : '10008';
      debugPrint('E2E_IOS_QUERY_TRANSIENT_RETRY operation="$operation" code=$code retry=$retries');
      await Future<void>.delayed(iosTransientQueryRetryDelay);
    }
  }
}

/// Checks one fresh native snapshot without a duplicate lookup or visibility wait.
///
/// Args:
///   platform: Native connection for the running application.
///   selector: Page-owned native selector; vendor identity stays page-specific.
///   timeout: Maximum duration of this entire probe, including iOS windows.
///   deadline: Optional earlier phase deadline; never extends [timeout].
///   unique: Require exactly one on-screen match before reporting visibility.
///
/// Returns:
///   Whether fresh on-screen matches satisfy the requested count. Actions must
///   still succeed; no snapshot is cached across transitions.
///
/// Throws:
///   UnsupportedError: The current platform is neither Android nor iOS.
///   TimeoutException: The probe or owning phase deadline expires.
///   Other native errors propagate unchanged.
Future<bool> nativeElementVisible(PlatformAutomator platform, Selector selector,
    {Duration timeout = const Duration(seconds: 2), DateTime? deadline, bool unique = false}) async {
  final probeDeadline = DateTime.now().add(timeout);
  final until = deadline != null && deadline.isBefore(probeDeadline) ? deadline : probeDeadline;
  final int count;
  if (defaultTargetPlatform == TargetPlatform.android) {
    count = (await nativeAndroidVisibleMatches(platform.android, selector.android, deadline: until)).length;
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    count = (await nativeIosVisibleMatches(platform.ios, selector.ios, deadline: until)).length;
  } else {
    throw UnsupportedError('Native visibility requires Android or iOS.');
  }
  return unique ? count == 1 : count > 0;
}

/// Log lines for a native tree dump: a `<tag> nodes=<n>` header, then one
/// `<tag>[<index>/<n>] ...` line per node with what a control matcher needs, capped at
/// [limit] nodes.
///
/// Print each line separately: logcat cuts a single multi-line print after a few nodes.
List<String> androidNodeDumpLines(String tag, List<AndroidNativeView> nodes, {int limit = 60}) {
  final lines = ['$tag nodes=${nodes.length}'];
  for (var index = 0; index < nodes.length && index < limit; index++) {
    lines.add('$tag[$index/${nodes.length}] ${_describeNode(nodes[index])}');
  }
  if (nodes.length > limit) {
    lines.add('$tag ... ${nodes.length - limit} more');
  }
  return lines;
}

String _describeNode(AndroidNativeView node) =>
    'class=${node.className} id=${node.resourceName} text=${node.text} desc=${node.contentDescription} '
    'checkable=${node.isCheckable} checked=${node.isChecked} clickable=${node.isClickable} enabled=${node.isEnabled}';

bool _hasArea(Rectangle bounds) => _rect(bounds).isFinite && !_rect(bounds).isEmpty;

Rect _rect(Rectangle bounds) => Rect.fromLTRB(bounds.minX, bounds.minY, bounds.maxX, bounds.maxY);
