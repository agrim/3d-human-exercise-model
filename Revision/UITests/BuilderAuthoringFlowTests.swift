import XCTest

/// Author a real draft through the movement picker and hand it to the system Files exporter.
final class BuilderAuthoringFlowTests: XCTestCase {
  @MainActor func testAuthorTwoStepsAndPreparePortableExport() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    func tap(_ button: XCUIElement) {
      for _ in 0..<4 where !button.exists || !button.isHittable { app.swipeUp() }
      XCTAssertTrue(button.isHittable, app.debugDescription)
      button.tap()
    }
    func capture(_ name: String) {
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTAssertTrue(app.buttons["Exercises"].waitForExistence(timeout: 15))
    app.buttons["Exercises"].tap()
    tap(app.buttons["eml.create"])
    let title = app.textFields["builder.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Standing Elbow Bend")
    for (index, label) in ["Bend", "Return"].enumerated() {
      tap(app.buttons["builder.addStep"])
      let name = app.textFields["builder.stepName"]
      XCTAssertTrue(name.waitForExistence(timeout: 5))
      name.tap()
      name.typeKey("a", modifierFlags: .command)
      name.typeText(label)
      if index == 0 {
        tap(app.buttons["builder.addMovement"])
        tap(app.buttons["builder.choice.bend-elbows"])
      }
      tap(app.buttons["builder.finishStep"])
    }
    capture("Two authored steps")
    tap(app.buttons["builder.export"])
    // Files runs out of process; on a newly booted device its provider may launch after
    // the exporter animation finishes. Identify the system action in either AX form.
    let save = app.buttons.matching(NSPredicate(
      format: "identifier == %@ OR label == %@", "DOCPicker.actionButton", "Save"
    )).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 35), app.debugDescription)
    capture("Portable EML export")
    // The system owns this sheet. Leave the destination choice to its user.
    app.terminate()
  }
}
