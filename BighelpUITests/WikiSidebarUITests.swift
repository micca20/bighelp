import XCTest

/// Regression coverage for removal of the optional provider screens.
final class WikiSidebarUITests: BighelpUITestCase {
    @MainActor
    func testRetiredFeaturesAreAbsentFromChatAndSettings() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 5))
        openChatWorkspaceMenu(in: app)
        XCTAssertTrue(app.buttons["menu.agents"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["quick-workspace.wiki"].exists)
        XCTAssertFalse(app.buttons["quick-workspace.menu.scratchpad"].exists)
        app.buttons["menu.settings"].tap()
        XCTAssertTrue(app.segmentedControls["settings.appearance"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.references.wiki"].exists)
        XCTAssertFalse(app.buttons["settings.references.github"].exists)
    }
}
