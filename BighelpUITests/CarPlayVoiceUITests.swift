import XCTest

/// CarPlay's hands-free voice chat on the demo data: it starts a new chat
/// with the default agent and listens, mutes, ends, and starts again.
/// (The simulator's CarPlay window itself can't be opened from a test.)
final class CarPlayVoiceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTalkListensMutesAndEnds() {
        let app = XCUIApplication()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-carplay-session",
                               "-loopdy.voice.conversation-mode", "turnBased"]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        let phase = app.staticTexts["carplay.phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 15))

        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "It connects and listens: \(phase.label)")
        XCTAssertNotEqual(app.staticTexts["carplay.agent"].label, "your agent", "It talks to the default agent")

        app.buttons["carplay.mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5), "Mute holds the microphone")
        app.buttons["carplay.mute"].tap()

        app.buttons["carplay.end"].tap()
        XCTAssertTrue(wait(for: phase, label: "paused"), "End stops listening: \(phase.label)")

        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "Talk starts again: \(phase.label)")
    }

    @MainActor
    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
