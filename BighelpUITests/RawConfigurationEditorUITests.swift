import XCTest

/// Settings › System › Raw Configuration on the demo host: edits stay a draft
/// until Save, leaving with a draft asks first, and the full editor has Find and
/// Replace. Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class RawConfigurationEditorUITests: BighelpUITestCase {
    @MainActor
    func testDraftStaysUntilSaveAndLeavingAsksFirst() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-system-page",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let link = app.buttons["Raw Configuration"]
            for _ in 0..<6 where !link.isHittable { app.swipeUp() }
            link.tap()

            let editor = app.textViews["host.raw-config.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 8))
            XCTAssertTrue((editor.value as? String)?.contains("max_turns: 60") == true)
            let save = app.buttons["host.raw-config.save"]
            XCTAssertTrue(save.exists)
            XCTAssertFalse(save.isEnabled, "Nothing to save before an edit")

            // The full editor has Find and Replace, and its edits are the screen's draft.
            app.buttons["host.raw-config.expand"].tap()
            let expanded = app.textViews["host.raw-config.expanded-editor"]
            XCTAssertTrue(expanded.waitForExistence(timeout: 5))
            expanded.tap()
            expanded.typeText("# draft\n")
            app.buttons["host.raw-config.find-menu"].tap()
            app.buttons["Find and Replace"].tap()
            let replaceField = app.textFields["find.replaceField"]
            XCTAssertTrue(replaceField.waitForExistence(timeout: 5), "The Find and Replace bar opens")
            app.typeText("180")
            replaceField.tap()
            replaceField.typeText("300")
            evidence("find-replace-\(appearance)", app)
            let replace = app.buttons["Replace"].firstMatch
            XCTAssertTrue(replace.exists)
            replace.tap()
            XCTAssertTrue((expanded.value as? String)?.contains("timeout: 300") == true, "Replace changed the draft")
            app.buttons["host.raw-config.expanded-done"].tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertTrue((editor.value as? String)?.contains("timeout: 300") == true, "The draft came back")
            XCTAssertTrue((editor.value as? String)?.contains("# draft") == true)
            XCTAssertTrue(save.isEnabled, "An edit can be saved")
            evidence("draft-\(appearance)", app)

            // Back with a draft warns, and Keep Editing keeps it.
            app.buttons["host.raw-config.back"].tap()
            XCTAssertTrue(app.alerts["Discard your changes?"].waitForExistence(timeout: 3))
            evidence("leave-warning-\(appearance)", app)
            app.alerts.buttons["Keep Editing"].tap()
            XCTAssertTrue((editor.value as? String)?.contains("# draft") == true)

            // Save shows the changes, then writes them.
            save.tap()
            let review = app.navigationBars["Review Raw Configuration"]
            XCTAssertTrue(review.waitForExistence(timeout: 5))
            evidence("review-\(appearance)", app)
            review.buttons["Save"].tap()
            XCTAssertTrue(review.waitForNonExistence(timeout: 8))
            XCTAssertFalse(save.isEnabled, "Saved: nothing left to save")
            XCTAssertFalse(app.buttons["host.raw-config.back"].exists, "Saved: the normal Back button is back")
            evidence("saved-\(appearance)", app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertFalse(app.alerts["Discard your changes?"].waitForExistence(timeout: 2),
                           "Leaving with nothing unsaved doesn't ask")
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "raw-config-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("raw-config-\(name).png"))
    }
}
