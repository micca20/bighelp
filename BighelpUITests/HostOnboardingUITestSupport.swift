import XCTest

/// Real onboarding against an open (no sign-in) isolated host from
/// Scripts/HostSignInMatrixProbe.py, for tests that run without demo fixtures.
extension BighelpUITestCase {
    @MainActor func onboardOpenHost(_ app: XCUIApplication, address: String) throws {
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Before typing: with the keyboard up, the floating Continue button covers
        // Advanced connection and the tap connects over HTTPS instead.
        app.buttons["Advanced connection"].firstMatch.tap()
        let http = app.switches["direct-hermes.private-http"]
        XCTAssertTrue(http.waitForExistence(timeout: 3))
        (http.switches.firstMatch.exists ? http.switches.firstMatch : http).tap()
        field.tap()
        field.typeText(address)
        // During onboarding the button reports the screen's identifier.
        let connect = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch
        let next = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND (label == %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], "Start chatting", "Let")).firstMatch
        // An open host needs no sign-in: Connect, then possibly Connect again on the method step.
        for _ in 0..<3 where !next.exists {
            for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
            if connect.exists { connect.tap() }
            _ = next.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Connected")
        next.tap()
    }
}
