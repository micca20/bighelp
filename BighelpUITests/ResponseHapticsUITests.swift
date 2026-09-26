import XCTest

final class ResponseHapticsUITests: BighelpUITestCase {
    @MainActor
    func testResponseHapticsTogglePersistsAcrossRelaunch() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openChatSettings(app)
        let toggle = app.switches["settings.chat.response-haptics"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        guard toggle.exists else { return }
        // Restore the starting preference so this test is repeatable.
        let original = toggle.value as? String
        let changed = original == "1" ? "0" : "1"
        // SwiftUI exposes the labelled row as the switch's accessibility frame.
        // Tap its trailing native switch, not the center of the multiline label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, changed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Response haptics in Chat and Voice"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        openChatSettings(app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, changed)
        // SwiftUI exposes the labelled row as the switch's accessibility frame.
        // Tap its trailing native switch, not the center of the multiline label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, original)
    }

    @MainActor
    private func openChatSettings(_ app: XCUIApplication) {
        openSettings(in: app)
        let chat = app.buttons["settings.menu.chat"]
        for _ in 0..<4 where !chat.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(chat.waitForExistence(timeout: 3))
        XCTAssertTrue(chat.isHittable)
        chat.tap()
        XCTAssertTrue(app.navigationBars["Chat & Voice"].waitForExistence(timeout: 3))
    }
}
