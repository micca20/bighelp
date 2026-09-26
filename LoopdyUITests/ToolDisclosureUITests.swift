import XCTest

final class ToolDisclosureUITests: LoopdyUITestCase {
    @MainActor
    func testCompletedFoldsKeepClarificationAndVerifierContextVisible() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-chat-sidebar-collapsed", "-test-completed-turn-context", "-test-clarification-fallback",
                               "-loopdy.chat.foldCompletedTurns", "YES", "-loopdy.demo.appearance", "light"]
        app.launch()
        let timeline = app.tables["chat.timeline"]
        let fold = app.buttons["Worked for 10s"]
        let continuation = app.buttons["More completed work"]
        func message(_ text: String) -> XCUIElement {
            app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        }
        let context = message("TestFlight keeps this build private")
        let answer = message("The compatibility flag must stay enabled")
        let final = message("Verification confirmed")
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        XCTAssertTrue(answer.exists)
        XCTAssertTrue(final.exists)
        XCTAssertTrue(app.buttons["TestFlight"].exists, "The real pending clarification remains answerable")
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertEqual(continuation.value as? String, "Collapsed")
        // Offscreen iPhone text views can report infinite AX frames. Measure
        // order only when the full fixture fits; prove phone reachability by scrolling.
        if app.frame.width > 700 {
            XCTAssertLessThan(context.frame.minY, answer.frame.minY)
            XCTAssertLessThan(answer.frame.minY, continuation.frame.minY)
            XCTAssertLessThan(continuation.frame.minY, final.frame.minY)
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<5 where !element.isHittable { timeline.swipeDown() }
            XCTAssertTrue(element.isHittable)
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        reveal(context)
        capture("completed-fold-context-and-clarification")
        reveal(fold)
        fold.tap()
        XCTAssertEqual(fold.value as? String, "Expanded")
        XCTAssertEqual(continuation.value as? String, "Collapsed")
        XCTAssertTrue(context.exists)
        capture("completed-fold-expanded-in-place")
        fold.tap()
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertTrue(answer.exists)
        for _ in 0..<5 where !answer.isHittable { timeline.swipeUp() }
        XCTAssertTrue(answer.isHittable)
        capture("completed-fold-substantive-answer")
        for _ in 0..<5 where !final.isHittable { timeline.swipeUp() }
        XCTAssertTrue(final.isHittable)
        capture("completed-fold-verification-followup")
        app.terminate()
        app.launch()
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        XCTAssertTrue(answer.exists)
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertEqual(continuation.value as? String, "Collapsed")
        capture("completed-fold-reopened")
    }

    @MainActor
    func testOpenedToolSurvivesEnclosingWorkTrailRecreation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-chat-sidebar-collapsed", "-test-tool-disclosure-scroll", "-loopdy.chat.foldCompletedTurns", "NO"]
        app.launch()
        let trail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")).firstMatch
        XCTAssertTrue(app.tables["chat.timeline"].waitForExistence(timeout: 5))
        func revealAndTap(_ element: XCUIElement) {
            for _ in 0..<8 where !element.isHittable {
                app.tables["chat.timeline"].swipeDown()
            }
            element.tap()
        }
        revealAndTap(trail)
        let tool = app.buttons["chat.activity.v3-sample-tool-0"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tool.tap()
        XCTAssertEqual(tool.value as? String, "Expanded")
        let timeline = app.tables["chat.timeline"]
        for _ in 0..<4 where tool.isHittable { timeline.swipeUp(velocity: .fast) }
        XCTAssertFalse(tool.isHittable, "Move the expanded tool out of the native table's visible cells.")
        for _ in 0..<8 where !tool.isHittable { timeline.swipeDown(velocity: .fast) }
        XCTAssertTrue(tool.isHittable)
        XCTAssertEqual(tool.value as? String, "Expanded", "Cell recycling must retain the reader's tool disclosure choice.")
        revealAndTap(trail)
        XCTAssertEqual(trail.value as? String, "Collapsed")
        revealAndTap(trail)
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertEqual(tool.value as? String, "Expanded", "Recreating the visible work trail must not discard the reader's tool disclosure choice")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "retained-tool-disclosure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tool.tap()
        XCTAssertEqual(tool.value as? String, "Collapsed")
        revealAndTap(trail)
        revealAndTap(trail)
        XCTAssertEqual(tool.value as? String, "Collapsed", "Explicit close must also persist")
    }
}
