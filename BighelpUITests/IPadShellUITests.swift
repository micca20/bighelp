import XCTest

/// iPad keeps the phone's shape: ☰ opens the menu instead of an always-open
/// sidebar, and chats use the width of a landscape screen.
/// Set BIGHELP_IPAD_EVIDENCE (TEST_RUNNER_…) to save screenshots, and
/// BIGHELP_IPAD_APPEARANCE=dark for the dark look.
final class IPadShellUITests: BighelpUITestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_IPAD_APPEARANCE"] ?? "light" }

    @MainActor
    func testMenuIsCollapsedBehindTheMenuButton() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad-only layout") }
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        let menu = app.buttons["home.drawer.open"]
        _ = menu.waitForExistence(timeout: 10)
        save("root-landscape", app)

        XCTAssertFalse(app.collectionViews["root.sidebar"].exists, "No always-open sidebar")
        XCTAssertTrue(menu.exists, "☰ opens the menu, like on iPhone")
        XCTAssertTrue(app.buttons["tab.feed"].exists, "The Chat/Feed/Ideas/Goals bar is at the bottom")
        menu.tap()
        let drawer = app.descendants(matching: .any)["home.drawer"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        sleep(1)
        save("root-menu-open", app)
        XCTAssertLessThan(drawer.frame.width, app.frame.width * 0.6, "The menu slides over; it doesn't take the screen")
        XCTAssertEqual(drawer.frame.minX, app.frame.minX, accuracy: 1, "It slides in from the leading edge")
        app.buttons["menu.done"].tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 5))
        // A choice in the menu closes it and goes there.
        menu.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let agents = app.buttons["menu.agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatBubblesUseTheLandscapeWidth() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad-only layout") }
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-thinking-style", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "You're on track")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        sleep(1)
        save("chat-landscape", app)

        XCTAssertFalse(app.descendants(matching: .any)["quick-workspace.persistent-sidebar"].exists,
                       "No always-open sidebar in chats")
        let geometry = XCTAttachment(string: "App: \(app.frame)\nAnswer: \(answer.frame)")
        geometry.name = "chat-landscape-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertGreaterThanOrEqual(answer.frame.width, app.frame.width * 0.7,
                                    "Replies use most of a landscape iPad")
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(composer.frame.width, app.frame.width * 0.7,
                                    "The message box lines up with the wider messages")

        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        sleep(1)
        save("chat-portrait", app)
        XCTAssertGreaterThanOrEqual(answer.frame.width, app.frame.width * 0.75)
    }

    @MainActor
    private func waitForLandscape(_ app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        // The whole screen: app screenshots crop in landscape.
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_IPAD_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(appearance).png"))
    }
}
