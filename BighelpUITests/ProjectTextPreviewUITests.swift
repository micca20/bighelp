import XCTest

final class ProjectTextPreviewUITests: BighelpUITestCase {
    @MainActor
    func testMarkdownAndTextOpenPreviewAndScrollOnIPad() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-enable-project-changes", "-use-project-changes-markdown-fixture"]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let newChat = app.buttons["root.new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let home = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        dismissActionsAfterWorkspaceSelection(in: app)
        let changes = app.buttons["chat.session-status.changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()
        let panel = app.otherElements["project-changes.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        for (path, diff, preview, marker) in [
            ("README.md", "+# Fixture Markdown Preview", "Fixture Markdown Preview", "Markdown final preview marker"),
            ("notes.txt", "+Plain text diff opens in Diff mode", "**This stays literal in TXT.**", "Text final preview marker"),
        ] {
            let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(path),")).firstMatch
            if !file.isHittable {
                for _ in 0..<5 { panel.swipeDown() }
            }
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.tap()
            XCTAssertTrue(app.staticTexts[diff].waitForExistence(timeout: 5))
            let previewButton = app.buttons["Preview"]
            XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
            previewButton.tap()
            let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", preview)).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts[diff].exists)
            capture(app, "\(path) in-app preview")
            for _ in 0..<4 {
                panel.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.85))
                    .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3)))
            }
            let ending = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            XCTAssertTrue(ending.exists)
            capture(app, "\(path) scrolled to final preview marker")
            for _ in 0..<5 { panel.swipeDown() }
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
