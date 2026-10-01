import XCTest

/// A Hermes address behind a proxy that asks for a username and password
/// (HTTP basic auth). Needs a real proxy: set BIGHELP_PROXY_PROBE (TEST_RUNNER_…)
/// to "address|username|password" for a plain-HTTP private address.
final class HostSetupProxyPasswordUITests: BighelpUITestCase {
    @MainActor
    func testPasswordProtectedAddressAsksForUsernameAndPasswordThenConnects() throws {
        guard let probe = ProcessInfo.processInfo.environment["BIGHELP_PROXY_PROBE"] else {
            throw XCTSkip("Requires a basic-auth proxy in front of Hermes")
        }
        var parts = probe.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        // A fresh name each run: a password saved for an address is sent
        // automatically, and a test can't clear the app's Keychain.
        if parts[0].hasPrefix("localhost:") {
            parts[0] = "proxy-\(UUID().uuidString.prefix(8).lowercased()).\(parts[0])"
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()

        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.typeText(parts[0])

        // No password yet: the next step asks for one, instead of claiming a
        // password was rejected.
        let connect = app.buttons["host-setup.connect-host"]
        tap(connect, in: app)
        XCTAssertTrue(app.staticTexts["Password needed"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["host-setup.error"].exists)
        let username = app.textFields["host-setup.proxy-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 3))
        save("proxy-1-asks", app)

        username.tap()
        username.typeText(parts[1])
        let password = app.secureTextFields["host-setup.proxy-password-field"]
        password.tap()
        password.typeText("wrong password")
        tap(connect, in: app)
        let rejected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "username and password didn't work")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 15))
        save("proxy-2-rejected", app)

        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + parts[2])
        tap(connect, in: app)
        let next = app.buttons["host-setup.continue"]
        // With the password, Hermes's own sign-in comes next, unless it needs none.
        if !next.waitForExistence(timeout: 20), app.buttons["direct-hermes.auth-picker"].exists {
            save("proxy-3-sign-in", app)
            tap(connect, in: app)
        }
        XCTAssertTrue(next.waitForExistence(timeout: 30), "Connects through the proxy, sockets included")
        save("proxy-4-connected", app)
    }

    /// A single sign-on login page at the proxy, and a proxy that refuses outright:
    /// neither can be signed in from the app, so each gets a plain explanation.
    /// BIGHELP_GATE_PROBE is "login-page address|refusing address".
    @MainActor
    func testLoginPageAndRefusingProxiesAreExplained() throws {
        guard let probe = ProcessInfo.processInfo.environment["BIGHELP_GATE_PROBE"] else {
            throw XCTSkip("Requires proxies that redirect and refuse")
        }
        let addresses = probe.components(separatedBy: "|")
        XCTAssertEqual(addresses.count, 2)
        guard addresses.count == 2 else { return }
        for (index, expected) in [(0, "login page"), (1, "turned bighelp away")] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
            app.launch()
            let address = app.textFields["host-setup.address"]
            XCTAssertTrue(address.waitForExistence(timeout: 8))
            address.tap()
            address.typeText(addresses[index])
            tap(app.buttons["host-setup.connect-host"], in: app)
            let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 15), expected)
            save(index == 0 ? "gate-login-page" : "gate-refused", app)
            app.terminate()
        }
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        element.tap()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CONNECTION_OPTIONS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
