import XCTest

final class LiveVoiceUITests: LoopdyUITestCase {
    @MainActor
    func testLiveVoiceOpensWithoutStartingMicrophoneOrShowingConfiguration() {
        let app=makeApp()
        app.launchArguments = ["-use-demo-fixtures","-disable-demo-delays","-start-chat","-test-live-voice"]
        app.launch()
        // The fixture enters the normal voice presentation from an existing chat.
        let voice=app.buttons["chat.voice"]
        if voice.waitForExistence(timeout:5) { voice.tap() }
        XCTAssertTrue(app.buttons["live-voice.start"].waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["live-voice.provider"].exists)
        XCTAssertFalse(app.buttons["live-voice.voice"].exists)
        XCTAssertFalse(app.buttons["live-voice.fallback"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["live-voice.captions"].exists)
        XCTAssertFalse(app.buttons["live-voice.end"].exists)
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        capture.name="Live-voice-subscription-ready";capture.lifetime = .keepAlways;add(capture)
    }

    /// A failed start must leave a way forward on the same screen: Start comes
    /// back as Try again, and turn-based voice is one tap away.
    @MainActor
    func testFailedLiveVoiceOffersRetryAndTurnBased() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-test-live-voice"]
        app.launch()
        let voice = app.buttons["chat.voice"]
        if voice.waitForExistence(timeout: 5) { voice.tap() }
        let start = app.buttons["live-voice.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-voice.error"].waitForExistence(timeout: 8))
        let retryReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND label == 'Try again'"), object: start
        )
        XCTAssertEqual(XCTWaiter.wait(for: [retryReady], timeout: 8), .completed, "Try again must be available.")
        XCTAssertTrue(app.buttons["live-voice.use-turn-based"].exists)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Live-voice-failed"; capture.lifetime = .keepAlways; add(capture)
    }
}
