package androidx.test.uiautomator;
import android.graphics.Point;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.Collections;
import java.util.List;

class AccessibilityNodeInfoHelper {
    static boolean trim;
    static Rect screen;
    static Rect getVisibleBoundsInScreen(AccessibilityNodeInfo node, Rect display, boolean scroll) {
        trim = scroll; screen = display;
        return new Rect(0, 0, 100, 30);
    }
}

