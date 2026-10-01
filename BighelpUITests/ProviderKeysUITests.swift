import XCTest

/// Settings › Hermes Tools › Provider Keys on demo data: what you have first, a
/// sign-in that finishes on its own, terminal-only sign-ins run by the host's
/// own tools, adding a key, and search.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ProviderKeysUITests: BighelpUITestCase {
    @MainActor
    func testSignInFinishesOnItsOwnAndEverythingElseIsOneTapAway() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openProviderKeys(in: app)

            XCTAssertTrue(app.descendants(matching: .any)["providers.connected.account:nous"].firstMatch.exists,
                          "Signed-in accounts are listed first")
            XCTAssertTrue(app.descendants(matching: .any)["providers.connected.key:OPENROUTER_API_KEY"].firstMatch.exists)
            evidence("overview-\(appearance)")

            let signIn = app.buttons["providers.sign-in.openai-codex"]
            XCTAssertTrue(signIn.waitForExistence(timeout: 5))
            signIn.tap()
            let code = app.staticTexts["providers.sign-in.code"]
            XCTAssertTrue(code.waitForExistence(timeout: 8), "The sign-in shows its code")
            XCTAssertTrue(app.buttons["Copied"].exists, "The code is copied for pasting")
            evidence("sign-in-\(appearance)")
            let connected = app.descendants(matching: .any)["providers.sign-in.connected"].firstMatch
            XCTAssertTrue(connected.waitForExistence(timeout: 15), "Hermes' approval shows without another tap")
            evidence("connected-\(appearance)")
            XCTAssertTrue(connected.waitForNonExistence(timeout: 6), "The sheet closes itself")
            XCTAssertTrue(app.descendants(matching: .any)["providers.connected.account:openai-codex"].firstMatch
                .waitForExistence(timeout: 5), "The new account joins Your providers")

            guard appearance == "light" else { app.terminate(); continue }
            let addKey = app.buttons["providers.add-key"]
            for _ in 0..<4 where !addKey.isHittable { app.swipeUp() }
            addKey.tap()
            XCTAssertTrue(app.buttons["providers.key-choice.ANTHROPIC_API_KEY"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["providers.key-choice.OPENAI_BASE_URL"].exists, "Only keys, not settings")
            evidence("add-key")
            app.navigationBars.buttons.element(boundBy: 0).tap()

            let search = app.searchFields["Search providers"]
            for _ in 0..<6 where !search.isHittable { app.swipeDown() }
            search.tap()
            search.typeText("grok")
            XCTAssertTrue(app.buttons["providers.sign-in.xai-oauth"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.descendants(matching: .any)["providers.connected.account:nous"].firstMatch.exists,
                           "Search hides providers it doesn't name")
            evidence("search")
            app.terminate()
        }
    }

    /// Accounts Hermes only signs in to from a terminal: the host runs the
    /// provider's own tool, and the phone shows its code or takes the page's code.
    @MainActor
    func testTerminalOnlyAccountsSignInFromThePhone() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openProviderKeys(in: app)

            // GitHub Copilot: a code, and GitHub confirms on its own.
            let copilot = app.buttons["providers.sign-in.copilot"]
            for _ in 0..<4 where !copilot.isHittable { app.swipeUp() }
            copilot.tap()
            XCTAssertTrue(app.staticTexts["providers.sign-in.code"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["providers.sign-in.code"].label, "Sign-in code H J K L - 4 8 2 1")
            evidence("host-device-\(appearance)")
            let connected = app.descendants(matching: .any)["providers.sign-in.connected"].firstMatch
            XCTAssertTrue(connected.waitForExistence(timeout: 15))
            XCTAssertTrue(connected.waitForNonExistence(timeout: 6), "The sheet closes itself")
            // Hermes keeps GitHub Copilot as a token, so it joins Your providers as one.
            let copilotToken = app.descendants(matching: .any)["providers.connected.key:COPILOT_GITHUB_TOKEN"].firstMatch
            for _ in 0..<4 where !copilotToken.waitForExistence(timeout: 2) { app.swipeDown() }
            XCTAssertTrue(copilotToken.exists, "GitHub Copilot joins Your providers")
            XCTAssertFalse(app.buttons["providers.sign-in.copilot"].exists, "…and leaves the sign-in list")

            // Claude through Claude Code: open the page, paste its code back. A wrong code says so.
            let claude = app.buttons["providers.sign-in.claude-subscription-directsdk-experimental"]
            for _ in 0..<4 where !claude.isHittable { app.swipeUp() }
            claude.tap()
            XCTAssertTrue(app.buttons["providers.sign-in.continue"].waitForExistence(timeout: 8))
            let field = app.secureTextFields["providers.oauth.completion-code"]
            XCTAssertTrue(field.exists)
            evidence("host-paste-\(appearance)")
            field.tap()
            field.typeText("wrong-code")
            app.buttons["providers.sign-in.finish"].tap()
            let failure = app.staticTexts["providers.sign-in.failure"]
            XCTAssertTrue(failure.waitForExistence(timeout: 8))
            XCTAssertEqual(failure.label, "Claude Code didn't accept that code. Try again.")
            evidence("host-paste-wrong-\(appearance)")
            app.buttons["providers.sign-in.retry"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            field.tap()
            field.typeText("page#code")
            app.buttons["providers.sign-in.finish"].tap()
            XCTAssertTrue(connected.waitForExistence(timeout: 15))
            XCTAssertTrue(connected.waitForNonExistence(timeout: 6))
            let claudeConnected = app.descendants(matching: .any)[
                "providers.connected.account:claude-subscription-directsdk-experimental"].firstMatch
            for _ in 0..<4 where !claudeConnected.waitForExistence(timeout: 2) { app.swipeDown() }
            XCTAssertTrue(claudeConnected.exists, "Claude Code's own check moves it to Your providers")
            evidence("host-connected-\(appearance)")

            guard appearance == "light" else { app.terminate(); continue }
            // The Copilot CLI isn't on the demo computer: what to install.
            let acp = app.descendants(matching: .any)["providers.signin-row.copilot-acp"].firstMatch
            for _ in 0..<4 where !acp.isHittable { app.swipeUp() }
            acp.tap()
            XCTAssertTrue(app.staticTexts["providers.computer.install"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["providers.computer.install"].label, "npm install -g @github/copilot")
            evidence("host-needs-tool")
            app.navigationBars.buttons.element(boundBy: 0).tap()

            // Qwen ended its sign-in: say so, and offer its key instead.
            let qwen = app.descendants(matching: .any)["providers.signin-row.qwen-oauth"].firstMatch
            for _ in 0..<4 where !qwen.isHittable { app.swipeUp() }
            qwen.tap()
            XCTAssertTrue(app.staticTexts["providers.retired.message"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["providers.retired.add-key"].exists)
            evidence("host-retired")
            app.terminate()
        }
    }

    @MainActor
    private func openProviderKeys(in app: XCUIApplication) {
        openHermesTool("keys", in: app)
        // A tap that lands while the list is still settling doesn't open the row; tap it again.
        let row = app.buttons["workspace.open.keys"].firstMatch
        if !app.navigationBars["Provider Keys"].waitForExistence(timeout: 4), row.exists, row.isHittable {
            row.tap()
        }
        XCTAssertTrue(app.navigationBars["Provider Keys"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["providers.connected.account:nous"].firstMatch
            .waitForExistence(timeout: 8))
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "provider-keys-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("provider-keys-\(name).png"))
    }
}
