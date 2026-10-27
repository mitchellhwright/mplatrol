import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Base for page objects identified by the `ValueKey` on their screen root.
///
/// A page object declares only its [rootKey] plus its screen-specific logic;
/// the "is this screen present" queries live here.
mixin KeyedPageObject {
  /// The `ValueKey` on this screen's root widget.
  ValueKey<String> get rootKey;

  /// Finder for the screen root. Defaults to Flutter's on-stage match; a page
  /// whose root can sit offstage mid-route overrides this.
  Finder get rootFinder => find.byKey(rootKey);

  /// Whether the screen root is currently in the widget tree.
  bool get isVisible => rootFinder.evaluate().isNotEmpty;

  /// How many screen-root matches exist (a diagnostic for duplicate roots).
  int get visibleCount => rootFinder.evaluate().length;
}
