import XCTest

/// Custom headers for a reverse proxy in front of Hermes (issue #1), in the
/// host setup's More options.
final class HostCustomHeadersUITests: BighelpUITestCase {
    @MainActor
    func testCustomHeadersAreEnteredMaskedAndReservedNamesExplained() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("https://hermes.example.com")
        app.buttons["More options"].firstMatch.tap()
        let add = app.buttons["host-access.add-header"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        let name = app.textFields["host-access.header-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Authorization")
        let value = app.secureTextFields["host-access.header-value"]
        value.tap()
        value.typeText("Bearer abc")
        save("headers-1-entered", app)

        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<4 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        connect.tap()
        let reserved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "bighelp sets Authorization itself")).firstMatch
        XCTAssertTrue(reserved.waitForExistence(timeout: 5), "Reserved names are explained")
        save("headers-2-reserved", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_HEADERS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
