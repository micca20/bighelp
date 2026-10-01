import XCTest

/// Answering a card sends the answer to the agent as the person's next
/// message, and whatever they were typing stays in the composer.
/// Set BIGHELP_CARD_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class CardRepliesUITests: BighelpUITestCase {
    @MainActor
    func testPickingAnOptionAndSendingAFormReachTheAgent() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-card-replies", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()

        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Hold this thought")
        app.swipeDown(velocity: .fast)

        // The chat opens at the bottom; the selection card is above the form.
        let mountains = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "The mountains")).firstMatch
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        for _ in 0..<5 where !(mountains.exists && mountains.isHittable) {
            (timeline.exists ? timeline : app).swipeDown()
        }
        XCTAssertTrue(mountains.waitForExistence(timeout: 5))
        mountains.tap()
        let send = app.buttons["chat.generative-ui.selection.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.generative-ui.selection.sent"].waitForExistence(timeout: 5))
        let pick = app.textViews.matching(NSPredicate(format: "value == %@", "Let's go to the mountains.")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "The pick is the person's next message")
        XCTAssertEqual(editor.value as? String, "Hold this thought", "The draft stays in the composer")
        save("selection-sent", app)

        let openForm = app.buttons["chat.generative-ui.form.open"]
        for _ in 0..<4 where !openForm.isHittable { app.swipeUp() }
        openForm.tap()
        let pace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose")).firstMatch
        XCTAssertTrue(pace.waitForExistence(timeout: 5))
        pace.tap()
        app.buttons["Slow and easy"].firstMatch.tap()
        let sendForm = app.buttons["chat.generative-ui.form.send"]
        for _ in 0..<4 where !(sendForm.exists && sendForm.isHittable) { app.swipeUp() }
        sendForm.tap()

        let answers = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "My answers to “Trip details”")).firstMatch
        XCTAssertTrue(answers.waitForExistence(timeout: 5))
        let text = answers.value as? String ?? ""
        XCTAssertTrue(text.contains("Travelers: 2"), text)
        XCTAssertTrue(text.contains("Pace: Slow and easy"), text)
        XCTAssertEqual(editor.value as? String, "Hold this thought")
        save("form-sent", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["BIGHELP_CARD_EVIDENCE"] != nil else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "card-replies-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
