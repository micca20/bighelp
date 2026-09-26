import XCTest

final class HomeWeatherUITests: BighelpUITestCase {
    @MainActor
    private func launch(_ mode: String, accessibility: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-home-weather-fixture=\(mode)",
                               "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    @MainActor
    func testWeatherIsVisibleAboveInboxBeforePermissionAndLoadsAfterEnable() {
        let app = launch("permission")
        let enable = app.buttons["dashboard.weather.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        let inbox = app.staticTexts["Agent Inbox"]
        XCTAssertTrue(inbox.exists)
        XCTAssertLessThan(enable.frame.maxY, inbox.frame.minY)
        XCTAssertFalse(app.staticTexts["San Francisco"].exists)
        enable.tap()
        XCTAssertTrue(app.staticTexts["San Francisco"].waitForExistence(timeout: 5))
        XCTAssertFalse(enable.exists)
        capture(app, "weather-enabled")
    }

    @MainActor
    func testDeniedLocationRetainsWeatherPanelWithSettingsAction() {
        let app = launch("denied", accessibility: true)
        let settings = app.buttons["dashboard.weather.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let dashboard = app.scrollViews["dashboard.screen"]
        for _ in 0..<4 where !settings.isHittable { dashboard.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        XCTAssertFalse(app.buttons["dashboard.weather.enable"].exists)
        capture(app, "weather-denied-accessibility")
    }

    @MainActor
    func testFailedWeatherCanRetryWithoutReloadingInbox() {
        let app = launch("failure")
        let retry = app.buttons["dashboard.weather.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Agent Inbox"].exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["San Francisco"].waitForExistence(timeout: 5))
        capture(app, "weather-retry")
    }

    @MainActor
    func testWeatherRemainsAvailableWhenHostDashboardIsOffline() {
        let app = launch("offline")
        XCTAssertTrue(app.staticTexts["San Francisco"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dashboard data is unavailable. Please try again."].exists)
        capture(app, "weather-offline-host")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
