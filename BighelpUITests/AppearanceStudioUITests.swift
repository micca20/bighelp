import XCTest

/// Settings › Colors: bubble color and page picks apply live and stick.
final class AppearanceStudioUITests: BighelpUITestCase {
    @MainActor
    func testColorsStudioPicksBubbleAndPagesAndKeepsThem() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        let link = settingsRow("settings.themes", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearance.studio"].firstMatch.waitForExistence(timeout: 5))
        evidence("colors-default")

        let ocean = app.buttons["appearance.bubble.ocean"]
        XCTAssertTrue(ocean.waitForExistence(timeout: 3))
        ocean.tap()
        XCTAssertTrue(ocean.isSelected, "The picked bubble color shows as selected")
        let paper = app.buttons["appearance.light.paper"]
        for _ in 0..<3 where !paper.isHittable { app.swipeUp() }
        paper.tap()
        XCTAssertTrue(paper.isSelected)
        let black = app.buttons["appearance.dark.black"]
        for _ in 0..<3 where !black.isHittable { app.swipeUp() }
        black.tap()
        XCTAssertTrue(black.isSelected)
        XCTAssertTrue(app.buttons["appearance.more-themes"].exists, "Custom themes stay one tap away")
        app.swipeDown()
        evidence("colors-ocean-paper-black")

        // Dark mode shows the Black page.
        app.segmentedControls["appearance.mode"].buttons["Dark"].tap()
        sleep(1)
        evidence("colors-dark")
        app.segmentedControls["appearance.mode"].buttons["Light"].tap()

        // The summary in Settings names the picks.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let summary = settingsRow("settings.themes", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.value as? String, "Ocean bubbles · Paper · Black")

        // Picks survive a relaunch.
        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertEqual(settingsRow("settings.themes", in: app).value as? String, "Ocean bubbles · Paper · Black")
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "appearance-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("appearance-\(name).png"))
        }
    }
}
