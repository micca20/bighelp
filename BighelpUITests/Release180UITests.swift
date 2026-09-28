import XCTest

final class Release180UITests: BighelpUITestCase {
    @MainActor
    func testEmptyUnlabelledCodeBlockRemainsLosslesslyEditableInSource() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        let composer = app.textViews["Message"].exists ? app.textViews["Message"] : app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let source = "Before an empty code block\n\n```\n\n```"
        composer.tap()
        composer.typeText(source)
        app.buttons["chat.composer.expand"].tap()
        app.buttons["reference-hub.editor-mode"].tap()
        let mode = app.buttons["chat.composer.expanded.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.label, "Rich text", "Unrepresentable empty structure must stay in source mode rather than silently disappear on edit")
        XCTAssertEqual(app.textViews["Expanded message"].value as? String, source)
    }

    @MainActor
    func testRichTextSwitchPreservesStructuredDraftThroughEditingAndCollapse() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.interface-version", "v3"]
        app.launch()
        let composer = app.textViews["Message"].exists ? app.textViews["Message"] : app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let source = "# Release checklist\n\n1. Preserve **themes**\n2. Fix media\n\n[Release notes](https://example.com/release)\n\n```swift\nlet version = 180\n```"
        composer.tap()
        composer.typeText(source)
        let expand = app.buttons["chat.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        app.buttons["reference-hub.editor-mode"].tap()
        let mode = app.buttons["chat.composer.expanded.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let editor = app.textViews["Expanded message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        if mode.label == "Markdown" { mode.tap() }
        XCTAssertEqual(editor.value as? String, source, "Opening or changing mode must preserve the exact original Markdown")
        mode.tap()
        XCTAssertEqual(mode.label, "Markdown", "Rich Text must actually enter rich editing for structured drafts")
        let rendered = editor.value as? String ?? ""
        XCTAssertTrue(rendered.contains("Release checklist"))
        XCTAssertTrue(rendered.contains("Release notes"))
        XCTAssertTrue(rendered.contains("let version = 180"))
        XCTAssertFalse(rendered.contains("https://example.com/release"))
        XCTAssertFalse(rendered.contains("```"))
        XCTAssertFalse(rendered.contains("**themes**"))
        evidence("structured-rich-editor")
        mode.tap()
        XCTAssertEqual(editor.value as? String, source)
        mode.tap()
        editor.tap()
        editor.typeText(" revised")
        mode.tap()
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.contains("revised"))
        XCTAssertTrue(edited.contains("https://example.com/release"))
        XCTAssertTrue(edited.contains("let version = 180"))
        XCTAssertTrue(edited.contains("```"))
        XCTAssertTrue(edited.contains("1."))
        evidence("structured-markdown-after-edit")
        app.buttons["chat.composer.expanded.collapse"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 4))
        XCTAssertEqual(composer.value as? String, edited)
    }

    @MainActor
    func testAppearanceHidesLegacyInterfaceChoices() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.appearance.interface-version", "v1", "-loopdy.appearance.theme", "loopdy"]
        app.launch()
        openSettings(in: app)
        let appearance = settingsRow("settings.menu.appearance", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.buttons["settings.themes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["settings.interface-version"].exists)
        XCTAssertFalse(app.buttons["V1"].exists)
        XCTAssertFalse(app.buttons["V2"].exists)
        evidence("v3-only-appearance")
    }

    @MainActor
    func testProjectChangesOutsideTapDismissesWithoutBreakingInsideControls() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-enable-project-changes", "-use-project-changes-markdown-fixture", "-start-chat"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
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
        let panel = app.otherElements["project-changes.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "README.md,")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(app.buttons["Preview"].waitForExistence(timeout: 5))
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Markdown Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.exists)
        evidence("diff-panel-inside-controls")
        // The uncovered canvas is left of the trailing panel, not its resize rail.
        XCTAssertGreaterThan(panel.frame.minX, app.frame.minX + 40)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: panel.frame.minX - 30, dy: app.frame.midY)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 4), "A tap on the chat canvas outside the diff must collapse the side panel")
        XCTAssertTrue(changes.exists)
        evidence("diff-panel-dismissed")
    }

    @MainActor
    private func evidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
