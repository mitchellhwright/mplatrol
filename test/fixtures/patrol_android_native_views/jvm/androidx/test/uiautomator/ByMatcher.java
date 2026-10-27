package androidx.test.uiautomator;
import android.graphics.Point;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.Collections;
import java.util.List;

class ByMatcher {
    static BySelector selector;
    static int calls;
    static RuntimeException failure;
    static List<AccessibilityNodeInfo> matches = Collections.singletonList(new AccessibilityNodeInfo());
    static List<AccessibilityNodeInfo> findMatches(UiDevice device, BySelector selected,
            AccessibilityNodeInfo... roots) {
        selector = selected; calls++;
        if (failure != null) throw failure;
        if (matches.isEmpty()) return matches;
        // AndroidX 2.3.0 PartialMatch stores AccessibilityNodeInfo.obtain(node).
        return Collections.singletonList(AccessibilityNodeInfo.obtain(roots[0]));
    }
}
