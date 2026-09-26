import XCTest

final class ScratchpadExportUITests: BighelpUITestCase {
    @MainActor
    func testNativeMarkdownExport() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-enable-project-changes", "-use-project-changes-markdown-fixture", "-start-chat", "-preview-ui-v3", "-test-chat-sidebar-collapsed"]
        app.launch()
        let changes = app.buttons["chat.session-status.changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()
        let open = app.buttons["project-changes.scratchpad"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let mode = app.buttons["scratchpad.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        if mode.label == "Markdown" { mode.tap() }
        let editor = app.textViews["Scratchpad"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let source = "Scratchpad export verification\nSecond line.\n"
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        app.buttons["scratchpad.actions"].tap()
        app.buttons["scratchpad.export-copy"].tap()
        let dialog = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dialog.name = "native-markdown-export"
        dialog.lifetime = .keepAlways
        add(dialog)
        print("EXPORT_UI_BEGIN\n\(app.debugDescription)\nEXPORT_UI_END")
        // The underlying Scratchpad toolbar also has a Save button. Waiting
        // for that button can accidentally tap it twice without ever opening
        // the system exporter, so require the distinct native export action.
        let save = app.navigationBars.buttons.matching(NSPredicate(
            format: "label IN %@ AND identifier != %@", ["Save", "Export", "Move"], "scratchpad.save"
        )).firstMatch
        let exporterIsPresented = save.waitForExistence(timeout: 5)
        if !exporterIsPresented { captureFailure(app, checkpoint: "exporter-missing") }
        XCTAssertTrue(exporterIsPresented, "Native Files exporter must offer its own save action")
        guard exporterIsPresented else { return }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let replace = app.buttons["Replace"]
        if replace.waitForExistence(timeout: 1) { replace.tap() }
        let exported = save.waitForNonExistence(timeout: 5)
        if !exported { captureFailure(app, checkpoint: "export-incomplete") }
        XCTAssertTrue(exported)
        XCTAssertTrue(app.buttons["scratchpad.send-to-agent"].exists)
    }

    @MainActor
    func testSaveToWikiWithoutHostKeepsDraftAndDoesNotClaimSuccess() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-chat-sidebar-collapsed"]
        app.launch()
        let menu = app.buttons["quick-workspace.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["quick-workspace.menu.scratchpad"].tap()
        let editor = app.textViews["Scratchpad"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Keep this draft")
        let draft = editor.value as? String
        app.buttons["scratchpad.save"].tap()
        XCTAssertTrue(app.navigationBars["Save to Wiki"].waitForExistence(timeout: 5))
        let save = app.buttons["wiki.create.save"]
        if save.exists { XCTAssertFalse(save.isEnabled) }
        XCTAssertFalse(app.buttons["wiki.create.continue"].exists)
        app.navigationBars["Save to Wiki"].buttons["Close"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
    }

    @MainActor
    private func captureFailure(_ app: XCUIApplication, checkpoint: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = checkpoint + "-hierarchy"
        hierarchy.lifetime = .deleteOnSuccess
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = checkpoint + "-screenshot"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
    }
}
