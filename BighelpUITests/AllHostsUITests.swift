import XCTest

/// The all-hosts view: ☰'s switch lists every agent on every host with its
/// host tagged, a tap opens that agent's chat, and a one-host screen like
/// Settings asks which host first. Demo hosts: Home Hermes (the demo's own
/// agents), Studio Mac (sample agents) and Office Linux (out of reach).
/// Set BIGHELP_FLEET_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class AllHostsUITests: BighelpUITestCase {
    @MainActor
    func testAllHostsListOpensAgentsAndAsksWhichHostForSettings() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()

        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let toggle = app.buttons["menu.all-hosts"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Off")
        toggle.tap()

        XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5))
        let mina = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        XCTAssertTrue(mina.label.contains("Home Hermes"), mina.label)
        let sage = app.buttons["fleet.agent.Sage Ortiz"]
        XCTAssertTrue(sage.waitForExistence(timeout: 5), "Another host's agents are listed too")
        XCTAssertTrue(sage.label.contains("Studio Mac"), sage.label)
        XCTAssertTrue(app.descendants(matching: .any)["fleet.host-note.Office Linux"].exists,
                      "A host out of reach says so")
        save("list", app)

        // A tap opens that agent's own chat, with Back to the list.
        mina.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mina Shah"))
            .firstMatch.exists, "It's Mina's chat")
        app.buttons["chat.back"].firstMatch.tap()
        XCTAssertTrue(mina.waitForExistence(timeout: 5))

        // Settings belongs to one host: pick which.
        menu.tap()
        XCTAssertEqual(app.buttons["menu.all-hosts"].value as? String, "On")
        app.buttons["menu.settings"].tap()
        let pickHome = app.buttons["fleet.gate.host.Home Hermes"]
        XCTAssertTrue(pickHome.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.gate.host.Studio Mac"].exists)
        save("which-host", app)
        pickHome.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // ☰ › All agents is the way back.
        menu.tap()
        app.buttons["menu.all-agents"].tap()
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5))

        // Off again: one host, its own chat list.
        app.buttons["fleet.toggle"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["fleet.home"].exists)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["BIGHELP_FLEET_EVIDENCE"] != nil else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "all-hosts-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
