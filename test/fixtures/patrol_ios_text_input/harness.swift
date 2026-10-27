// XCTest transport fixture, not an on-device typing test.
import Foundation
import CoreGraphics

enum ElementType: Int { case any = 0, textField = 49, secureTextField = 50, textView = 52 }
enum XCUIKeyboardKey: String { case delete = "\u{8}" }
enum PatrolError: Error { case viewNotExists(String) }

extension String.StringInterpolation {
  mutating func appendInterpolation(format value: String) { appendLiteral(value) }
}

final class XCUIElement: NSObject {
  @objc dynamic var elementType: Int
  @objc dynamic var value: Any?
  @objc dynamic var identifier: String
  var exists = true
  var isEnabled = true
  var isHittable = true
  var readOnly = false
  var brokenCaret = false
  var typed = ""
  var taps = 0
  init(_ type: ElementType, _ text: String = "", id: String = "input") {
    elementType = type.rawValue
    value = text
    identifier = id
  }
  func waitForExistence(timeout: TimeInterval) -> Bool { exists }
  func coordinate(withNormalizedOffset: CGVector) -> XCUIElement { self }
  func tap() { taps += 1 }
  func typeText(_ text: String) {
    typed += text
    guard !readOnly else { return }
    var current = value as? String ?? ""
    for character in text {
      if character == "\u{8}" {
        if !current.isEmpty && !brokenCaret { current.removeLast() }
      } else { current.append(character) }
    }
    value = current
  }
}

struct IOSSelector {
  var elementType: ElementType?
  var identifier: String?
  var instance: Int?
  var isEnabled: Bool?
  func toTextFieldNSPredicate() -> NSPredicate? {
    guard let identifier else { return nil }
    return NSPredicate(format: "identifier == %@", identifier)
  }
  func toNSPredicate() -> NSPredicate {
    NSPredicate { object, _ in
      guard let element = object as? XCUIElement else { return false }
      return (self.elementType == nil || element.elementType == self.elementType!.rawValue)
        && (self.identifier == nil || element.identifier == self.identifier)
        && (self.isEnabled == nil || element.isEnabled == self.isEnabled)
    }
  }
}

final class XCUIElementQuery {
  let elements: [XCUIElement]
  init(_ elements: [XCUIElement]) { self.elements = elements }
  func matching(_ predicate: NSPredicate) -> XCUIElementQuery {
    XCUIElementQuery(elements.filter { predicate.evaluate(with: $0) })
  }
  var allElementsBoundByIndex: [XCUIElement] { elements }
  var firstMatch: XCUIElement {
    if let first = elements.first { return first }
    let absent = XCUIElement(.any)
    absent.exists = false
    return absent
  }
}

final class Application {
  let elements: [XCUIElement]
  init(_ elements: [XCUIElement]) { self.elements = elements }
  func descendants(matching type: ElementType) -> XCUIElementQuery {
    XCUIElementQuery(elements.filter { type == .any || $0.elementType == type.rawValue })
  }
}

final class Automator {
  let app: Application
  let timeout: TimeInterval = 1
  var sleepCalls = 0
  init(_ elements: [XCUIElement]) { app = Application(elements) }
  func getApp(withBundleId: String) throws -> Application { app }
  func createLogMessage(element: String, from: IOSSelector) -> String { element }
  func runAction<T>(_ message: String, _ body: () throws -> T) rethrows -> T { try body() }
  func waitFor(query: XCUIElementQuery, index: Int, timeout: TimeInterval) -> XCUIElement? {
    guard index >= 0 && index < query.elements.count else { return nil }
    return query.elements[index]
  }
  func sleepTask(timeInSeconds: Int) { sleepCalls += 1 }
  // INSERT_ACTUAL_PATCHED_UPSTREAM_METHODS
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}

func type(_ automator: Automator, _ selector: IOSSelector, dismiss: Bool = false) throws {
  try automator.enterText("new draft", on: selector, inApp: "fixture",
                          dismissKeyboard: dismiss, withTimeout: 1, dx: 0.9, dy: 0.9)
}

func rejects(_ automator: Automator, _ selector: IOSSelector,
             containing message: String, dismiss: Bool = false) {
  do { try type(automator, selector, dismiss: dismiss); fatalError("Expected rejection") }
  catch PatrolError.viewNotExists(let detail) { require(detail.contains(message), detail) }
  catch { fatalError("Unexpected error: \(error)") }
}

let textView = IOSSelector(elementType: .textView, identifier: "input", isEnabled: true)
let empty = XCUIElement(.textView)
let emptyAutomator = Automator([empty])
try type(emptyAutomator, textView)
require(empty.value as? String == "new draft", "Empty text view not typed")
require(empty.taps == 1 && emptyAutomator.sleepCalls == 0, "Expected visible tap without sleep")

let existing = XCUIElement(.textView, "old multiline\ndraft")
try type(Automator([existing]), textView)
require(existing.value as? String == "new draft", "Existing text view not cleared")
require(existing.typed.hasPrefix(String(repeating: "\u{8}", count: 19)), "No keyboard clearing")

for kind in [ElementType.textField, .secureTextField] {
  let field = XCUIElement(kind, "old")
  try type(Automator([field]), IOSSelector(elementType: kind, identifier: "input"))
  require(field.value as? String == "new draft", "Legacy field behavior changed")
}

let defaultField = XCUIElement(.textField)
try type(Automator([defaultField]), IOSSelector(elementType: .textField), dismiss: true)
require(defaultField.value as? String == "new draft\n", "Legacy Return behavior changed")

let indexedField = XCUIElement(.secureTextField)
try Automator([indexedField]).enterText("indexed", byIndex: 0, inApp: "fixture",
    dismissKeyboard: false, withTimeout: 1, dx: 0.9, dy: 0.9)
require(indexedField.value as? String == "indexed", "Indexed secure field changed")

rejects(Automator([]), textView, containing: "No UITextView")
let disabled = XCUIElement(.textView)
disabled.isEnabled = false
rejects(Automator([disabled]), textView, containing: "No UITextView")
let hidden = XCUIElement(.textView)
hidden.isHittable = false
rejects(Automator([hidden]), textView, containing: "found 0")
let first = XCUIElement(.textView)
let second = XCUIElement(.textView)
rejects(Automator([first, second]), textView, containing: "found 2")
require(first.taps == 0 && second.taps == 0, "Ambiguity caused a tap")

try type(Automator([first, second]), IOSSelector(elementType: .textView, instance: 1))
require(first.taps == 0 && second.value as? String == "new draft", "Explicit index ignored")
rejects(Automator([first]), IOSSelector(elementType: .textView, instance: -1),
        containing: "out of bounds")

let readOnly = XCUIElement(.textView)
readOnly.readOnly = true
rejects(Automator([readOnly]), textView, containing: "value did not match")
let caret = XCUIElement(.textView, "old")
caret.brokenCaret = true
rejects(Automator([caret]), textView, containing: "value did not match")
rejects(Automator([empty]), textView, containing: "KeyboardBehavior.alternative", dismiss: true)
print("SWIFT_INPUT_FIXTURE_PASSED 15")
