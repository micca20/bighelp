import XCTest

/// Holding an agent in the Chats "Your agents" rail offers the same actions
/// as holding it in Agents, and they open the same sheets.
final class AgentHoldMenuUITests: BighelpUITestCase {
    @MainActor
    func testChatsRailHoldMenuMatchesAgentsAndOpensItsSheets() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO"]
        app.launch()
        openRootTab("tab.sessions", in: app)
        let tile = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@", "sessions.start-with.", "sessions.start-with.new")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "The Your agents rail shows")
        tile.press(forDuration: 1.2)
        for title in ["Message", "Edit", "Past chats", "Save as template"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "\(title) in the rail menu")
        }
        let railTitles = app.buttons.allElementsBoundByIndex.map(\.label)
        save("hold-1-chats-rail", app)

        app.buttons["Save as template"].tap()
        XCTAssertTrue(app.alerts["Template saved"].waitForExistence(timeout: 5))
        app.alerts["Template saved"].buttons.firstMatch.tap()

        tile.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 10), "Edit opens the agent editor")
        save("hold-2-edit-from-rail", app)
        app.buttons["Cancel"].firstMatch.tap()

        // The Agents list offers the same actions after the shared refactor.
        openRootTab("tab.agents", in: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", tile.label.replacingOccurrences(of: "New chat with ", with: ""))).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        for title in ["Message", "Edit", "Past chats", "Save as template"] {
            XCTAssertTrue(app.buttons[title].exists, "\(title) in the Agents menu")
        }
        save("hold-3-agents", app)
        XCTAssertFalse(railTitles.isEmpty)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_HOLD_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
