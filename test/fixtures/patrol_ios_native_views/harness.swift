import Foundation

enum Failure: Error { case disappeared, unavailableApp }
enum ElementType { case any, button }
struct IOSSelector {
  let enabled: Bool
  func toNSPredicate() -> NSPredicate {
    NSPredicate { object, _ in (object as? XCUIElement)?.enabled == self.enabled }
  }
}
struct XCUIElementSnapshot { let label: String }
struct IOSNativeView {
  let label: String
  let bundleId: String
  static func fromXCUIElement(_ element: XCUIElement, _ bundleId: String) -> IOSNativeView {
    guard !element.indexInvalidated else { fatalError("LIVE_INDEX_COLLECTION_INVALIDATED") }
    return IOSNativeView(label: element.label, bundleId: bundleId)
  }
}
final class XCUIElement {
  let label: String
  let enabled: Bool
  var indexInvalidated = false
  var failSnapshot = false
  var snapshots = 0
  init(_ label: String, enabled: Bool = true) { self.label = label; self.enabled = enabled }
  func snapshot() throws -> XCUIElementSnapshot {
    snapshots += 1
    if failSnapshot { throw Failure.disappeared }
    return XCUIElementSnapshot(label: label)
  }
}
final class Query {
  let elements: [XCUIElement]
  init(_ elements: [XCUIElement]) { self.elements = elements }
  func matching(_ predicate: NSPredicate) -> Query {
    Query(elements.filter { predicate.evaluate(with: $0) })
  }
  var allElementsBoundByIndex: [XCUIElement] {
    for element in elements { element.indexInvalidated = true }
    return elements
  }
  var allElementsBoundByAccessibilityElement: [XCUIElement] { elements }
}
final class Application {
  let elements: [XCUIElement]
  init(_ elements: [XCUIElement]) { self.elements = elements }
  func descendants(matching: ElementType) -> Query { Query(elements) }
}
final class Automator {
  let apps: [String: Application]
  init(_ apps: [String: Application]) { self.apps = apps }
  func getApp(withBundleId id: String) throws -> Application {
    guard let app = apps[id] else { throw Failure.unavailableApp }
    return app
  }
  func createLogMessage(element: String, from: IOSSelector) -> String { element }
  func runAction<T>(_ log: String, block: () throws -> T) rethrows -> T { try block() }
  // INSERT_QUERY
}
extension IOSNativeView {
  // INSERT_CONVERTER
}
func require(_ value: @autoclosure () -> Bool) { precondition(value()) }
let first = XCUIElement("first")
let second = XCUIElement("second")
let disabled = XCUIElement("disabled", enabled: false)
let apps = ["springboard": Application([first, disabled, second]),
            "empty": Application([]),
            "other": Application([XCUIElement("unrelated")])]
let automator = Automator(apps)
let views = try automator.getNativeViews(on: IOSSelector(enabled: true), inApp: "springboard")
require(views.map { $0.label } == ["first", "second"])
require(views.allSatisfy { $0.bundleId == "springboard" })
require(first.snapshots == 1 && second.snapshots == 1 && disabled.snapshots == 0)
let empty = try automator.getNativeViews(on: IOSSelector(enabled: true), inApp: "empty")
require(empty.isEmpty)
first.failSnapshot = true
func verifyErrors() throws {
  do {
    _ = try automator.getNativeViews(on: IOSSelector(enabled: true), inApp: "springboard")
    fatalError("Missing snapshot error")
  } catch Failure.disappeared {}
  do {
    _ = try automator.getNativeViews(on: IOSSelector(enabled: true), inApp: "missing")
    fatalError("Missing app error")
  } catch Failure.unavailableApp {}
}
try verifyErrors()
print("SWIFT_SNAPSHOT_FIXTURE_PASSED")
