package androidx.test.uiautomator;
import android.graphics.Point;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.Collections;
import java.util.List;

public class Harness {
    public static void main(String[] args) {
        UiDevice device = new UiDevice();
        BySelector selector = new BySelector();
        AccessibilityNodeInfo root = new AccessibilityNodeInfo();
        device.roots = new AccessibilityNodeInfo[] {root};
        List<AccessibilityNodeInfo> acquired = PatrolNativeSnapshot.findMatches(device, selector);
        check(acquired.size() == 1 && acquired.get(0) != root);
        check(!acquired.get(0).recycled);
        check(ByMatcher.selector == selector && ByMatcher.calls == 1 && root.recycled);
        ByMatcher.matches = Collections.emptyList();
        check(PatrolNativeSnapshot.findMatches(device, selector).isEmpty());
        RuntimeException failure = new IllegalStateException("fixture transport failure");
        device.failure = failure;
        expectFailure(() -> PatrolNativeSnapshot.findMatches(device, selector), failure);
        check(ByMatcher.calls == 2);
        device.failure = null;
        ByMatcher.failure = failure;
        root.recycled = false;
        expectFailure(() -> PatrolNativeSnapshot.findMatches(device, selector), failure);
        check(root.recycled && ByMatcher.calls == 3);
        ByMatcher.failure = null;
        device.roots = new AccessibilityNodeInfo[0];
        try {
            PatrolNativeSnapshot.findMatches(device, selector);
            throw new AssertionError("missing roots became absence");
        } catch (IllegalStateException expected) { check(ByMatcher.calls == 3); }
        PatrolNativeSnapshot.visibleBounds(device, root);
        check(AccessibilityNodeInfoHelper.trim && AccessibilityNodeInfoHelper.screen.right == 400);
        android.os.Build.VERSION.SDK_INT = 33;
        PatrolNativeSnapshot.visibleBounds(device, root);
        check(device.displayId == 2);
        device.displayAccessible = false;
        PatrolNativeSnapshot.visibleBounds(device, root);
        check(AccessibilityNodeInfoHelper.screen == null);
        System.out.println("JAVA_SNAPSHOT_BOUNDARY_PASSED cases=7");
    }
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    private static void expectFailure(Runnable operation, RuntimeException original) {
        try { operation.run(); throw new AssertionError("native failure became absence"); }
        catch (RuntimeException actual) { check(actual == original); }
    }
}
