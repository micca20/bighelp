import XCTest

/// One menu (☰) with hosts, chats and everywhere else; the bighelp logo switches
/// hosts on touch and hold; Settings holds this app's settings and Hermes Tools the
/// host's tools. Set BIGHELP_MENU_EVIDENCE (TEST_RUNNER_BIGHELP_MENU_EVIDENCE) to
/// save screenshots.
final class BighelpMenuUITests: BighelpUITestCase {
    @MainActor
    func testOneMenuHostsChatsAndSettings() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-use-multi-host-fixtures",
                               "-loopdy.demo.appearance", "dark"]
        app.launch()
        openSettings(in: app)
        XCTAssertFalse(app.buttons["quick-workspace.menu"].exists, "The grid button is gone.")
        save("01-settings", app)

        // ☰: hosts first, then chats, then everywhere else.
        tap(app.buttons["home.drawer.open"])
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let hosts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "menu.host.")).allElementsBoundByIndex
        XCTAssertFalse(hosts.isEmpty, "The menu lists hosts to switch between.")
        XCTAssertTrue(app.buttons["menu.new-chat"].waitForExistence(timeout: 3))
        XCTAssertLessThan(hosts[0].frame.minY, app.buttons["menu.new-chat"].frame.minY)
        save("02-menu", app)
        for id in ["menu.chats", "menu.agents", "menu.scheduled-tasks", "menu.hermes-tools", "menu.settings"] {
            let row = app.buttons[id]
            for _ in 0..<4 where !(row.exists && row.isHittable) { menu.swipeUp() }
            XCTAssertTrue(row.exists, id)
        }
        XCTAssertLessThan(app.buttons["menu.agents"].frame.minY, app.buttons["menu.settings"].frame.minY)
        save("02b-menu-scrolled", app)

        // Hermes Tools keeps the host's tools; this app's settings moved to Settings.
        tap(app.buttons["menu.hermes-tools"])
        XCTAssertTrue(app.descendants(matching: .any)["workspace.hub"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace.open.activity"].waitForExistence(timeout: 5))
        for moved in ["appearance", "permissions", "watch", "contact", "tabBar", "caching", "instances", "security"] {
            XCTAssertFalse(app.buttons["workspace.open.\(moved)"].exists, moved)
        }
        save("03-hermes-tools", app)

        // Touch and hold the logo to switch hosts.
        let logo = app.buttons["brand.host-switcher"].firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        logo.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["brand.host.add"].waitForExistence(timeout: 5))
        save("04-logo-host-switcher", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        // Settings: help, Apple Watch and hosts live here.
        openSettings(in: app)
        let help = app.buttons["settings.menu.help"].firstMatch
        let watch = app.buttons["settings.menu.watch"].firstMatch
        for _ in 0..<8 where !(help.exists && help.isHittable && watch.exists && watch.isHittable) { app.swipeUp() }
        XCTAssertTrue(help.exists, "Settings has Help & feedback.")
        XCTAssertTrue(watch.exists, "Settings has Apple Watch.")
        save("05-settings-help", app)
        tap(help)
        XCTAssertTrue(app.staticTexts["Version"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MENU_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
