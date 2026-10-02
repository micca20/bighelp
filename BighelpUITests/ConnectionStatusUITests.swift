import XCTest

/// Every place that shows the host connection uses the shared loaders, mapped
/// by one adapter so they agree: the chat's banner (with the island under the
/// Dynamic Island following the same state), host setup's check and All
/// agents' hosts. Demo holds put each one in each state. Set BIGHELP_CONNECTION_EVIDENCE (TEST_RUNNER_…) to a
/// folder to save screenshots there.
final class ConnectionStatusUITests: BighelpUITestCase {
    @MainActor
    func testChatBannerSaysWhatTheConnectionIsDoing() throws {
        let holds: [(hold: String, words: String, offersRetry: Bool)] = [
            ("connecting", "Connecting to your computer…", false),
            ("reconnecting", "Reconnecting to your computer…", false),
            ("disconnected", "Not connected to your computer", true),
            ("no-internet", "No internet connection", true),
        ]
        for (hold, words, offersRetry) in holds {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                   "-test-connection-keeper", hold]
            app.launch()
            let banner = app.descendants(matching: .any)["chat.connection-banner"].firstMatch
            XCTAssertTrue(banner.waitForExistence(timeout: 15), hold)
            XCTAssertTrue(banner.staticTexts[words].exists, "\(hold): \(words)")
            XCTAssertEqual(app.buttons["chat.connection.retry"].exists, offersRetry, hold)
            // The island follows the same state a moment later.
            Thread.sleep(forTimeInterval: 1.2)
            save("chat-\(hold)", app)
            app.terminate()
        }
    }

    @MainActor
    func testHostSetupDrawsTheCheckThenTheConnection() throws {
        var app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-test-host-setup", "connecting"]
        app.launch()
        var line = app.descendants(matching: .any)["connection.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        XCTAssertTrue(line.label.contains("to Studio Mac: Connecting…"), line.label)
        XCTAssertFalse(app.descendants(matching: .any)["host-setup.error"].exists)
        save("setup-connecting", app)
        app.terminate()

        // A check that connects after a moment turns the same line connected.
        app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-test-host-setup", "check"]
        app.launch()
        line = app.descendants(matching: .any)["connection.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        let connected = NSPredicate(format: "label CONTAINS %@", "to Studio Mac: Connected")
        expectation(for: connected, evaluatedWith: line)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["host-setup.continue"].waitForExistence(timeout: 5), "Start chatting follows")
        save("setup-connected", app)
    }

    /// A real check: an address that never answers keeps the line connecting.
    @MainActor
    func testCheckingAnAddressShowsTheLineUntilItAnswers() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText("10.255.255.1")
        let connect = app.buttons["host-setup.connect-host"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let line = app.descendants(matching: .any)["connection.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "The check shows while it runs")
        XCTAssertTrue(line.label.contains("to 10.255.255.1: Connecting…"), line.label)
        save("setup-real-check", app)
    }

    @MainActor
    func testAllAgentsMarksHostsStillLoadingOrOutOfReach() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES",
                               "-test-fleet-loading"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].waitForExistence(timeout: 15))
        let away = app.descendants(matching: .any)["fleet.host-note.Office Linux"].firstMatch
        XCTAssertTrue(away.waitForExistence(timeout: 10), "A host out of reach says so")
        XCTAssertTrue(away.staticTexts["Couldn't reach this host."].exists, "With its reason")
        XCTAssertTrue(app.staticTexts["Loading Studio Mac…"].waitForExistence(timeout: 5), "A host still loading says so")
        XCTAssertTrue(app.buttons["fleet.filter.Studio Mac"].exists)
        save("all-agents", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CONNECTION_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
