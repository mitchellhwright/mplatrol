package androidx.test.uiautomator;
import android.graphics.Point;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.Collections;
import java.util.List;

class UiDevice {
    AccessibilityNodeInfo[] roots;
    RuntimeException failure;
    boolean displayAccessible = true;
    int displayId;
    AccessibilityNodeInfo[] getWindowRoots() { if (failure != null) throw failure; return roots; }
    android.view.Display getDisplayById(int id) {
        displayId = id;
        return displayAccessible ? new android.view.Display() : null;
    }
    Point getDisplaySize(int id) { return new Point(); }
}
