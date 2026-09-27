import XCTest

/// Every way a stock Hermes host can ask for sign-in, against real isolated
/// hosts started by Scripts/HostSignInMatrixProbe.py (BIGHELP_SIGNIN_PROBE).
/// Skipped without it.
final class HostSignInMatrixUITests: BighelpUITestCase {
    private struct BrowserMissing: Error {}
    private var probe: [String: String] = [:]

    // MARK: No sign-in

    @MainActor func testOpenHostPrefersNoSignIn() throws {
        let app = try beginSetup(mode: "open")
        XCTAssertTrue(methodDetail(app).contains("No sign-in is required"), "An open host needs no sign-in")
        save("open-1-no-sign-in", app)
        try connect(app)
    }

    @MainActor func testOpenHostAcceptsItsSessionToken() throws {
        let app = try beginSetup(mode: "open")
        choose("Session token", in: app)
        let token = app.secureTextFields["direct-hermes.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 3))
        token.tap()
        token.typeText(try XCTUnwrap(probe["session_token"]))
        try connect(app)
    }

    // MARK: Hermes's username/password provider

    @MainActor func testPasswordOnlyHostPrefersUsernameAndPasswordAndChats() throws {
        let app = try beginSetup(mode: "password")
        // Every sign-in provider takes a password, so that's the form shown.
        XCTAssertTrue(methodDetail(app).contains("username and password"), methodDetail(app))
        try typeCredentials(app, password: try XCTUnwrap(probe["password"]))
        save("password-1-form", app)
        try connect(app)
        app.buttons["host-setup.continue"].tap()
        // A new host has no chats yet: start the first one.
        let firstChat = app.buttons["sessions.empty.new-chat"]
        if firstChat.waitForExistence(timeout: 10) {
            firstChat.tap()
            confirmNewChatPicker(in: app)
        }
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A chat opens after connecting")
        composer.tap()
        composer.typeText("Run pwd once, then finish the direct streaming fixture.")
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Direct streaming fixture complete.", "Direct streaming fixture complete."))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "The signed-in session can chat")
        save("password-2-chat", app)
    }

    @MainActor func testWrongPasswordIsExplained() throws {
        let app = try beginSetup(mode: "password")
        try typeCredentials(app, password: "not-the-password")
        tapConnect(app)
        let rejected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "rejected these credentials")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["host-setup.continue"].exists)
        save("password-3-wrong", app)
    }

    @MainActor func testAccessToken() throws {
        let app = try beginSetup(mode: "password")
        choose("Access token", in: app)
        let token = app.secureTextFields["direct-hermes.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 3))
        token.tap()
        token.typeText(try XCTUnwrap(probe["token"]))
        try connect(app)
    }

    @MainActor func testBrowserSignInThroughHermesLoginPage() throws {
        let app = try beginSetup(mode: "password")
        choose("Browser sign-in", in: app)
        tapConnect(app)
        let web = try browser(app)
        let user = web.textFields.firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 15), "Hermes's login page opens in the browser")
        user.tap()
        user.typeText(try XCTUnwrap(probe["username"]))
        // Native Tab moves focus without tapping WebKit's stale pre-keyboard frame.
        user.typeText("\t")
        web.secureTextFields.firstMatch.typeText(try XCTUnwrap(probe["password"]))
        save("browser-1-hermes-login", app)
        let submit = web.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign in")).firstMatch
        XCTAssertTrue(submit.exists)
        submit.tap()
        try expectConnected(app)
    }

    // MARK: Single sign-on (self-hosted OpenID Connect)

    @MainActor func testSingleSignOnThroughIdentityProvider() throws {
        let app = try beginSetup(mode: "sso")
        // Not every provider takes a password here, so the browser leads.
        XCTAssertTrue(methodDetail(app).contains("in Safari"), methodDetail(app))
        XCTAssertTrue(app.buttons["host-setup.provider"].exists, "Two providers: the person picks one")
        app.buttons["host-setup.provider"].tap()
        app.buttons["Self-Hosted OIDC"].tap()
        save("sso-1-provider", app)
        tapConnect(app)
        let web = try browser(app)
        let approve = web.buttons["Approve sign-in"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "The identity provider's page opens")
        save("sso-2-identity-provider", app)
        approve.tap()
        try expectConnected(app)
    }

    // MARK: Helpers

    @MainActor private func beginSetup(mode: String) throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == mode else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "Sign-in and password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(try XCTUnwrap(probe["address"]))
        app.buttons["Advanced connection"].firstMatch.tap()
        let http = app.switches["direct-hermes.private-http"]
        XCTAssertTrue(http.waitForExistence(timeout: 3))
        (http.switches.firstMatch.exists ? http.switches.firstMatch : http).tap()
        tapConnect(app)
        XCTAssertTrue(methodPicker(app).waitForExistence(timeout: 30), "Discovery finds the host's sign-in methods")
        return app
    }

    /// The line under the method, which names what it does.
    @MainActor private func methodDetail(_ app: XCUIApplication) -> String {
        let detail = app.staticTexts["host-setup.method-detail"]
        _ = detail.waitForExistence(timeout: 3)
        return detail.label
    }

    @MainActor private func methodPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["direct-hermes.auth-picker"]
    }

    @MainActor private func choose(_ method: String, in app: XCUIApplication) {
        methodPicker(app).tap()
        let option = app.buttons[method]
        XCTAssertTrue(option.waitForExistence(timeout: 3), method)
        option.tap()
    }

    @MainActor private func typeCredentials(_ app: XCUIApplication, password: String) throws {
        let user = app.textFields["direct-hermes.username"]
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        user.typeText(try XCTUnwrap(probe["username"]))
        let secret = app.secureTextFields["direct-hermes.password"]
        secret.tap()
        secret.typeText(password)
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        let connect = app.buttons["host-setup.connect-host"]
        // The form draws rows lazily; the keyboard can hide the button.
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func connect(_ app: XCUIApplication) throws {
        tapConnect(app)
        try expectConnected(app)
    }

    @MainActor private func expectConnected(_ app: XCUIApplication) throws {
        app.activate()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        save("\(probe["mode"] ?? "")-connected-\(name.split(separator: " ").last ?? "")", app)
    }

    /// The system sign-in sheet: in-app web view or Safari's view service.
    @MainActor private func browser(_ app: XCUIApplication) throws -> XCUIElement {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Continue"].waitForExistence(timeout: 5) {
            springboard.alerts.buttons["Continue"].tap()
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if app.webViews.firstMatch.exists { return app.webViews.firstMatch }
            if safari.webViews.firstMatch.exists { return safari.webViews.firstMatch }
            Thread.sleep(forTimeInterval: 0.5)
        }
        save("browser-missing", app)
        XCTFail("No sign-in browser appeared")
        throw BrowserMissing()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
