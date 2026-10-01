import XCTest

/// ☰ › Secure credential vault with demo data: the saved list, adding a
/// login, and unlocking a password manager.
final class CredentialVaultUITests: BighelpUITestCase {
    @MainActor func testAddALoginAndUnlockAPasswordManager() throws {
        try walkThrough(appearance: "light")
    }

    @MainActor func testVaultInDarkMode() throws {
        try walkThrough(appearance: "dark")
    }

    @MainActor private func walkThrough(appearance: String) throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-test-vault-import",
                                "-loopdy.demo.appearance", appearance]
        app.launch()
        openVault(in: app)
        XCTAssertTrue(app.navigationBars["Credential vault"].waitForExistence(timeout: 10))
        XCTAssertTrue(item("example.com", in: app).waitForExistence(timeout: 10), "Saved logins are listed")
        shot("vault-1-list-\(appearance)", app)

        app.buttons["vault.add"].tap()
        let site = app.textFields["vault.site"]
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        site.tap()
        site.typeText("news.example.net/signin")
        app.textFields["vault.username"].tap()
        app.textFields["vault.username"].typeText("sam")
        app.secureTextFields["vault.password"].tap()
        app.secureTextFields["vault.password"].typeText("made-up-pass")
        shot("vault-2-add-\(appearance)", app)
        app.buttons["vault.save"].tap()
        XCTAssertTrue(item("news.example.net", in: app).waitForExistence(timeout: 10), "The new login is listed")
        XCTAssertFalse(item("news.example.net", in: app).label.contains("Makes its own codes"),
                       "The password didn't land in the authenticator key")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "made-up-pass")).firstMatch.exists)

        // A made-up export: two new logins, one already saved, one row with no login.
        let importRow = app.buttons["vault.import"]
        for _ in 0..<4 where !importRow.isHittable { app.swipeUp() }
        importRow.tap()
        let summary = app.staticTexts["vault.import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Found 1 login to import."), summary.label)
        XCTAssertTrue(summary.label.contains("2 are already saved."), summary.label)
        XCTAssertTrue(summary.label.contains("1 row was skipped"), summary.label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "made-up")).firstMatch.exists,
                       "No password is shown")
        shot("vault-5-import-\(appearance)", app)
        app.buttons["vault.import-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["vault.import-done"].waitForExistence(timeout: 10))
        shot("vault-6-imported-\(appearance)", app)
        app.buttons["vault.import-close"].tap()
        XCTAssertTrue(item("shop.example.org", in: app).waitForExistence(timeout: 10), "The imported login is listed")

        let unlock = app.buttons["vault.unlock.onepassword"]
        for _ in 0..<4 where !unlock.isHittable { app.swipeUp() }
        unlock.tap()
        let master = app.secureTextFields["vault.master-password"]
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        master.typeText("made-up-master")
        shot("vault-3-unlock-\(appearance)", app)
        app.buttons["vault.unlock-confirm"].tap()
        XCTAssertTrue(app.buttons["vault.lock.onepassword"].waitForExistence(timeout: 10), "1Password is unlocked")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "vault.item.", "From 1Password"))
            .firstMatch.waitForExistence(timeout: 5), "Its logins show up")
        shot("vault-4-unlocked-\(appearance)", app)
    }

    @MainActor private func openVault(in app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let row = app.buttons["menu.vault"]
        let list = app.descendants(matching: .any)["navigation.menu"].firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { (list.exists ? list : app).swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The vault is in the menu")
        row.tap()
    }

    @MainActor private func item(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "vault.item.", label))
            .firstMatch
    }

    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
