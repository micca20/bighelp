import XCTest

/// Interim agent messages and thinking read quieter than the answer.
/// Set BIGHELP_THINKING_STYLE_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class ChatThinkingStyleUITests: BighelpUITestCase {
    @MainActor
    func testInterimMessagesAndThinkingAreQuieterThanTheAnswer() throws {
        try checkThinkingStyle(hidingToolCalls: false)
    }

    /// With tool calls hidden, thinking alone still marks the work: interim
    /// messages stay quiet and the finished turn still folds.
    @MainActor
    func testThinkingStyleAndFoldWithToolCallsHidden() throws {
        try checkThinkingStyle(hidingToolCalls: true)
    }

    @MainActor
    private func checkThinkingStyle(hidingToolCalls: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let variant = hidingToolCalls ? "-no-tools" : ""
        for fold in ["NO", "YES"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-thinking-style",
                                   "-loopdy.chat.foldCompletedTurns", fold, "-loopdy.demo.appearance", "light"]
                + (hidingToolCalls ? ["-test-hide-tool-calls"] : [])
            app.launch()
            func message(_ text: String) -> XCUIElement {
                app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
            }
            let interim = message("Let me pull up your budget file")
            let answer = message("You're on track")
            XCTAssertTrue(answer.waitForExistence(timeout: 10))
            let worked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked for 12s")).firstMatch
            if hidingToolCalls, fold == "YES" {
                // The notes are the thought process here, so they fold with it.
                app.tables["chat.timeline"].swipeDown()
                XCTAssertTrue(worked.waitForExistence(timeout: 5))
                XCTAssertFalse(interim.exists)
                save("thinking-style\(variant)-fold-\(fold)", app)
                worked.tap()
            }
            XCTAssertTrue(interim.waitForExistence(timeout: 5))
            // The answer keeps its full-size text; the interim message is smaller.
            XCTAssertLessThan(interim.frame.height, answer.frame.height)
            // "Thinking" while it runs, "Thought for 4s" once it's done.
            let thinking = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Thinking", "Thought")).firstMatch
            XCTAssertTrue(thinking.exists)
            if hidingToolCalls, fold == "YES" {
                save("thinking-style\(variant)-fold-expanded", app)
            } else {
                save("thinking-style\(variant)-fold-\(fold)", app)
                app.tables["chat.timeline"].swipeDown()
                save("thinking-style\(variant)-fold-\(fold)-top", app)
                if fold == "YES" {
                    // One fold for the whole turn, even with interim messages between the work.
                    XCTAssertFalse(app.buttons["More completed work"].exists)
                    XCTAssertTrue(worked.waitForExistence(timeout: 5))
                    worked.tap()
                    save("thinking-style\(variant)-fold-expanded", app)
                }
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
