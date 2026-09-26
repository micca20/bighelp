import XCTest

/// The icon badge says "something arrived while you were away" and goes away
/// as soon as bighelp is opened.
final class AppBadgeUITests: BighelpUITestCase {
    @MainActor
    func testOpeningBighelpClearsTheIconBadge() throws {
        XCUIDevice.shared.orientation = .portrait
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-badge-on-background", "3"]
        app.launch()

        // Badges need notification permission.
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let allow = app.buttons["permissions.notification.allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
            let systemAllow = springboard.alerts.buttons["Allow"]
            if systemAllow.waitForExistence(timeout: 5) { systemAllow.tap() }
        }

        // Leaving the app stands in for a push that badges the icon.
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["bighelp"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        let badged = NSPredicate { _, _ in self.hasBadge(icon) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: badged, object: nil)], timeout: 10),
                       .completed, "The icon shows a badge while bighelp is away")
        attach("badge-while-away", springboard)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        // Leaving again without new pushes must not bring it back.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        sleep(3)
        attach("badge-after-opening", springboard)
        XCTAssertFalse(hasBadge(icon), "Opening bighelp clears the icon badge")
    }

    /// The red badge sits over the icon's top-right corner.
    @MainActor
    private func hasBadge(_ icon: XCUIElement) -> Bool {
        guard icon.exists, let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let scale = CGFloat(image.width) / XCUIScreen.main.screenshot().image.size.width
        let frame = icon.frame
        let corner = CGRect(x: (frame.maxX - frame.width * 0.3) * scale, y: (frame.minY - 8) * scale,
                            width: frame.width * 0.45 * scale, height: frame.height * 0.35 * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !corner.isEmpty, let crop = image.cropping(to: corner) else { return false }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
            where pixels[index] > 200 && pixels[index + 1] < 90 && pixels[index + 2] < 90 {
            red += 1
        }
        return red > 60
    }

    @MainActor
    private func attach(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
