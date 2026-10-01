import XCTest

/// Settings › Chat › Return sends. XCUITest on the simulator drops hardware
/// Return presses (plain, Shift, and sometimes Command) before the app sees
/// them, so the keys themselves are covered by `ComposerReturnKeyTests`.
final class HardwareKeyboardComposerUITests: BighelpUITestCase {
    @MainActor
    func testReturnSendsIsInSettingsAndStays() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        setReturnSends(false, in: app)
        app.terminate()
        app.launch()
        setReturnSends(true, in: app, expectingSaved: false)
    }

    /// Flips the toggle; `expectingSaved` checks what the previous launch left.
    @MainActor
    private func setReturnSends(_ on: Bool, in app: XCUIApplication, expectingSaved saved: Bool? = nil) {
        openSettings(in: app)
        settingsRow("settings.menu.chat", in: app).tap()
        let toggle = app.switches["settings.chat.return-sends"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if let saved { XCTAssertEqual(toggle.value as? String, saved ? "1" : "0", "The choice is saved") }
        save("settings-chat-return-sends-\(on)", app)
        if (toggle.value as? String == "1") != on {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    /// Set BIGHELP_KEYBOARD_EVIDENCE (TEST_RUNNER_…) to keep screenshots.
    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_KEYBOARD_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
