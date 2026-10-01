import XCTest

/// Kanban from ☰ with demo boards: move cards by dragging and swiping, answer
/// what needs you, add cards, filter by agent and switch boards. Set
/// BIGHELP_KANBAN_EVIDENCE (TEST_RUNNER_BIGHELP_KANBAN_EVIDENCE) to save screenshots.
final class KanbanUITests: BighelpUITestCase {
    @MainActor
    func testPhoneBoardFromMenu() throws {
        let app = launch(appearance: "light")
        openKanban(in: app)
        // It opens on what needs you.
        XCTAssertTrue(app.buttons["kanban.lane-tab.needsYou"].isSelected)
        XCTAssertTrue(card("t_budget", in: app).waitForExistence(timeout: 5))
        save("01-phone-needs-you", app)

        // Approve a review: it lands in Done.
        card("t_budget", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["kanban.needs-you"].waitForExistence(timeout: 5))
        save("02-phone-review", app)
        app.buttons["kanban.approve"].tap()
        app.buttons["kanban.task.done"].tap()
        app.buttons["kanban.lane-tab.done"].tap()
        XCTAssertTrue(card("t_budget", in: app).waitForExistence(timeout: 5), "Approved work is done.")

        // Answer a question: the card goes back to its agent (Ready).
        app.buttons["kanban.lane-tab.needsYou"].tap()
        card("t_date", in: app).tap()
        let composer = app.textViews["kanban.task.composer"].exists
            ? app.textViews["kanban.task.composer"] : app.textFields["kanban.task.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Saturday the 18th works best.")
        app.buttons["kanban.task.send"].tap()
        save("03-phone-answered", app)
        app.buttons["kanban.task.done"].tap()
        app.buttons["kanban.lane-tab.ready"].tap()
        XCTAssertTrue(card("t_date", in: app).waitForExistence(timeout: 5), "Answered work goes back to Ready.")
        save("04-phone-ready", app)

        // Drag a Ready card up onto the Done tab.
        let quotes = card("t_quotes", in: app)
        XCTAssertTrue(quotes.waitForExistence(timeout: 5))
        quotes.press(forDuration: 0.8, thenDragTo: app.buttons["kanban.lane-tab.done"])
        app.buttons["kanban.lane-tab.done"].tap()
        XCTAssertTrue(card("t_quotes", in: app).waitForExistence(timeout: 5), "Dropping on a tab moves the card.")

        // Quick add to Later.
        app.buttons["kanban.lane-tab.later"].tap()
        app.buttons["kanban.quick-add.later"].tap()
        let field = app.textFields["kanban.quick-add.later.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Order launch stickers\n")
        XCTAssertTrue(app.staticTexts["Order launch stickers"].waitForExistence(timeout: 5))
        save("05-phone-later", app)

        // New card with an agent, starting now.
        app.buttons["kanban.new"].tap()
        let title = app.textViews["kanban.new.title"].exists ? app.textViews["kanban.new.title"] : app.textFields["kanban.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Write the launch tweet")
        app.buttons["kanban.new.agent.travel"].tap()
        app.segmentedControls["kanban.new.when"].buttons["Start now"].tap()
        save("06-phone-new-card", app)
        app.buttons["kanban.new.add"].tap()
        app.buttons["kanban.lane-tab.ready"].tap()
        XCTAssertTrue(app.staticTexts["Write the launch tweet"].waitForExistence(timeout: 5))

        // Filter by agent: only Mina's cards show.
        app.buttons["kanban.filter.travel"].tap()
        XCTAssertTrue(app.staticTexts["Write the launch tweet"].waitForExistence(timeout: 3))
        save("07-phone-filtered", app)
        app.buttons["kanban.lane-tab.later"].tap()
        XCTAssertTrue(card("t_survey", in: app).waitForExistence(timeout: 3), "Mina's own card stays.")
        XCTAssertFalse(card("t_store", in: app).exists, "Cards for anyone else are hidden.")
        app.buttons["kanban.filter.everyone"].tap()

        // Switch boards (menu items go by their title).
        app.buttons["kanban.board-switcher"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Get quotes for gutter cleaning"].waitForExistence(timeout: 5)
                      || card("h_gutter", in: app).waitForExistence(timeout: 5))
        save("08-phone-home-board", app)
    }

    @MainActor
    func testPhoneBoardDark() throws {
        let app = launch(appearance: "dark")
        openKanban(in: app)
        XCTAssertTrue(card("t_budget", in: app).waitForExistence(timeout: 5))
        save("10-phone-dark", app)
        app.buttons["kanban.lane-tab.working"].tap()
        XCTAssertTrue(card("t_hosting", in: app).waitForExistence(timeout: 5))
        save("11-phone-dark-working", app)
        card("t_hosting", in: app).tap()
        save("12-phone-dark-task", app)
    }

    /// iPad and landscape: all five lanes side by side, drag from lane to lane.
    @MainActor
    func testWideBoardDragsBetweenLanes() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Run on an iPad simulator for the side-by-side lanes.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openKanban(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["kanban.columns"].waitForExistence(timeout: 8))
            save("20-ipad-\(appearance)", app)
            if appearance == "light" {
                let quotes = card("t_quotes", in: app)
                let done = app.descendants(matching: .any)["kanban.lane.done"].firstMatch
                quotes.press(forDuration: 0.8, thenDragTo: done)
                XCTAssertTrue(done.descendants(matching: .any)["kanban.card.t_quotes"].waitForExistence(timeout: 5),
                              "Dragging to another lane moves the card.")
                save("21-ipad-dragged", app)
            }
            app.terminate()
        }
    }

    /// Back from Kanban leaves an app that keeps working.
    @MainActor
    func testBackFromKanbanLeavesAWorkingApp() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.home.opens-chat", "YES"]
        app.launch()
        openKanban(in: app)
        XCTAssertTrue(card("t_budget", in: app).waitForExistence(timeout: 8))
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(card("t_budget", in: app).waitForNonExistence(timeout: 8), "Back leaves the board")
        // Still alive and answering touches a few seconds later.
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 5))
        menuButton(in: app).tap()
        XCTAssertTrue(app.buttons["menu.kanban"].waitForExistence(timeout: 5), "The app still responds")
    }

    // MARK: Helpers

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        return app
    }

    /// ☰ on a root list, or on the agent home chat when the app opens to it.
    @MainActor
    private func menuButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
    }

    @MainActor
    private func openKanban(in app: XCUIApplication) {
        let menuButton = menuButton(in: app)
        XCTAssertTrue(menuButton.waitForExistence(timeout: 25))
        menuButton.tap()
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let row = app.buttons["menu.kanban"]
        for _ in 0..<5 where !(row.exists && row.isHittable) { menu.swipeUp() }
        XCTAssertTrue(row.exists, "The menu offers Kanban under Go to.")
        save("00-menu", app)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kanban.screen"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func card(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["kanban.card.\(id)"].firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_KANBAN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
