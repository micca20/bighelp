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
        XCTAssertTrue(mina.label.contains("Travel agent"), "Each agent's role shows under its name: \(mina.label)")
        XCTAssertTrue(app.buttons["fleet.new-chat"].isHittable, "One big New chat, bottom right")

        // Touch and hold a pinned agent and drag it: the new order stays.
        let pinned = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.pinned.'"))
        XCTAssertGreaterThanOrEqual(pinned.count, 2)
        let before = pinned.allElementsBoundByIndex.map(\.identifier)
        pinned.element(boundBy: 0).press(forDuration: 0.8, thenDragTo: pinned.element(boundBy: 1),
                                          withVelocity: .slow, thenHoldForDuration: 0.6)
        let after = pinned.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(after, [before[1], before[0]] + before.dropFirst(2), "Dragged into a new place")
        XCTAssertFalse(pinned.element(boundBy: 0).label.contains("Home Hermes"), "Pinned agents skip the host name")
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

    /// Hold a pinned agent and let go to unpin it; long-press any agent's row to pin it.
    @MainActor
    func testPinnedAgentsCanBeUnpinnedAndPinnedAgain() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        for name in ["Rio Tanaka", "Avery Park"] { // another host's agent, then the selected host's
            let tile = app.descendants(matching: .any)["fleet.pinned.\(name)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "\(name) is pinned")
            tile.press(forDuration: 1.0)
            let unpin = app.buttons["Unpin"].firstMatch
            XCTAssertTrue(unpin.waitForExistence(timeout: 3), "Holding a pinned agent offers Unpin")
            unpin.tap()
            XCTAssertFalse(tile.waitForExistence(timeout: 2), "\(name) left the pinned agents")
            let row = app.buttons["fleet.agent.\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "\(name) is in the list now")
        }
        let row = app.buttons["fleet.agent.Rio Tanaka"]
        row.press(forDuration: 1.0)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3), "A row's menu offers Pin")
        pin.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.pinned.Rio Tanaka"].waitForExistence(timeout: 3),
                      "Pinned again")
    }

    /// A swipe that starts on the pinned agents scrolls the list like anywhere
    /// else; only touch and hold picks an agent up.
    @MainActor
    func testSwipingOnPinnedAgentsScrollsTheList() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        let pinned = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.pinned.'"))
        XCTAssertTrue(pinned.firstMatch.waitForExistence(timeout: 5))
        let order = pinned.allElementsBoundByIndex.map(\.identifier)
        let tile = pinned.firstMatch

        // Control: a swipe on an agent row scrolls.
        let row = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowTop = row.frame.minY
        swipeUp(from: row, in: app)
        XCTAssertLessThan(row.frame.minY, rowTop - 40, "The list scrolls (control)")
        swipeDown(in: app)
        let tileTop = tile.frame.minY

        swipeUp(from: tile, in: app)
        XCTAssertLessThan(tile.frame.minY, tileTop - 40, "A swipe that starts on a pinned agent scrolls the list")
        XCTAssertEqual(pinned.allElementsBoundByIndex.map(\.identifier), order, "A swipe doesn't rearrange them")
    }

    @MainActor
    private func swipeUp(from element: XCUIElement, in app: XCUIApplication) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
    }

    @MainActor
    private func swipeDown(in app: XCUIApplication) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
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
