import XCTest

final class CameraGestureTests: XCTestCase {
  @MainActor func testPinchAndResetPreservePausedPosition() throws {
    let app = XCUIApplication()
    app.launch()
    let model = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label ENDSWITH %@", " model")).firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 12))
    let pause = app.buttons["Pause"].firstMatch
    if pause.exists { pause.tap() }

    let play = app.buttons["Play"].firstMatch
    XCTAssertTrue(play.waitForExistence(timeout: 3))
    let phase = play.value as? String
    let initial = try XCTUnwrap(model.value as? String)
    XCTAssertTrue(initial.hasSuffix("100 percent zoom"))

    let start = model.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.50))
    let end = model.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.48))
    start.press(forDuration: 0.08, thenDragTo: end)
    XCTAssertNotEqual(model.value as? String, initial, "Dragging should orbit the model")
    XCTAssertTrue(try XCTUnwrap(model.value as? String).hasSuffix("100 percent zoom"))

    model.pinch(withScale: 1.55, velocity: 1)
    let zoomed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "NOT (value ENDSWITH %@)", "100 percent zoom"), object: model)
    XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
    let value = try XCTUnwrap(model.value as? String)
    let percent = try XCTUnwrap(
      value.components(separatedBy: ", ").last?.split(separator: " ").first.flatMap { Int($0) })
    XCTAssertGreaterThan(percent, 110)
    let zoomedImage = XCTAttachment(screenshot: app.screenshot())
    zoomedImage.name = "Zoomed and orbited"
    zoomedImage.lifetime = .keepAlways
    add(zoomedImage)

    let reset = app.buttons["studio.resetView"]
    XCTAssertTrue(reset.isHittable)
    reset.tap()
    XCTAssertEqual(model.value as? String, initial)
    XCTAssertTrue(play.exists)
    XCTAssertEqual(play.value as? String, phase)
    let resetImage = XCTAttachment(screenshot: app.screenshot())
    resetImage.name = "Reset at the same position"
    resetImage.lifetime = .keepAlways
    add(resetImage)
  }
}
