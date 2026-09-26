import XCTest

final class ProjectChangesAvailabilityUITests: LoopdyUITestCase {
    @MainActor
    func testNonRepositoryProjectChangesShowsNAWithoutRetry() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-disable-demo-delays",
            "-enable-project-changes",
            "-use-project-changes-non-repository-fixture",
        ]
        app.launch()

        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let homeWorkspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(homeWorkspace.waitForExistence(timeout: 3))
        homeWorkspace.tap()
        dismissActionsAfterWorkspaceSelection(in: app)

        let changes = app.buttons["chat.session-status.changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        XCTAssertTrue(
            changes.label.contains("not available"),
            "Project Changes accessibility label: \(changes.label)"
        )
        let railScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        railScreenshot.name = "Project Changes non-repository N-A rail"
        railScreenshot.lifetime = .keepAlways
        add(railScreenshot)

        changes.tap()
        XCTAssertTrue(app.staticTexts["Project Changes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["This Project is not a Git repository."].exists)
        XCTAssertFalse(app.buttons["Retry"].exists)
        let panelScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        panelScreenshot.name = "Project Changes non-repository panel"
        panelScreenshot.lifetime = .keepAlways
        add(panelScreenshot)
    }
}
