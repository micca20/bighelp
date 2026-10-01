import XCTest

/// Feed, Ideas, Goals and Apps have the Chat tab's ☰, New chat and ⋯, and
/// each one works (the edge-swipe zones used to cover the corner buttons).
final class BoardHeaderUITests: BighelpUITestCase {
    @MainActor
    func testEveryBoardTabHasWorkingMenuNewChatAndMore() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        for tab in ["tab.feed", "tab.ideas", "tab.goals", "tab.apps"] {
            let button = app.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 15), tab)
            button.tap()
            XCTAssertTrue(app.buttons["home.drawer.open"].firstMatch.waitForExistence(timeout: 5), "☰ on \(tab)")
            XCTAssertTrue(app.descendants(matching: .any)["board.new-chat"].firstMatch.exists, "New chat on \(tab)")
            XCTAssertTrue(app.buttons["board.more"].firstMatch.isHittable, "⋯ on \(tab)")
        }

        app.buttons["tab.feed"].firstMatch.tap()
        app.buttons["board.more"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Agent profile"].waitForExistence(timeout: 3), "⋯ opens the agent's places")
        XCTAssertTrue(app.buttons["Files"].exists)
        app.buttons["Agent profile"].tap()
        let close = app.buttons["agent.profile.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Agent profile opens")
        close.tap()

        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        for _ in 0..<10 where !menu.isHittable { usleep(200_000) }
        menu.tap()
        XCTAssertTrue(app.descendants(matching: .any)["navigation.menu"].waitForExistence(timeout: 5), "☰ opens the menu")
        app.buttons["menu.done"].firstMatch.tap()

        let newChat = app.descendants(matching: .any)["board.new-chat"].firstMatch
        for _ in 0..<10 where !newChat.isHittable { usleep(200_000) }
        newChat.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5), "New chat opens a chat")
    }
}
