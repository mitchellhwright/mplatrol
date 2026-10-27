import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.BySelector
import pl.leancode.patrol.contracts.Contracts.AndroidNativeView
import pl.leancode.patrol.contracts.Contracts.Rectangle
import pl.leancode.patrol.contracts.Contracts.Point2D

private fun fromUiObject2(obj: UiObject2): AndroidNativeView {
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

class Automator(private val uiDevice: UiDevice) {
    fun getNativeViews(selector: BySelector): List<AndroidNativeView> {
        val uiObjects2 = uiDevice.findObjects(selector)
        return uiObjects2.map { fromUiObject2(it) }
    }
}
