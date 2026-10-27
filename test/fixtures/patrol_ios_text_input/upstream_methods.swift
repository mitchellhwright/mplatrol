    func enterText(
      _ data: String,
      on selector: IOSSelector,
      inApp bundleId: String,
      dismissKeyboard: Bool,
      withTimeout timeout: TimeInterval?,
      dx: CGFloat,
      dy: CGFloat
    ) throws {
      var data = data
      if dismissKeyboard {
        data = "\(data)\n"
      }

      var view = createLogMessage(element: "text field", from: selector)
      view += " in app \(bundleId)"

      try runAction("entering text \(format: data) into \(view)") {
        let app = try self.getApp(withBundleId: bundleId)

        // elementType must be specified as integer
        // See:
        // * https://developer.apple.com/documentation/xctest/xcuielementtype/xcuielementtypetextfield
        // * https://developer.apple.com/documentation/xctest/xcuielementtype/xcuielementtypesecuretextfield
        let textFieldPredicate = NSPredicate(format: "elementType == 49")
        let secureTextFieldPredicate = NSPredicate(format: "elementType == 50")

        var subpredicates: [NSPredicate] = [
          NSCompoundPredicate(orPredicateWithSubpredicates: [
            textFieldPredicate, secureTextFieldPredicate,
          ])
        ]

        // toTextFieldNSPredicate() can be nil - depending on the selector user provided
        if let contentPredicate = selector.toTextFieldNSPredicate() {
          subpredicates.insert(contentPredicate, at: 0)
        }

        let finalPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)

        let query = app.descendants(matching: .any).matching(finalPredicate)
        guard
          let element = self.waitFor(
            query: query,
            index: selector.instance ?? 0,
            timeout: timeout ?? self.timeout
          )
        else {
          throw PatrolError.viewNotExists(view)
        }

        self.clearAndEnterText(data: data, element: element, dx: dx, dy: dy)
      }

      // Prevent keyboard dismissal from happening too fast
      sleepTask(timeInSeconds: 1)
    }

    func enterText(
      _ data: String,
      byIndex index: Int,
      inApp bundleId: String,
      dismissKeyboard: Bool,
      withTimeout timeout: TimeInterval?,
      dx: CGFloat,
      dy: CGFloat
    ) throws {
      var data = data
      if dismissKeyboard {
        data = "\(data)\n"
      }

      try runAction("entering text \(format: data) by index \(index) in app \(bundleId)") {
        let app = try self.getApp(withBundleId: bundleId)

        // elementType must be specified as integer
        // See:
        // * https://developer.apple.com/documentation/xctest/xcuielementtype/xcuielementtypetextfield
        // * https://developer.apple.com/documentation/xctest/xcuielementtype/xcuielementtypesecuretextfield
        let textFieldPredicate = NSPredicate(format: "elementType == 49")
        let secureTextFieldPredicate = NSPredicate(format: "elementType == 50")
        let predicate = NSCompoundPredicate(
          orPredicateWithSubpredicates: [textFieldPredicate, secureTextFieldPredicate]
        )

        let textFieldsQuery = app.descendants(matching: .any).matching(predicate)
        guard
          let element = self.waitFor(
            query: textFieldsQuery,
            index: index,
            timeout: timeout ?? self.timeout
          )
        else {
          throw PatrolError.viewNotExists("text field at index \(index) in app \(bundleId)")
        }

        self.clearAndEnterText(data: data, element: element, dx: dx, dy: dy)
      }

      // Prevent keyboard dismissal from happening too fast
      sleepTask(timeInSeconds: 1)
    }

    private func clearAndEnterText(data: String, element: XCUIElement, dx: CGFloat, dy: CGFloat) {
      let currentValue = element.value as? String
      var delete: String = ""
      if let value = currentValue {
        delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
      }

      // We need to tap at the end of the field to ensure the cursor is at the end
      let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
      coordinate.tap()

      element.typeText(delete + data)
    }

