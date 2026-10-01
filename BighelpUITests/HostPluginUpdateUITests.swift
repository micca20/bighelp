import XCTest

/// The plugin version section: Update, Restart with confirmation, and the verified
/// result. Set BIGHELP_PLUGIN_UPDATE_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class HostPluginUpdateUITests: BighelpUITestCase {
    @MainActor
    func testPluginUpdateStatesAndRestartConfirmation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-plugin-update"]
        app.launch()

        XCTAssertTrue(app.buttons["settings.plugin.update"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["settings.plugin.update"].label, "Update plugin to 2.17.0")
        // Old running code can't restart itself: say so, and offer no dead-end Restart button.
        let manual = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Restart Hermes on your computer once")).firstMatch
        XCTAssertTrue(manual.exists)
        save("01-update-available", app)

        let restart = app.buttons["settings.plugin.restart"]
        for _ in 0..<4 where !restart.isHittable { app.swipeUp() }
        XCTAssertTrue(restart.exists)
        restart.tap()
        let confirm = app.buttons["settings.plugin.restart.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Restart Hermes to finish updating?"].exists)
        save("02-restart-confirmation", app)
        app.buttons["Later"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))

        let running = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "installed and running")).firstMatch
        for _ in 0..<6 where !running.isHittable { app.swipeUp() }
        XCTAssertTrue(running.isHittable)
        save("03-restarting-and-verified", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PLUGIN_UPDATE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
