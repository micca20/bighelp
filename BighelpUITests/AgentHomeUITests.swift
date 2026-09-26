import XCTest

/// Opt-in: walks the agent home (Chat, profile, switcher, ☰, Feed, Ideas,
/// Goals, Apps) on demo fixtures and saves screenshots. Set
/// BIGHELP_HOME_EVIDENCE (TEST_RUNNER_BIGHELP_HOME_EVIDENCE) to the output folder.
final class AgentHomeUITests: BighelpUITestCase {
    @MainActor
    func testAgentHomeWalkthrough() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_HOME_EVIDENCE"] else {
            throw XCTSkip("Set BIGHELP_HOME_EVIDENCE to capture the agent home.")
        }
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_HOME_APPEARANCE"] ?? "light"
        func save(_ name: String, _ app: XCUIApplication) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(appearance)-\(name).png"))
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()

        // Launch lands in the default agent's chat with the big avatar.
        let avatar = app.buttons["agent.hero.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 25), "Home chat did not open")
        XCTAssertTrue(app.buttons["chat.menu"].exists)
        XCTAssertTrue(app.buttons["chat.home.new-chat"].exists)
        XCTAssertTrue(app.buttons["tab.feed"].exists)
        sleep(2)
        save("01-chat", app)

        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.profile"].waitForExistence(timeout: 10))
        sleep(1)
        save("02-profile-activity", app)
        for (index, tab) in ["approvals", "schedules", "identity"].enumerated() {
            tap(app.buttons["agent.profile.tab.\(tab)"])
            save("0\(3 + index)-profile-\(tab)", app)
        }
        tap(app.buttons["agent.profile.close"])

        tap(app.buttons["agent.hero.name"])
        XCTAssertTrue(app.descendants(matching: .any)["agent.switcher"].waitForExistence(timeout: 10))
        save("06-switcher", app)
        app.swipeDown(velocity: .fast)
        sleep(1)

        tap(app.buttons["chat.menu"])
        XCTAssertTrue(app.descendants(matching: .any)["home.drawer"].waitForExistence(timeout: 10))
        save("07-drawer", app)
        tap(app.buttons["home.drawer.done"])

        // New chat: one agent is a 1:1 chat, two or more a group.
        tap(app.buttons["chat.home.new-chat"])
        let submit = app.buttons["bot-mode.create.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertEqual(submit.label, "Start chat")
        save("07b-new-chat-one", app)
        tap(app.buttons["bot-mode.create.participant.travel"])
        XCTAssertEqual(submit.label, "Start group chat")
        save("07c-new-chat-group", app)
        tap(app.buttons["Cancel"])

        tap(app.buttons["tab.feed"])
        XCTAssertTrue(app.descendants(matching: .any)["board.feed"].waitForExistence(timeout: 10))
        sleep(1)
        save("08-feed", app)
        tap(app.buttons["tab.ideas"])
        XCTAssertTrue(app.descendants(matching: .any)["board.ideas"].waitForExistence(timeout: 10))
        save("09-ideas", app)
        tap(app.buttons["tab.goals"])
        XCTAssertTrue(app.descendants(matching: .any)["board.goals"].waitForExistence(timeout: 10))
        save("10-goals", app)
        tap(app.buttons["tab.apps"])
        XCTAssertTrue(app.descendants(matching: .any)["board.apps"].waitForExistence(timeout: 10))
        save("11-apps", app)

        // Discuss opens a chat with the post ready to talk about.
        tap(app.buttons["tab.feed"])
        tap(app.buttons.matching(identifier: "board.feed.discuss").firstMatch)
        XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 15)
                      || app.textViews.firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        save("12-discuss", app)

        // Chat returns to the agent's own chat.
        if app.buttons["chat.back"].exists { app.buttons["chat.back"].tap() } else { app.swipeRight() }
        tap(app.buttons["tab.sessions"])
        XCTAssertTrue(app.buttons["agent.hero.avatar"].waitForExistence(timeout: 15))
        save("13-chat-again", app)
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }
}
