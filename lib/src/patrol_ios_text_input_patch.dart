import 'dart:io';

/// Package-relative native source used by patching and build fingerprints.
const patrolIosTextInputSourcePath = 'darwin/patrol/Sources/PatrolImpl/AutomatorServer/Automator/IOSAutomator.swift';

/// Checks that a generated Patrol copy contains the exact current input patch.
///
/// Returns false for missing source or a stale or incomplete helper.
bool hasPatrolIosTextInputPatch(Directory packageRoot) {
  final source = File('${packageRoot.path}/$patrolIosTextInputSourcePath');
  if (!source.existsSync()) {
    return false;
  }
  final content = source.readAsStringSync();
  return content.contains(_route) && content.contains(_helper);
}

/// Adds explicit UITextView keyboard input to a generated Patrol package copy.
///
/// Args:
///   packageRoot: Generated Patrol copy, never the upstream package cache.
///
/// Throws:
///   FileSystemException: The native source is missing.
///   StateError: Upstream input code changed or the patch is incomplete.
void patchPatrolIosTextInput(Directory packageRoot) {
  final source = File('${packageRoot.path}/$patrolIosTextInputSourcePath');
  final before = source.readAsStringSync();
  final after = patchPatrolIosTextInputSource(before);
  if (before != after) {
    source.writeAsStringSync(after);
  }
}

/// Transforms the actual upstream Swift entry point without changing field input.
///
/// Args:
///   source: Patrol IOSAutomator.swift source text.
///
/// Returns:
///   Idempotently patched source.
///
/// Throws:
///   StateError: Required upstream anchors are missing, duplicated, or changed.
String patchPatrolIosTextInputSource(String source) {
  if (source.contains('private func enterTextView(')) {
    if (!source.contains(_route) || !source.contains(_helper)) {
      throw StateError('Incomplete Patrol UITextView patch; regenerate the '
          'Patrol copy from pristine source before preparing E2E dependencies');
    }
    return source;
  }
  for (final anchor in [
    _entryAnchor,
    _clearAnchor,
    'if let contentPredicate = selector.toTextFieldNSPredicate()',
    'let textFieldPredicate = NSPredicate(format: "elementType == 49")',
    'let secureTextFieldPredicate = NSPredicate(format: "elementType == 50")',
    'element.typeText(delete + data)',
  ]) {
    if (anchor.allMatches(source).length != 1 &&
        !anchor.startsWith('let textFieldPredicate') &&
        !anchor.startsWith('let secureTextFieldPredicate')) {
      throw StateError('Patrol iOS text-input source changed near "$anchor"; '
          'review upstream input semantics before updating this patch');
    }
    if (!source.contains(anchor)) {
      throw StateError('Patrol iOS text-input source is missing "$anchor"; '
          'review upstream input semantics before updating this patch');
    }
  }
  return source.replaceFirst(_entryAnchor, '$_entryAnchor$_route').replaceFirst(_clearAnchor, '$_helper$_clearAnchor');
}

const _entryAnchor = '''    func enterText(
      _ data: String,
      on selector: IOSSelector,
      inApp bundleId: String,
      dismissKeyboard: Bool,
      withTimeout timeout: TimeInterval?,
      dx: CGFloat,
      dy: CGFloat
    ) throws {
''';

const _clearAnchor = '    private func clearAndEnterText(';

const _route = '''      if selector.elementType == .textView {
        try self.enterTextView(data, on: selector, inApp: bundleId,
                               dismissKeyboard: dismissKeyboard,
                               withTimeout: timeout, dx: dx, dy: dy)
        return
      }

''';

const _helper = '''    // Repository patch: explicit UITextView input through XCTest's keyboard.
    private func enterTextView(
      _ data: String,
      on selector: IOSSelector,
      inApp bundleId: String,
      dismissKeyboard: Bool,
      withTimeout timeout: TimeInterval?,
      dx: CGFloat,
      dy: CGFloat
    ) throws {
      try runAction("entering text into a visible enabled UITextView in app \\(bundleId)") {
        guard !dismissKeyboard else {
          throw PatrolError.viewNotExists(
            "UITextView input requires KeyboardBehavior.alternative; Return inserts a newline")
        }
        let app = try self.getApp(withBundleId: bundleId)
        let query = app.descendants(matching: .textView).matching(selector.toNSPredicate())
        guard query.firstMatch.waitForExistence(timeout: timeout ?? self.timeout) else {
          throw PatrolError.viewNotExists("No UITextView matches the supplied selector")
        }
        let elements = query.allElementsBoundByIndex
        let element: XCUIElement
        if let index = selector.instance {
          guard index >= 0 && index < elements.count else {
            throw PatrolError.viewNotExists("UITextView instance index is out of bounds")
          }
          element = elements[index]
          guard element.exists && element.isEnabled && element.isHittable else {
            throw PatrolError.viewNotExists("Selected UITextView is not visible and enabled")
          }
        } else {
          let usable = elements.filter { \$0.exists && \$0.isEnabled && \$0.isHittable }
          guard usable.count == 1 else {
            throw PatrolError.viewNotExists(
              "Expected one visible enabled UITextView; found \\(usable.count). Narrow the selector")
          }
          element = usable[0]
        }
        // Preserve upstream coordinate tap and keyboard-delete semantics, never set UIKit state.
        self.clearAndEnterText(data: data, element: element, dx: dx, dy: dy)
        guard (element.value as? String) == data else {
          throw PatrolError.viewNotExists(
            "UITextView value did not match after keyboard clear/type; check editability and caret")
        }
      }
    }

''';
