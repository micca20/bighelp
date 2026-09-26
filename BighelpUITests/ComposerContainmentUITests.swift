import XCTest

/// The draft must stay inside the visible rounded field: the first glyph clears
/// the leading curve, and wrapped or scrolled text never paints beyond it.
final class ComposerContainmentUITests: BighelpUITestCase {
    @MainActor
    func testDraftTextStaysInsideTheVisibleFieldAtEveryLength() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "dark"
        ]
        app.launch()

        let input = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        let field = app.otherElements["chat.composer.field"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        attach(app, "composer-empty")

        // The native text origin must sit inside the field by at least the
        // capsule's leading clearance so the first glyph is never cut.
        XCTAssertGreaterThanOrEqual(input.frame.minX - field.frame.minX, 14,
                                    "Draft text begins inside the leading curve: input=\(input.frame) field=\(field.frame)")

        input.tap()
        input.typeText("Short draft")
        attach(app, "composer-one-line")
        assertContained(input, in: field)

        input.typeText(" that keeps going so it wraps across several lines of the composer and then keeps going well past the four line cap to force internal scrolling inside the native editor.")
        attach(app, "composer-long")
        assertContained(input, in: field)
    }

    private func assertContained(_ input: XCUIElement, in field: XCUIElement,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let inner = field.frame.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertTrue(inner.contains(input.frame),
                      "Editor escapes the visible field: input=\(input.frame) field=\(field.frame)",
                      file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
