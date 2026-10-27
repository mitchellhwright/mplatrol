import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The first [limit] hit-testable texts on screen, each cut to [maxLength] characters, for failure messages.
String visibleScreenText({int limit = 24, int maxLength = 30}) {
  final shown = <String>[];
  for (final element in find.byType(RichText).hitTestable().evaluate()) {
    final text = (element.widget as RichText).text.toPlainText().trim();
    if (text.isNotEmpty && shown.length < limit) {
      shown.add(text.length > maxLength ? text.substring(0, maxLength) : text);
    }
  }
  return shown.toString();
}
