import XCTest

final class HomeWorkUITests: XCTestCase {
    @MainActor
    func testWorkStatusReplacesInPlaceAndClarifyAnswerReturnsItsSession() {
        let app = launchHome()
        let owner = app.buttons.matching(NSPredicate(format: "label == %@", "Choose a release channel")).firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        XCTAssertTrue(owner.label.contains("Choose a release channel"))
        XCTAssertFalse(workRow(app, title: "Choose a release channel").exists)
        reveal(owner, in: app)
        capture(app, "home-needs-you-session")

        let working = workRow(app, title: "Improve the Home screen")
        reveal(working, in: app)
        XCTAssertTrue(working.exists)
        let originalID = working.identifier
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            working.label.contains("Calling subagents")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
        XCTAssertEqual(working.identifier, originalID)
        XCTAssertEqual(app.buttons.matching(identifier: originalID).count, 1)
        XCTAssertFalse(working.label.contains("Private implementation detail"))
        capture(app, "home-work-in-flight-status")

        let choice = app.buttons.matching(NSPredicate(format: "label == %@", "TestFlight")).firstMatch
        reveal(choice, in: app, directionUp: false)
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        let resumed = workRow(app, title: "Choose a release channel")
        XCTAssertTrue(resumed.waitForExistence(timeout: 5))
        XCTAssertFalse(owner.exists)
        reveal(resumed, in: app)
        capture(app, "home-clarify-resumed")

        for title in ["Plan the next release", "Morning briefing", "Review accessibility"] {
            let text = app.staticTexts[title].firstMatch
            reveal(text, in: app)
            XCTAssertTrue(text.exists, "Missing completion title: \(title)")
            XCTAssertTrue(text.isHittable, "Completion must be reachable: \(title)")
        }
        capture(app, "home-recent-completion-titles")
        reveal(working, in: app, directionUp: false)
        working.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Original Home improvement conversation")).firstMatch.waitForExistence(timeout: 8))
        capture(app, "home-work-original-session")
    }

    @MainActor
    func testClarifySessionTitleOpensItsOriginalConversation() {
        let app = launchHome()
        let owner = app.buttons.matching(NSPredicate(format: "label == %@", "Choose a release channel")).firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        reveal(owner, in: app)
        owner.tap()
        let originalContext = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Original release conversation")).firstMatch
        XCTAssertTrue(originalContext.waitForExistence(timeout: 8))
        capture(app, "home-clarify-original-session")
    }

    @MainActor
    func testClarifyExpiryReturnsSessionWhileHomeStaysOpen() {
        let app = launchHome(extra: ["-test-home-work-expiry"])
        let owner = app.buttons.matching(NSPredicate(format: "label == %@", "Choose a release channel")).firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        let resumed = workRow(app, title: "Choose a release channel")
        XCTAssertFalse(resumed.exists)
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !owner.exists && resumed.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 30), .completed)
        reveal(resumed, in: app)
        capture(app, "home-clarify-expired")
    }

    @MainActor
    private func launchHome(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-home-work"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func workRow(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "dashboard.work.row.", title)).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, directionUp: Bool = true) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            if directionUp { app.swipeUp() } else { app.swipeDown() }
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
