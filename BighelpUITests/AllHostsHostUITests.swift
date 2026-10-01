import XCTest

/// The all-hosts view against two real, isolated Hermes hosts started by
/// `Scripts/HostSignInMatrixProbe.py --modes fleet` (BIGHELP_SIGNIN_PROBE).
/// The host that isn't selected is read in the background, and opening one of
/// its agents switches to it. Skipped without the probe.
final class AllHostsHostUITests: BighelpUITestCase {
    private var probe: [String: String] = [:]

    @MainActor func testAllHostsListsBothHostsAndOpensTheOther() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes fleet")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "fleet" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-bighelp.hosts.all-hosts", "NO"]
        app.launch()

        try addHost(app, address: try XCTUnwrap(probe["address_a"]), name: "Desk Hermes")
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.hosts"].tap()
        app.buttons["menu.host.add"].tap()
        try addHost(app, address: try XCTUnwrap(probe["address_b"]), name: "Lab Hermes")

        // Lab Hermes is selected now; Desk Hermes is read in the background.
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 10))
        let desk = agent(on: "Desk Hermes", in: app)
        XCTAssertTrue(desk.waitForExistence(timeout: 45), "The other host's agents are listed")
        XCTAssertTrue(agent(on: "Lab Hermes", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "researcher")).firstMatch
            .waitForExistence(timeout: 20), "Every agent on the host, not just its default")
        save("fleet-1-both-hosts", app)

        // Opening Desk Hermes' agent switches to that host and opens its chat.
        desk.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "The agent's chat opens on its own host")
        save("fleet-2-other-host-chat", app)
        app.buttons["chat.back"].firstMatch.tap()

        // Back on the list, Lab Hermes is now the one read in the background.
        XCTAssertTrue(agent(on: "Lab Hermes", in: app).waitForExistence(timeout: 45))
        XCTAssertTrue(agent(on: "Desk Hermes", in: app).exists)
        app.buttons["fleet.toggle"].tap()
        menu.tap()
        let hosts = app.buttons["menu.hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 5))
        XCTAssertTrue(hosts.label.contains("Desk Hermes"), "Desk Hermes became the selected host: \(hosts.label)")
        save("fleet-3-desk-selected", app)
    }

    @MainActor private func agent(on host: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH 'fleet.agent.' OR identifier BEGINSWITH "
            + "'fleet.pinned.') AND label CONTAINS %@", host)).firstMatch
    }

    @MainActor private func addHost(_ app: XCUIApplication, address: String, name: String) throws {
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(address)
        let nameField = app.textFields["host-setup.name"]
        if nameField.waitForExistence(timeout: 3) {
            nameField.tap()
            nameField.typeText(name)
        }
        app.buttons["Advanced connection"].firstMatch.tap()
        let http = app.switches["direct-hermes.private-http"]
        XCTAssertTrue(http.waitForExistence(timeout: 3))
        (http.switches.firstMatch.exists ? http.switches.firstMatch : http).tap()
        tapConnect(app)
        XCTAssertTrue(app.buttons["direct-hermes.auth-picker"].waitForExistence(timeout: 30), "The host answers")
        tapConnect(app)
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected to \(name)")
        next.tap()
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
