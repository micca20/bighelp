import XCTest

/// Opt-in: captures the App Store screenshot set from curated demo content.
/// Set BIGHELP_STORE_SCREENSHOTS (TEST_RUNNER_BIGHELP_STORE_SCREENSHOTS) to the
/// output folder. Run on an iPhone 6.5"/6.9" and an iPad 13" simulator with
/// the status bar overridden to 9:41.
final class AppStoreScreenshotUITests: BighelpUITestCase {
    @MainActor
    func testCaptureStoreScreenshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_STORE_SCREENSHOTS"] else {
            throw XCTSkip("Set BIGHELP_STORE_SCREENSHOTS to capture the App Store set.")
        }
        let prefix = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        func save(_ name: String, _ app: XCUIApplication) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name).png"))
        }

        var app = launch("light")
        let kyoto = app.buttons["session.row.store-kyoto"]
        XCTAssertTrue(kyoto.waitForExistence(timeout: 15))
        sleep(2)
        save("01-chats", app)

        kyoto.tap(); sleep(3)
        save("02-chat", app)
        goBack(app)

        openTab("tab.agents", app)
        save("05-agents", app)
        let group = app.buttons["agents.group.\(Self.groupID)"]
        for _ in 0..<3 where !group.isHittable { app.swipeUp() }
        if tap(group) {
            sleep(3)
            save("03-group", app)
            goBack(app)
        }
        openTab("tab.agents", app)
        if tap(app.buttons["agents.create"]) {
            let templates = app.segmentedControls["agent.editor.start"].buttons["Templates"]
            if templates.waitForExistence(timeout: 3) { templates.tap() }
            let template = app.buttons["agent.editor.template.anchor"]
            if template.waitForExistence(timeout: 3), template.isHittable { template.tap(); sleep(1) }
            save("06-studio", app)
            if !tap(app.buttons["agent.editor.cancel"]) { tap(app.buttons["Cancel"].firstMatch) }
            tap(app.buttons["Discard changes"])
        }

        openTab("tab.scheduled-tasks", app)
        save("04-tasks", app)

        openTab("tab.profile", app)
        save("07-settings", app)
        if tap(app.buttons["settings.default-model"]) {
            sleep(2)
            save("09-default-model", app)
            goBack(app)
        }
        if tap(app.buttons["settings.providers"]) {
            sleep(2)
            save("10-providers", app)
            goBack(app)
        }
        app.terminate()

        app = launch("dark")
        let darkKyoto = app.buttons["session.row.store-kyoto"]
        XCTAssertTrue(darkKyoto.waitForExistence(timeout: 15))
        darkKyoto.tap(); sleep(3)
        save("08-chat-dark", app)
        app.terminate()
    }

    private static let groupID = "dinner-party"

    @MainActor
    private func launch(_ appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-app-store-screenshots",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 4), element.isHittable else { return false }
        element.tap(); sleep(2)
        return true
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let custom = app.buttons["Back"].firstMatch
        let back = custom.waitForExistence(timeout: 2) ? custom : app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap(); sleep(1) }
    }

    /// iPhone tab bar buttons, or the matching iPad sidebar destinations.
    @MainActor
    private func openTab(_ identifier: String, _ app: XCUIApplication) {
        openRootTab(identifier, in: app, timeout: 8)
        sleep(2)
    }
}
