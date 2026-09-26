import XCTest

@MainActor
final class NativeClarificationAcceptanceUITests: LoopdyUITestCase {
    private let draft = "Preserve my independent composer draft"
    private let question = "Which release channel should receive this build after the remaining checks have passed?"

    func testSingleInlineChoiceSubmitsDirectlyAndPreservesComposer() {
        let app = launch(single: true)
        let fullQuestion = app.tables["chat.timeline"].staticTexts[question].firstMatch
        XCTAssertTrue(fullQuestion.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            if fullQuestion.isHittable && fullQuestion.frame.minY > 215 { break }
            app.tables["chat.timeline"].swipeDown()
        }
        XCTAssertTrue(fullQuestion.isHittable)
        let choice = choice(app.tables["chat.timeline"], question: 0, index: 1)
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        reveal(choice, in: app)
        XCTAssertTrue(choice.isHittable)
        capture("native-single-full-question", app: app)
        choice.tap()
        let receipt = app.staticTexts["native-clarify-fixture.receipt"]
        XCTAssertTrue(wait { receipt.label == "q0=App Store; submissions=0" })
        XCTAssertFalse(app.buttons["direct-hermes.attention"].exists)
        assertDraft(app)
        capture("native-single-structured-accepted", app: app)
    }

    func testAttentionPopupCompletesBothQuestionsWithCustomAnswer() {
        let app = launch()
        let attention = app.buttons["direct-hermes.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        attention.tap()
        XCTAssertTrue(app.navigationBars["Needs attention"].waitForExistence(timeout: 5))
        // The mounted inline card remains in AX beneath the modal. Restrict
        // interaction to the real List in the foreground attention sheet.
        let sheet = app.collectionViews.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let firstQuestion = sheet.staticTexts[question].firstMatch
        XCTAssertTrue(firstQuestion.exists)
        XCTAssertEqual(firstQuestion.label, question)
        let first = choice(sheet, question: 0, index: 0)
        let second = choice(sheet, question: 0, index: 1)
        let third = choice(sheet, question: 0, index: 2)
        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertNotEqual(second.identifier, third.identifier)
        reveal(second, in: app)
        second.tap()
        XCTAssertTrue(app.navigationBars["Needs attention"].exists, "A batch must not submit its first answer alone")
        let custom = customInput(sheet, question: 1)
        reveal(custom, in: app)
        XCTAssertTrue(custom.isHittable)
        capture("native-attention-full-questions-and-selected-choice", app: app)
        custom.tap()
        custom.typeText("Ship after review")
        XCTAssertTrue(wait { custom.value as? String == "Ship after review" })
        let keyboard = app.keyboards.firstMatch
        for _ in 0..<4 {
            if !keyboard.exists || keyboard.frame.height == 0 || custom.frame.maxY < keyboard.frame.minY { break }
            sheet.swipeUp()
        }
        XCTAssertTrue(custom.isHittable)
        if keyboard.exists && keyboard.frame.height > 0 {
            XCTAssertLessThan(custom.frame.maxY, keyboard.frame.minY)
        }
        capture("native-attention-custom-answer-visible", app: app)
        let done = sheet.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "direct-hermes.clarification.done.")).firstMatch
        reveal(done, in: app)
        XCTAssertTrue(done.isEnabled)
        done.tap()
        let receipt = app.staticTexts["native-clarify-fixture.receipt"]
        XCTAssertTrue(wait { receipt.label == "q0=App Store; q1=Ship after review; submissions=0" })
        XCTAssertTrue(wait { !app.navigationBars["Needs attention"].exists })
        XCTAssertFalse(attention.exists)
        assertDraft(app)
        capture("native-attention-batch-accepted-original-draft", app: app)
    }

    private func launch(single: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-test-native-clarification-ui", "-loopdy.demo.appearance", "light"]
        if single { app.launchArguments.append("-test-native-clarify-single") }
        app.launch()
        return app
    }

    private func choice(_ app: XCUIElement, question: Int, index: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "direct-hermes.clarification.question.\(question).choice.\(index).")).firstMatch
    }

    private func customInput(_ app: XCUIElement, question: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND identifier BEGINSWITH %@",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            "direct-hermes.clarification.question.\(question).custom."
        )).firstMatch
    }

    private func assertDraft(_ app: XCUIApplication) {
        let input = app.textViews.matching(NSPredicate(format: "value == %@", draft)).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "The actual composer must retain its independent draft")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 7) == .completed
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
