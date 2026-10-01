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
        // Give each agent a chat first, so later taps reopen it.
        desk.tap()
        try say("Hello desk", in: app)
        save("fleet-2-other-host-chat", app)
        app.buttons["chat.back"].firstMatch.tap()

        // Back on the list, Lab Hermes is now the one read in the background.
        XCTAssertTrue(agent(on: "Lab Hermes", in: app).waitForExistence(timeout: 45))
        XCTAssertTrue(agent(on: "Desk Hermes", in: app).exists)
        named("Lab agent", in: app).tap()
        try say("Hello lab", in: app)
        app.buttons["chat.back"].firstMatch.tap()

        // Each switch is timed from the tap to that agent's own chat on screen.
        var timings: [String: Double] = [:]
        timings["1-to-desk"] = try timeToOpen(named("Desk agent", in: app), showing: "Hello desk", in: app)
        app.buttons["chat.back"].firstMatch.tap()
        timings["2-to-lab"] = try timeToOpen(named("Lab agent", in: app), showing: "Hello lab", in: app)
        app.buttons["chat.back"].firstMatch.tap()
        timings["3-to-desk-again"] = try timeToOpen(named("Desk agent", in: app), showing: "Hello desk", in: app)
        app.buttons["chat.back"].firstMatch.tap()
        // The floor: the same host's agent again, with no switch at all.
        timings["4-same-host"] = try timeToOpen(named("Desk agent", in: app), showing: "Hello desk", in: app)
        app.buttons["chat.back"].firstMatch.tap()
        report(timings)
        app.buttons["fleet.toggle"].tap()
        menu.tap()
        let hosts = app.buttons["menu.hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 5))
        XCTAssertTrue(hosts.label.contains("Desk Hermes"), "Desk Hermes became the selected host: \(hosts.label)")
        save("fleet-3-desk-selected", app)
    }

    /// Provider usage opened from a chat on the host the all-hosts list just
    /// switched to. The usage panel used to keep the first host's connection and
    /// said "Usage couldn't be loaded" until the chat closed.
    @MainActor func testProviderUsageLoadsInAChatOnTheOtherHost() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes fleet")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "fleet" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
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
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        let desk = agent(on: "Desk Hermes", in: app)
        XCTAssertTrue(desk.waitForExistence(timeout: 45))
        desk.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 45), "Desk Hermes' chat opens")
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        let usage = app.buttons["chat.provider-usage"].firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 10), "Provider usage is in the chat's ⋯ menu")
        usage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage"].waitForExistence(timeout: 10))
        let failed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "couldn't be loaded")).firstMatch
        let loaded = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "provider-usage.")).matching(
            NSPredicate(format: "NOT identifier IN %@", ["provider-usage.message", "provider-usage.close",
                                                         "provider-usage.refresh"])).firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !failed.exists, !loaded.exists { Thread.sleep(forTimeInterval: 0.5) }
        save("fleet-4-usage-in-other-host-chat", app)
        XCTAssertFalse(failed.exists, "Usage loads in the other host's chat")
    }

    /// Seconds from tapping an agent to its chat, with the given message, on screen.
    @MainActor private func timeToOpen(_ agent: XCUIElement, showing message: String,
                                       in app: XCUIApplication) throws -> Double {
        XCTAssertTrue(agent.waitForExistence(timeout: 30))
        let text = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", message)).firstMatch
        let start = Date()
        agent.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 60), "The agent's own chat opens on its host")
        return (Date().timeIntervalSince(start) * 100).rounded() / 100
    }

    /// Sends a message and waits for the agent's reply, so the chat is saved on the host.
    @MainActor private func say(_ message: String, in app: XCUIApplication) throws {
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "The agent's chat opens on its own host")
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["chat.send"]
        let deadline = Date().addingTimeInterval(30)
        while !send.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        send.tap()
        let reply = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fixture complete")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 45), "The agent replies")
    }

    @MainActor private func named(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH 'fleet.agent.' OR identifier BEGINSWITH "
            + "'fleet.pinned.') AND label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor private func report(_ timings: [String: Double]) {
        let json = (try? JSONSerialization.data(withJSONObject: timings, options: [.sortedKeys])) ?? Data()
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "fleet-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("fleet-timings.json"))
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
        app.buttons["More options"].firstMatch.tap()
        let nameField = app.textFields["host-setup.name"]
        if nameField.waitForExistence(timeout: 3) {
            nameField.tap()
            nameField.typeText(name)
        }
        // An open host connects straight from the address.
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
