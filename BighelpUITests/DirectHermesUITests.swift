import XCTest

final class DirectHermesUITests: BighelpUITestCase {
    @MainActor func testPasswordConnectSendAndReopenAgainstStockHost() throws { try exerciseConnection(mode: "password") }
    @MainActor func testTokenConnectSendAndReopenAgainstStockHost() throws { try exerciseConnection(mode: "token") }
    @MainActor func testBrowserConnectSendAndReopenAgainstStockHost() throws { try exerciseConnection(mode: "browser") }

    @MainActor func testBrowserCancellationAndBackgroundReturnRemainRetryable() throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the isolated stock Hermes fixture")
        }
        let config = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath:path)))
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures","-disable-demo-delays","-test-no-configured-hosts"]
        app.launch()
        let address=app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout:8))
        address.tap(); address.typeText(try XCTUnwrap(config["address"]))
        app.buttons["host-setup.connect-host"].tap()
        let picker=app.buttons["direct-hermes.auth-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout:20)); picker.tap()
        app.buttons["Browser sign-in"].tap()
        let connect=app.buttons["host-setup.connect-host"]
        for iteration in 0..<2 {
            XCTAssertTrue(connect.waitForExistence(timeout:8)); connect.tap()
            let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
            if springboard.alerts.buttons["Continue"].waitForExistence(timeout:2) { springboard.alerts.buttons["Continue"].tap() }
            let safari=XCUIApplication(bundleIdentifier:"com.apple.SafariViewService")
            let local=app.webViews.textFields.firstMatch.waitForExistence(timeout:8)
            XCTAssertTrue(local || safari.webViews.textFields.firstMatch.waitForExistence(timeout:8))
            addCapture(app,"browser-cancellation-before-\(iteration)")
            if iteration == 0 {
                let cancel = local ? app.buttons["Cancel"].firstMatch : safari.buttons["Cancel"].firstMatch
                XCTAssertTrue(cancel.exists); cancel.tap()
            } else {
                XCUIDevice.shared.press(.home)
                app.activate()
            }
            let ready=NSPredicate { _,_ in connect.exists && connect.isEnabled && connect.isHittable }
            expectation(for:ready,evaluatedWith:nil)
            waitForExpectations(timeout:10)
            XCTAssertFalse(app.buttons["host-setup.continue"].exists)
            addCapture(app,"browser-cancellation-after-\(iteration)")
        }
    }

    @MainActor
    private func exerciseConnection(mode: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the isolated stock Hermes fixture")
        }
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let monitor = addUIInterruptionMonitor(withDescription: "Credential and browser system prompts") { dialog in
            for label in ["Not Now", "Continue"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        address.tap()
        address.typeText(try XCTUnwrap(config["address"]))
        app.buttons["host-setup.connect-host"].tap()
        let picker = app.buttons["direct-hermes.auth-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        if mode != "password" {
            picker.tap()
            app.buttons[mode == "browser" ? "Browser sign-in" : "Access token"].tap()
        }
        if mode == "password" {
            let user = app.textFields["direct-hermes.username"]
            user.tap(); user.typeText(try XCTUnwrap(config["username"]))
            let password = app.secureTextFields["direct-hermes.password"]
            password.tap(); password.typeText(try XCTUnwrap(config["password"]) + "\n")
        } else if mode == "token" {
            let token = app.secureTextFields["direct-hermes.token"]
            token.tap(); token.typeText(try XCTUnwrap(config["token"]) + "\n")
        }
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<3 where !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        if mode == "browser" {
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if system.alerts.buttons["Continue"].waitForExistence(timeout: 3) { system.alerts.buttons["Continue"].tap() }
            let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            let inAppUser = app.webViews.textFields.firstMatch
            let browserUser = safari.webViews.textFields.firstMatch
            let inAppFound = inAppUser.waitForExistence(timeout: 8)
            let user = inAppFound ? inAppUser : browserUser
            XCTAssertTrue(user.waitForExistence(timeout: 8), "Real system browser must show the stock host login")
            guard user.exists else { addCapture(app, "browser-missing-login"); return }
            user.tap(); user.typeText(try XCTUnwrap(config["username"]))
            let password = inAppFound ? app.webViews.secureTextFields.firstMatch : safari.webViews.secureTextFields.firstMatch
            // Native Tab moves focus without tapping WebKit's stale pre-keyboard frame.
            user.typeText("\t")
            addCapture(app, "browser-password-focus")
            password.typeText(try XCTUnwrap(config["password"]))
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            let signIn = inAppFound ? app.webViews.buttons["SIGN IN"].firstMatch : safari.webViews.buttons["SIGN IN"].firstMatch
            XCTAssertTrue(signIn.exists)
            guard signIn.exists else { addCapture(app, "browser-submit-unavailable"); return }
            signIn.tap()
        }
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "Authenticated host must reach optional notifications")
        guard next.exists else { addCapture(app, "connect-failed-" + mode); return }
        addCapture(app, "host-connected-" + mode)
        next.tap()
        let newChat = app.buttons["direct-hermes.new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        let save = app.sheets["Save Password?"]
        if save.exists { save.buttons["Not Now"].tap() }
        newChat.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        guard composer.exists else { addCapture(app, "missing-chat-" + mode); return }
        XCTAssertFalse(app.buttons["chat.voice"].exists)
        XCTAssertFalse(app.buttons["chat.attachment"].exists)
        let identity = app.staticTexts["direct-hermes.identity"]
        XCTAssertTrue(identity.exists, "Native chat must lead with its actual conversation identity.")
        let controls = app.buttons["direct-hermes.controls"]
        XCTAssertTrue(controls.exists)
        XCTAssertGreaterThan(controls.frame.minY, composer.frame.minY - 100,
                             "Native model controls belong beside the draft, not in the header.")
        composer.tap()
        composer.typeText("Run pwd once, then finish the direct streaming fixture.")
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Direct streaming fixture complete.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        addCapture(app, "host-chat-" + mode)
        app.buttons["direct-hermes.sessions"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "direct-hermes.session.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Complete a second direct turn.")
        app.buttons["chat.send"].tap()
        let second = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Second direct fixture complete.")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 30))
    }

    @MainActor private func addCapture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}
