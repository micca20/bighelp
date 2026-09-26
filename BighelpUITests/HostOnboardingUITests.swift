import XCTest

final class HostOnboardingUITests: BighelpUITestCase {
    @MainActor
    func testNewUserStartsWithWelcomeWithoutBighelpAccountGate() {
        let app = makeApp()
        app.launchArguments = ["-force-signed-out-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.get-started"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["link.account.mode.sign-up"].exists)
        XCTAssertFalse(app.buttons["direct-hermes.open"].exists)
    }

    @MainActor
    func testEmptyHostSetupOffersSeparatePortAfterAppearance() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts", "-force-signed-out-onboarding"]
        app.launch()
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        app.buttons["onboarding.customize-appearance"].tap()
        let next = app.buttons["onboarding.appearance.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
        let port = app.textFields["host-setup.port"]
        if !port.exists { app.otherElements["host-setup.options"].buttons.firstMatch.tap() }
        XCTAssertTrue(port.waitForExistence(timeout: 5))
    }
}
