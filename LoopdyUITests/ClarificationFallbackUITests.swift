import XCTest

@MainActor
final class ClarificationFallbackUITests: LoopdyUITestCase {
    func testExpiredCardCannotSubmitAStaleAnswer() throws {
        let app = launch(extra: ["-test-clarification-expired"])
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["TestFlight"].exists)
        XCTAssertFalse(app.buttons["Send custom response"].exists)
    }

    func testCurrentCardChoiceFallsBackToChatText() throws {
        let app = launch(extra: [])
        let choice = app.buttons["TestFlight"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.isEnabled)
        capture("Expired clarification still answerable", app: app)
        choice.tap()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply to clarification:")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.label.contains("TestFlight"))
        XCTAssertFalse(choice.exists)
        capture("Expired clarification delivered as text", app: app)
    }

    func testFailedTextFallbackRetainsCustomInputForRetry() throws {
        let app = launch(extra: ["-test-clarification-failure"])
        let input = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label == %@",
            XCUIElement.ElementType.textField.rawValue,
            XCUIElement.ElementType.textView.rawValue,
            "Type another response"
        )).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Keep this custom answer")
        let send = app.buttons["Send custom response"]
        send.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "could not be sent")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this custom answer")
        capture("Both paths failed and answer retained", app: app)
        send.tap()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply to clarification:")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.label.contains("Keep this custom answer"))
        XCTAssertFalse(input.exists)
        capture("Custom answer delivered on retry", app: app)
    }

    private func launch(extra: [String]) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-clarification-fallback", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"] + extra
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
