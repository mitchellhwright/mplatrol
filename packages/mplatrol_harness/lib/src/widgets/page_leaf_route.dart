import 'package:flutter/widgets.dart';

/// The route [element] is shown in when [element] is a leaf (has no child elements), else null.
///
/// `ModalRoute.of` registers the element it is given as a dependent of the route's status. Calling it
/// on every element of `WidgetTester.allElements` also registers the route's own transition widgets
/// (the `IgnorePointer` that holds the page), which never depend on it themselves. When the route
/// pushes or pops, Flutter then rebuilds or moves those widgets out of order and reports "Duplicate
/// GlobalKey detected in widget tree" for the page key and a failed `notifyClients` descendant
/// assertion. Leaf elements always sit inside a route's page, so looking the route up
/// from leaves only finds the same routes without touching the transition widgets.
ModalRoute<Object?>? pageLeafRoute(Element element) {
  var hasChild = false;
  element.visitChildren((_) => hasChild = true);
  return hasChild ? null : ModalRoute.of(element);
}
