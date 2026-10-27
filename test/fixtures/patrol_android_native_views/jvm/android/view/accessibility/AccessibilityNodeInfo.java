package android.view.accessibility;
public class AccessibilityNodeInfo {
    public boolean recycled;
    public static AccessibilityNodeInfo obtain(AccessibilityNodeInfo node) {
        return new AccessibilityNodeInfo();
    }
    public AccessibilityWindowInfo getWindow() { return new AccessibilityWindowInfo(); }
    public void recycle() { recycled = true; }
}
