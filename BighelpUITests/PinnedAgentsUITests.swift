import XCTest

/// Pinned agents on Agents: touch and hold acts on the agent you pressed (it
/// used to act on the first pinned one), a drag moves it, and each shows its
/// role under the name.
final class PinnedAgentsUITests: BighelpUITestCase {
    @MainActor
    func testHoldingAPinnedAgentActsOnThatAgent() {
        let app = launch(appearance: "light")
        openAgents(in: app)
        pin("travel", in: app)
        let travel = tile("travel", in: app)
        XCTAssertTrue(travel.waitForExistence(timeout: 5))
        save("01-pinned", app)

        travel.press(forDuration: 0.8)
        let actions = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "Letting go shows the agent's actions")
        XCTAssertTrue(app.buttons["agent.travel.edit"].waitForExistence(timeout: 3), "They're for the agent that was held")
        XCTAssertFalse(app.buttons["agent.finance.edit"].exists, "Not the first pinned agent")
        save("02-held-actions", app)
    }

    @MainActor
    func testDraggingAPinnedAgentReordersAndSticks() {
        let app = launch(appearance: "light")
        openAgents(in: app)
        pin("travel", in: app)
        let finance = tile("finance", in: app)
        let travel = tile("travel", in: app)
        XCTAssertTrue(travel.waitForExistence(timeout: 5))
        XCTAssertLessThan(finance.frame.minX, travel.frame.minX)

        travel.press(forDuration: 0.8, thenDragTo: finance)
        let moved = NSPredicate { _, _ in travel.frame.minX < finance.frame.minX }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5),
                       .completed, "Travel moves ahead of Finance")
        XCTAssertFalse(app.descendants(matching: .any)["agent.actions.list"].firstMatch.exists,
                       "A drag doesn't open the actions")
        save("03-reordered", app)

        // The order is kept: leaving Agents and coming back shows it the same.
        app.terminate()
        let again = launch(appearance: "light")
        openAgents(in: again)
        let travelAgain = tile("travel", in: again)
        XCTAssertTrue(travelAgain.waitForExistence(timeout: 5))
        XCTAssertLessThan(travelAgain.frame.minX, tile("finance", in: again).frame.minX)
    }

    @MainActor
    func testPinnedAgentsShowTheirRole() {
        let app = launch(appearance: "dark")
        openAgents(in: app)
        let finance = tile("finance", in: app)
        XCTAssertTrue(finance.waitForExistence(timeout: 5))
        XCTAssertFalse((finance.value as? String ?? "").contains("Here for you"))
        XCTAssertTrue((finance.value as? String ?? "").contains("Finance"), "The role shows: \(finance.value ?? "")")
        XCTAssertFalse(app.staticTexts["Here for you"].exists)
        save("04-roles-dark", app)
    }

    /// The same trap on Chats: holding the second pinned chat offered the
    /// first one's Rename, Archive and Delete.
    @MainActor
    func testHoldingAPinnedChatActsOnThatChat() {
        let app = launch(appearance: "light")
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        menu.tap()
        app.buttons["menu.chats"].tap()
        for id in ["demo-travel", "demo-finance"] {
            let row = app.buttons["session.row.\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.press(forDuration: 1.0)
            let pin = app.buttons["session.action.pin.\(id)"]
            XCTAssertTrue(pin.waitForExistence(timeout: 3))
            pin.tap()
        }
        let second = app.descendants(matching: .any)["session.pin.demo-finance"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["session.action.delete.demo-finance"].waitForExistence(timeout: 3),
                      "The menu is for the chat that was held")
        XCTAssertFalse(app.buttons["session.action.delete.demo-travel"].exists, "Not the first pinned chat")
        save("05-pinned-chat-menu", app)

        // Closing the menu and tapping still opens the chat.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        second.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer-shell"].firstMatch.waitForExistence(timeout: 8),
                      "Tapping a pinned chat opens it")
    }

    // MARK: Helpers

    @MainActor
    private func tile(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agents.featured.\(id)"].firstMatch
    }

    @MainActor
    private func pin(_ id: String, in app: XCUIApplication) {
        guard !tile(id, in: app).exists else { return }
        let list = app.descendants(matching: .any)["agents.screen"].firstMatch
        let more = app.buttons["agent.\(id).more"]
        for _ in 0..<6 where !(more.exists && more.isHittable) { list.swipeUp() }
        more.tap()
        let actions = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        let pin = app.buttons["agent.\(id).pin"]
        for _ in 0..<4 where !pin.isHittable { actions.swipeUp() }
        pin.tap()
        if actions.exists { app.swipeDown(velocity: .fast) }
        for _ in 0..<6 where !tile(id, in: app).isHittable { list.swipeDown() }
    }

    @MainActor
    /// Relaunching in the same test keeps its preferences (one run id per test).
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        return app
    }

    @MainActor
    private func openAgents(in app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        menu.tap()
        let agents = app.buttons["menu.agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PINNED_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
