import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';

/// Relative Android serializer path within a prepared Patrol package.
const patrolAndroidNativeViewsSourcePath = 'android/src/main/kotlin/pl/leancode/patrol/Automator.kt';
const _legacyBridgePath = 'android/src/main/kotlin/androidx/test/uiautomator/PatrolNativeSnapshot.java';
const _bridgePath = 'android/src/main/java/androidx/test/uiautomator/PatrolNativeSnapshot.java';

/// Returns the source-derived Android snapshot recipe identity.
String patrolAndroidNativeViewsPatchIdentity() => (FingerprintBuilder()
      ..addString(_replacement)
      ..addString(_converter)
      ..addString(_bridge))
    .finish();

/// Checks the exact serializer and version-bound bridge in a prepared copy.
bool hasPatrolAndroidNativeViewsPatch(Directory root) {
  if (File('${root.path}/$_legacyBridgePath').existsSync() || !_hasSupportedAndroidXVersion(root)) {
    return false;
  }
  final source = File('${root.path}/$patrolAndroidNativeViewsSourcePath');
  final bridge = File('${root.path}/$_bridgePath');
  if (!source.existsSync() || !bridge.existsSync()) {
    return false;
  }
  final text = source.readAsStringSync();
  return _replacement.allMatches(text).length == 1 &&
      _converter.allMatches(text).length == 1 &&
      !text.contains(_original) &&
      bridge.readAsStringSync() == _bridge;
}

/// Patches only a prepared package using the resolved AndroidX 2.3.0 API.
///
/// Missing/unknown sources fail before compilation; native acquisition and
/// serialization errors still propagate. This adds no stale-object retry.
void patchPatrolAndroidNativeViews(Directory root) {
  if (File('${root.path}/$_legacyBridgePath').existsSync() || !_hasSupportedAndroidXVersion(root)) {
    throw StateError('Unsupported or ambiguous Patrol AndroidX snapshot API; '
        'expected one literal uiautomator 2.3.0 dependency');
  }
  final file = File('${root.path}/$patrolAndroidNativeViewsSourcePath');
  final before = file.readAsStringSync();
  final after = patchPatrolAndroidNativeViewsSource(before);
  final bridge = File('${root.path}/$_bridgePath');
  if (bridge.existsSync() && bridge.readAsStringSync() != _bridge) {
    throw StateError('Patrol Android snapshot bridge changed; restore pristine source');
  }
  if (after != before) {
    file.writeAsStringSync(after);
  }
  if (!bridge.existsSync()) {
    bridge.parent.createSync(recursive: true);
    bridge.writeAsStringSync(_bridge);
  }
}

bool _hasSupportedAndroidXVersion(Directory root) {
  final file = File('${root.path}/android/build.gradle');
  if (!file.existsSync()) {
    return false;
  }
  final source = file.readAsStringSync().replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\n]*'), '');
  final declarations =
      RegExp(r'''["']androidx\.test\.uiautomator:uiautomator:([^"']+)["']''').allMatches(source).toList();
  final pinned = RegExp(r'''^\s*api\s+["']androidx\.test\.uiautomator:uiautomator:2\.3\.0["']''', multiLine: true)
      .allMatches(source)
      .length;
  return declarations.length == 1 && declarations.single.group(1) == '2.3.0' && pinned == 1;
}

/// Replaces repeated live getters with serialization of acquired nodes.
String patchPatrolAndroidNativeViewsSource(String source) {
  if (_replacement.allMatches(source).length == 1 &&
      _converter.allMatches(source).length == 1 &&
      !source.contains(_original)) {
    return source;
  }
  if (_original.allMatches(source).length != 1 ||
      _originalQuery.allMatches(source).length != 1 ||
      source.contains('PatrolNativeSnapshot')) {
    throw StateError('Patrol Android native serializer changed; review snapshot semantics');
  }
  return source.replaceFirst(_original, _converter).replaceFirst(_originalQuery, _replacement).replaceFirst(
      'import androidx.test.uiautomator.UiDevice',
      'import android.view.accessibility.AccessibilityNodeInfo\n'
          'import androidx.test.uiautomator.PatrolNativeSnapshot\n'
          'import androidx.test.uiautomator.UiDevice');
}

const _originalQuery = '''        val uiObjects2 = uiDevice.findObjects(selector)
        return uiObjects2.map { fromUiObject2(it) }''';
const _replacement = '''        // Repository patch: serialize acquired accessibility nodes without live refreshes.
        val nodes = PatrolNativeSnapshot.findMatches(uiDevice, selector)
        return try {
            nodes.map { fromNativeSnapshot(it, uiDevice) }
        } finally {
            nodes.forEach { PatrolNativeSnapshot.recycle(it) }
        }''';
const _original = '''private fun fromUiObject2(obj: UiObject2): AndroidNativeView {
    val bounds = obj.visibleBounds
    val center = obj.visibleCenter

    return AndroidNativeView(
        className = obj.className,
        text = obj.text,
        contentDescription = obj.contentDescription,
        isFocused = obj.isFocused,
        isEnabled = obj.isEnabled,
        childCount = obj.childCount.toLong(),
        resourceName = obj.resourceName,
        applicationPackage = obj.applicationPackage,
        isCheckable = obj.isCheckable,
        isChecked = obj.isChecked,
        isClickable = obj.isClickable,
        isFocusable = obj.isFocusable,
        isLongClickable = obj.isLongClickable,
        isScrollable = obj.isScrollable,
        isSelected = obj.isSelected,
        visibleBounds = Rectangle(
            minX = bounds.left.toDouble(),
            minY = bounds.top.toDouble(),
            maxX = bounds.right.toDouble(),
            maxY = bounds.bottom.toDouble()
        ),
        visibleCenter = Point2D(
            x = center.x.toDouble(),
            y = center.y.toDouble()
        ),
        children = obj.children?.map { fromUiObject2(it) } ?: listOf()
    )
}
''';
const _converter = '''private fun fromNativeSnapshot(obj: AccessibilityNodeInfo, device: UiDevice): AndroidNativeView {
    val bounds = PatrolNativeSnapshot.visibleBounds(device, obj)
    val count = obj.childCount
    val children = (0 until count).mapNotNull { index ->
        val child = obj.getChild(index)
            ?: throw IllegalStateException("Native snapshot child disappeared")
        try {
            if (child.isVisibleToUser) fromNativeSnapshot(child, device) else null
        } finally {
            PatrolNativeSnapshot.recycle(child)
        }
    }
    return AndroidNativeView(
        className = obj.className?.toString(),
        text = obj.text?.toString(),
        contentDescription = obj.contentDescription?.toString(),
        isFocused = obj.isFocused,
        isEnabled = obj.isEnabled,
        childCount = count.toLong(),
        resourceName = obj.viewIdResourceName,
        applicationPackage = obj.packageName?.toString(),
        isCheckable = obj.isCheckable,
        isChecked = obj.isChecked,
        isClickable = obj.isClickable,
        isFocusable = obj.isFocusable,
        isLongClickable = obj.isLongClickable,
        isScrollable = obj.isScrollable,
        isSelected = obj.isSelected,
        visibleBounds = Rectangle(
            minX = bounds.left.toDouble(), minY = bounds.top.toDouble(),
            maxX = bounds.right.toDouble(), maxY = bounds.bottom.toDouble()
        ),
        visibleCenter = Point2D(x = bounds.centerX().toDouble(), y = bounds.centerY().toDouble()),
        children = children
    )
}
''';
const _bridge = '''package androidx.test.uiautomator;

import android.graphics.Point;
import android.graphics.Rect;
import android.os.Build;
import android.view.Display;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.List;

/** Acquires the existing selector's nodes before Patrol serializes their stored properties. */
@SuppressWarnings("deprecation")
public final class PatrolNativeSnapshot {
    private PatrolNativeSnapshot() {}

    /** Uses AndroidX 2.3.0 matching; adds no exception fallback or retry. */
    public static List<AccessibilityNodeInfo> findMatches(UiDevice device, BySelector selector) {
        AccessibilityNodeInfo[] roots = device.getWindowRoots();
        if (roots.length == 0) {
            throw new IllegalStateException("Native snapshot has no accessible window roots");
        }
        try {
            return ByMatcher.findMatches(device, selector, roots);
        } finally {
            for (AccessibilityNodeInfo root : roots) {
                root.recycle();
            }
        }
    }

    /** Releases acquired nodes on Android versions where recycling is required. */
    public static void recycle(AccessibilityNodeInfo node) {
        if (Build.VERSION.SDK_INT < 33) {
            node.recycle();
        }
    }

    /** Preserves UiObject2 display, window and scrollable-ancestor clipping. */
    public static Rect visibleBounds(UiDevice device, AccessibilityNodeInfo node) {
        AccessibilityWindowInfo window = node.getWindow();
        int displayId = Build.VERSION.SDK_INT >= 30 && window != null
                ? window.getDisplayId() : Display.DEFAULT_DISPLAY;
        Rect screen = null;
        if (device.getDisplayById(displayId) != null) {
            Point size = device.getDisplaySize(displayId);
            screen = new Rect(0, 0, size.x, size.y);
        }
        return AccessibilityNodeInfoHelper.getVisibleBoundsInScreen(node, screen, true);
    }
}
''';
