    func getNativeViews(
      on selector: IOSSelector,
      inApp bundleId: String
    ) throws -> [IOSNativeView] {
      let view = createLogMessage(element: "views", from: selector)
      return try runAction("getting native \(view)") {
        let app = try self.getApp(withBundleId: bundleId)

        // TODO: We should consider more view properties. See #1554
        let query = app.descendants(matching: .any).matching(selector.toNSPredicate())
        let elements = query.allElementsBoundByIndex

        let views = elements.map { xcuielement in
          return IOSNativeView.fromXCUIElement(xcuielement, bundleId)
        }

        return views
      }
    }

    static func fromXCUIElementSnapshot(_ xcuielement: XCUIElementSnapshot, _ bundleId: String)
      -> IOSNativeView {
      IOSNativeView(label: xcuielement.label, bundleId: bundleId)
    }
