import XCTest

/// Hands-free (TTS) voice waits for a real pause before sending; while you're
/// talking, Send now sends what you've said without waiting.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class VoiceSendNowUITests: BighelpUITestCase {
    @MainActor
    func testSendNowSendsASentenceInProgress() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                                   "-test-voice-partial", "-loopdy.voice.conversation-mode", "turnBased",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let voice = app.buttons["chat.voice"]
            XCTAssertTrue(voice.waitForExistence(timeout: 10))
            voice.tap()
            // Installing the test build clears voice permissions: allow them.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
            for _ in 0..<2 where allow.waitForExistence(timeout: 4) { allow.tap() }

            let caption = app.staticTexts["voice.caption"]
            XCTAssertTrue(caption.waitForExistence(timeout: 8))
            let sendNow = app.buttons["voice.send-now"]
            XCTAssertTrue(sendNow.waitForExistence(timeout: 5), "Send now appears while you're talking")
            XCTAssertTrue(caption.label.contains("trip to Denver next month and"), caption.label)
            evidence("talking-\(appearance)", app)

            sendNow.tap()
            // The whole sentence went out as one turn (the demo agent has no reply to give).
            let toggle = app.buttons["voice.transcript.toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.tap()
            let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                              "I'd love ideas for day trips.")).firstMatch
            XCTAssertTrue(sent.waitForExistence(timeout: 5), "The turn carries everything said, not half of it")
            evidence("sent-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func evidence(_ label: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "voice-send-now-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("voice-send-now-\(label).png"))
    }
}
