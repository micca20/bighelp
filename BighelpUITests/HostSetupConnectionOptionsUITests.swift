import XCTest

/// Host setup asks one thing at a time: the address, then only what the
/// address turns out to need. More options holds the rarely needed rest.
/// Set BIGHELP_CONNECTION_OPTIONS_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class HostSetupConnectionOptionsUITests: BighelpUITestCase {
    @MainActor
    func testMoreOptionsHoldsTheRestAndCloudflareAccessIsItsOwnStep() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["host-setup.port"].exists, "Only the address to start")
        save("setup-1-address", app)

        let options = app.buttons["More options"].firstMatch
        XCTAssertTrue(options.exists)
        options.tap()
        XCTAssertTrue(app.textFields["host-setup.port"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["host-setup.name"].exists)
        XCTAssertFalse(app.switches["direct-hermes.private-http"].exists, "HTTP on a private network is found, not switched on")
        save("setup-2-more-options", app)

        let accessStep = app.buttons["host-setup.choose-cloudflare-access"]
        for _ in 0..<3 where !accessStep.isHittable { app.swipeUp() }
        accessStep.tap()
        XCTAssertTrue(app.staticTexts["Cloudflare Access"].waitForExistence(timeout: 3))
        let clientID = app.textFields["host-setup.cloudflare-client-id"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["host-setup.cloudflare-client-secret"].exists)
        XCTAssertFalse(app.buttons["host-setup.connect-host"].isEnabled, "Continue waits for the token")
        save("setup-3-cloudflare-access", app)

        app.buttons["host-setup.back"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 3), "Back returns to the address")
        XCTAssertFalse(clientID.exists)
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
