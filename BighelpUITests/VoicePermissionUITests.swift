import XCTest

/// Allowing the microphone and speech recognition for voice must not crash.
/// In 2.3.0 (26) and (27) the system's answer arrived on a background queue in
/// a callback that inherited the main actor, and Swift 6 trapped. Needs a
/// simulator where bighelp hasn't been asked for speech recognition yet.
final class VoicePermissionUITests: BighelpUITestCase {
    @MainActor
    func testAllowingMicrophoneAndSpeechKeepsTheAppRunning() throws {
        let app = makeApp()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                               "-loopdy.voice.conversation-mode", "turnBased"]
        app.launch()
        let voice = app.buttons["chat.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()

        // The microphone prompt, then the speech recognition prompt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
        var answered = 0
        while answered < 2, allow.waitForExistence(timeout: answered == 0 ? 15 : 6) {
            allow.tap()
            answered += 1
            sleep(2)
        }
        XCTAssertGreaterThan(answered, 0, "bighelp asked for voice permissions")
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Allowing voice permissions keeps bighelp running")
    }
}
