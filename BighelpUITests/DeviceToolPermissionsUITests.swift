import XCTest

final class DeviceToolPermissionsUITests: BighelpUITestCase {
    @MainActor
    func testIndependentPhoneToolsStartOffInPermissions() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
            "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
            "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()

        for capability in ["health", "calendar", "reminders"] {
            let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
            let target = app.switches["permissions.device-tools.\(capability)"].firstMatch
            for _ in 0..<6 where !target.exists { form.swipeUp() }
            let toggle = app.switches["permissions.device-tools.\(capability)"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
            // Demo fixtures have no verified host and must not prompt for real data.
            XCTAssertFalse(toggle.isEnabled)
            if capability == "calendar" || capability == "reminders" {
                XCTAssertTrue(app.staticTexts[capability == "calendar"
                    ? "Read, create, update, and delete events directly after you enable access."
                    : "Read, create, update, and delete reminders directly after you enable access."].exists)
            }
            XCTAssertTrue(app.navigationBars["Device access"].exists)
        }
        XCTAssertEqual(app.alerts.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "phone-tools-permissions-off"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
