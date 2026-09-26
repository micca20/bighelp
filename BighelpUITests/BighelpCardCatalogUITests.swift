import XCTest

final class BighelpCardCatalogUITests: BighelpUITestCase {
    @MainActor
    private func launchCatalog(
        extraArguments: [String] = [],
        preferredContentSize: String? = nil
    ) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-show-card-catalog",
            "-use-card-catalog-fixture",
        ] + extraArguments
        if let preferredContentSize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                preferredContentSize,
            ]
        }
        app.launch()
        return app
    }

    @MainActor
    func testBrowseSearchAndPreviewFixtureCatalog() throws {
        let app = launchCatalog()
        let catalog = app.descendants(matching: .any)["catalog.screen"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].exists)

        let search = app.searchFields["Search Card Catalog"]
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("weather")
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].exists)
        search.buttons["Clear text"].tap()
        search.tap()
        search.typeText("earthquake")
        XCTAssertTrue(app.staticTexts["No card templates found"].exists)

        search.buttons["Clear text"].tap()
        app.buttons["catalog.template.weather-brief"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["catalog.detail-column"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["catalog.preview.weather-brief"].exists)
        XCTAssertTrue(app.staticTexts["Weather Brief"].exists)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "catalog-native-detail"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testDetailDisclosesPermissionsProvenanceAndVersionBeforeInstall() throws {
        let app = launchCatalog()
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].waitForExistence(timeout: 5))
        app.buttons["catalog.template.weather-brief"].tap()
        let detail = app.descendants(matching: .any)["catalog.detail-column"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 3))

        for disclosure in [
            "api.weather.gov",
            "Every 15 minutes",
            "Stops refreshing after Sep 8, 2026",
            "card",
            "metric",
            "bighelp",
            "MIT",
            "Version 1",
        ] {
            XCTAssertTrue(
                detail.staticTexts[disclosure].exists,
                "Missing pre-install disclosure: \(disclosure)"
            )
        }
        XCTAssertTrue(app.buttons["catalog.install.weather-brief"].exists)
    }

    @MainActor
    func testInstallUpdateAndRemoveActionsUseExplicitStates() throws {
        var app = launchCatalog()
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].waitForExistence(timeout: 5))
        app.buttons["catalog.template.weather-brief"].tap()
        let install = app.buttons["catalog.install.weather-brief"]
        XCTAssertTrue(install.exists)
        install.tap()
        XCTAssertTrue(app.buttons["catalog.remove.weather-brief"].waitForExistence(timeout: 3))

        app.terminate()
        app = launchCatalog(extraArguments: ["-card-catalog-installed-version", "0"])
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].waitForExistence(timeout: 5))
        app.buttons["catalog.template.weather-brief"].tap()
        let update = app.buttons["catalog.update.weather-brief"]
        XCTAssertTrue(update.exists)
        update.tap()
        XCTAssertTrue(app.buttons["catalog.remove.weather-brief"].waitForExistence(timeout: 3))
        app.buttons["catalog.remove.weather-brief"].tap()
        XCTAssertTrue(app.buttons["catalog.install.weather-brief"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testDynamicTypeAccessibilityXLKeepsDetailReadableAndActionsReachable() throws {
        let app = launchCatalog(
            preferredContentSize: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )
        XCTAssertTrue(app.buttons["catalog.template.weather-brief"].waitForExistence(timeout: 5))
        app.buttons["catalog.template.weather-brief"].tap()
        let detail = app.descendants(matching: .any)["catalog.detail-column"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        for _ in 0..<10 where !app.buttons["catalog.install.weather-brief"].isHittable {
            detail.swipeUp()
        }
        XCTAssertTrue(app.buttons["catalog.install.weather-brief"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["catalog.install.weather-brief"].frame.height, 44)
    }

    @MainActor
    func testVoiceOverContractProvidesNamedControlsAndGroupedPermissions() throws {
        let app = launchCatalog()
        let template = app.buttons["catalog.template.weather-brief"]
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        XCTAssertEqual(template.label, "Weather Brief, bighelp, Version 1")
        template.tap()
        let permissions = app.descendants(matching: .any)["catalog.permissions.weather-brief"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 3))
        XCTAssertTrue(permissions.label.contains("api.weather.gov"))
        XCTAssertTrue(permissions.label.contains("Every 15 minutes"))
        XCTAssertEqual(app.buttons["catalog.install.weather-brief"].label, "Install Weather Brief")
    }

    @MainActor
    func testIPadUsesReadableTwoColumnCatalogLayout() throws {
        let app = launchCatalog()
        guard app.frame.width >= 700 else { throw XCTSkip("iPad-only layout contract") }
        let sidebar = app.descendants(matching: .any)["catalog.sidebar"]
        let detailPlaceholder = app.staticTexts["Choose a card template"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(detailPlaceholder.waitForExistence(timeout: 3))
        XCTAssertLessThan(sidebar.frame.maxX, detailPlaceholder.frame.minX)
        XCTAssertLessThan(detailPlaceholder.frame.maxX, app.frame.maxX)
    }
}
