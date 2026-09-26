import XCTest

final class Release180BlockerUITests: LoopdyUITestCase {
    @MainActor
    func testScratchpadOpensFromDiffHeader() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-enable-project-changes", "-use-project-changes-markdown-fixture", "-start-chat", "-test-chat-sidebar-collapsed"]
        app.launch()
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        attachment.tap()
        app.buttons["chat.action.workspace"].tap()
        let workspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        dismissActionsAfterWorkspaceSelection(in: app)
        let changes = app.buttons["chat.session-status.changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()
        let scratchpad = app.buttons["project-changes.scratchpad"]
        XCTAssertTrue(scratchpad.waitForExistence(timeout: 5), "Diff header must expose Scratchpad")
        guard scratchpad.exists else { return }
        scratchpad.tap()
        XCTAssertTrue(app.buttons["scratchpad.send-to-agent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scratchpad.save"].exists)
    }

    @MainActor
    func testScratchpadRichDraftStagesMarkdownWithoutSending() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-enable-project-changes", "-use-project-changes-markdown-fixture", "-start-chat", "-preview-ui-v3", "-test-chat-sidebar-collapsed"]
        app.launch()
        let composer = app.textViews["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let existing = composer.value as? String ?? ""
        if !existing.isEmpty { composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        composer.typeText("Existing destination draft")
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
        let source = "# Scratchpad checklist\n\n- **Bold** and *italic*\n- Second item\n\n```swift\nlet answer = 42\n```\n\n[Reference](https://example.com)"
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source, "Native source typing must retain every character before mode switching")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertGreaterThan(editor.frame.height, 44, "Landscape must keep a usable editing viewport")
        XCTAssertEqual(editor.value as? String, source)
        XCUIDevice.shared.orientation = .portrait
        mode.tap()
        XCTAssertEqual(mode.label, "Markdown", "Structured draft should enter actual rich editing")
        let rendered = editor.value as? String ?? ""
        XCTAssertTrue(rendered.contains("Scratchpad checklist"))
        XCTAssertFalse(rendered.contains("**Bold**"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "scratchpad-rich-editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["scratchpad.send-to-agent"].tap()
        let destination = app.buttons["scratchpad.session.demo-finance"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()
        XCTAssertTrue(app.buttons["Remove Scratchpad.md"].waitForExistence(timeout: 8), "Selection must stage the Markdown attachment in the destination composer")
        XCTAssertEqual(app.textViews["Message"].value as? String, "Existing destination draft")
        XCTAssertTrue(app.buttons["chat.send"].exists)
        XCTAssertFalse(app.buttons["scratchpad.send-to-agent"].exists)
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attached.name = "scratchpad-staged-not-sent"
        attached.lifetime = .keepAlways
        add(attached)
    }
}
