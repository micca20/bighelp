import XCTest

/// Advanced connection: HTTP on any private network, and Cloudflare Access.
/// Set BIGHELP_CONNECTION_OPTIONS_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class HostSetupConnectionOptionsUITests: BighelpUITestCase {
    @MainActor
    func testAdvancedConnectionOffersPrivateHTTPAndCloudflareAccess() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        let options = app.buttons["Advanced connection"].firstMatch
        XCTAssertTrue(options.exists)
        options.tap()
        let http = app.switches["direct-hermes.private-http"]
        XCTAssertTrue(http.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "a VPN or Tailscale")).firstMatch.exists)
        let accessToggle = app.switches["host-setup.cloudflare-access"]
        for _ in 0..<3 where !accessToggle.isHittable { app.swipeUp() }
        (accessToggle.switches.firstMatch.exists ? accessToggle.switches.firstMatch : accessToggle).tap()
        let clientID = app.textFields["host-setup.cloudflare-client-id"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["host-setup.cloudflare-client-secret"].exists)
        save("connection-options", app)
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
