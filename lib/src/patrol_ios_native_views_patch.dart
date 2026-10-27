import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';

/// Returns the source-derived identity of the native collection recipe.
String patrolIosNativeViewsPatchIdentity() => (FingerprintBuilder()
      ..addString(_original)
      ..addString(_replacement))
    .finish();

/// Checks exact collection and snapshot-converter anchors in a prepared copy.
bool hasPatrolIosNativeViewsPatch(Directory root) {
  final file = File('${root.path}/$patrolIosTextInputSourcePath');
  if (!file.existsSync()) {
    return false;
  }
  final source = file.readAsStringSync();
  return _replacement.allMatches(source).length == 1 &&
      _original.allMatches(source).isEmpty &&
      source.contains(_scope) &&
      _converter.allMatches(source).length == 1;
}

/// Patches only a prepared Patrol copy; unknown native source fails closed.
void patchPatrolIosNativeViews(Directory root) {
  final file = File('${root.path}/$patrolIosTextInputSourcePath');
  final before = file.readAsStringSync();
  final after = patchPatrolIosNativeViewsSource(before);
  if (before != after) {
    file.writeAsStringSync(after);
  }
}

/// Preserves query semantics while serializing one immutable snapshot per match.
///
/// Snapshot acquisition can still fail if a matched element disappears. That
/// error propagates; this transformation adds no retry or absence conversion.
String patchPatrolIosNativeViewsSource(String source) {
  if (_converter.allMatches(source).length != 1 || _scope.allMatches(source).length != 1) {
    throw StateError('Patrol snapshot converter changed; review native query semantics');
  }
  if (_replacement.allMatches(source).length == 1 && !source.contains(_original)) {
    return source;
  }
  if (_original.allMatches(source).length != 1 || source.contains(_marker)) {
    throw StateError('Patrol native collection source changed or is incomplete; '
        'restore pristine source before preparing');
  }
  return source.replaceFirst(_original, _replacement);
}

const _converter = 'static func fromXCUIElementSnapshot(_ xcuielement: XCUIElementSnapshot, _ bundleId: String)';
const _marker = '// Repository patch: snapshot native query matches once.';
const _scope = '''    func getNativeViews(
      on selector: IOSSelector,
      inApp bundleId: String
    ) throws -> [IOSNativeView] {
      let view = createLogMessage(element: "views", from: selector)
      return try runAction("getting native \\(view)") {
        let app = try self.getApp(withBundleId: bundleId)

        // TODO: We should consider more view properties. See #1554
        let query = app.descendants(matching: .any).matching(selector.toNSPredicate())
''';
const _original = '''        let elements = query.allElementsBoundByIndex

        let views = elements.map { xcuielement in
          return IOSNativeView.fromXCUIElement(xcuielement, bundleId)
        }

        return views''';
const _replacement = '''        // Repository patch: snapshot native query matches once.
        let elements = query.allElementsBoundByAccessibilityElement
        return try elements.map { element in
          let snapshot = try element.snapshot()
          return IOSNativeView.fromXCUIElementSnapshot(snapshot, bundleId)
        }''';
