import XCTest

/// Interim agent messages and thinking read quieter than the answer.
/// Set BIGHELP_THINKING_STYLE_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class ChatThinkingStyleUITests: BighelpUITestCase {
    @MainActor
    func testInterimMessagesAndThinkingAreQuieterThanTheAnswer() throws {
        XCUIDevice.shared.orientation = .portrait
        for fold in ["NO", "YES"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-thinking-style",
                                   "-loopdy.chat.foldCompletedTurns", fold, "-loopdy.demo.appearance", "light"]
            app.launch()
            func message(_ text: String) -> XCUIElement {
                app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
            }
            let interim = message("Let me pull up your budget file")
            let answer = message("You're on track")
            XCTAssertTrue(interim.waitForExistence(timeout: 10))
            XCTAssertTrue(answer.exists)
            // The answer keeps its full-size text; the interim message is smaller.
            XCTAssertLessThan(interim.frame.height, answer.frame.height)
            let thinking = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Thinking")).firstMatch
            XCTAssertTrue(thinking.exists)
            save("thinking-style-fold-\(fold)", app)
            app.tables["chat.timeline"].swipeDown()
            save("thinking-style-fold-\(fold)-top", app)
            if fold == "YES" {
                // One fold for the whole turn, even with interim messages between the work.
                XCTAssertFalse(app.buttons["More completed work"].exists)
                let worked = app.buttons["Worked for 12s"]
                XCTAssertTrue(worked.waitForExistence(timeout: 5))
                worked.tap()
                save("thinking-style-fold-expanded", app)
            }
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_THINKING_STYLE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
