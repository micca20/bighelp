import XCTest

/// Settings › Appearance: bubble color and page picks apply live and stick, and
/// there's no second theme system to overwrite them.
final class AppearanceStudioUITests: BighelpUITestCase {
    @MainActor
    func testColorsStudioPicksBubbleAndPagesAndKeepsThem() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        let link = settingsRow("settings.themes", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearance.studio"].firstMatch.waitForExistence(timeout: 5))
        evidence("colors-default")

        let ocean = app.buttons["appearance.bubble.ocean"]
        XCTAssertTrue(ocean.waitForExistence(timeout: 3))
        ocean.tap()
        XCTAssertTrue(ocean.isSelected, "The picked bubble color shows as selected")
        let paper = app.buttons["appearance.light.paper"]
        for _ in 0..<3 where !paper.isHittable { app.swipeUp() }
        paper.tap()
        XCTAssertTrue(paper.isSelected)
        let black = app.buttons["appearance.dark.black"]
        for _ in 0..<3 where !black.isHittable { app.swipeUp() }
        black.tap()
        XCTAssertTrue(black.isSelected)
        XCTAssertFalse(app.buttons["appearance.more-themes"].exists, "Themes are gone; bubble colors are the one choice")
        let layout = app.buttons["settings.appearance.chat-layout"]
        for _ in 0..<3 where !layout.isHittable { app.swipeUp() }
        XCTAssertTrue(layout.isHittable, "Chat layout lives on the Appearance page")
        app.swipeDown()
        evidence("colors-ocean-paper-black")

        // Dark mode shows the Black page.
        app.segmentedControls["appearance.mode"].buttons["Dark"].tap()
        sleep(1)
        evidence("colors-dark")
        app.segmentedControls["appearance.mode"].buttons["Light"].tap()

        // The summary in Settings names the picks.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let summary = settingsRow("settings.themes", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.value as? String, "Ocean bubbles · Paper · Black")

        // Picks survive a relaunch.
        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertEqual(settingsRow("settings.themes", in: app).value as? String, "Ocean bubbles · Paper · Black")
    }

    /// Custom opens the system color picker; a custom color names itself in
    /// Settings and colors your own chat bubbles (checked in the screenshots).
    @MainActor
    func testCustomColorOpensThePickerAndColorsYourBubbles() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light", "-loopdy.appearance.customBubbleColor", "0E7C66"]
        app.launch()
        openSettings(in: app)
        let link = settingsRow("settings.themes", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertEqual(link.value as? String, "Custom bubbles · Cream · Graphite")
        link.tap()
        let custom = app.descendants(matching: .any)["appearance.bubble.custom"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["appearance.bubble.lavender"].isSelected, "A custom color replaces the preset")
        evidence("custom-selected")
        custom.tap()
        XCTAssertTrue(app.staticTexts["Custom bubble color"].waitForExistence(timeout: 5), "The system color picker opens")
        evidence("custom-picker")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any)["appearance.studio"].firstMatch.waitForExistence(timeout: 5))

        // Your own message in a chat, in light and dark mode.
        for appearance in ["light", "dark"] {
            app.terminate()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.demo.appearance", appearance, "-loopdy.appearance.customBubbleColor", "0E7C66"]
            app.launch()
            let menu = app.buttons["home.drawer.open"]
            XCTAssertTrue(menu.waitForExistence(timeout: 25))
            menu.tap()
            app.buttons["menu.chats"].tap()
            let chat = app.buttons["session.row.demo-travel"]
            XCTAssertTrue(chat.waitForExistence(timeout: 8))
            chat.tap()
            let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 8))
            let input = composer.textViews.firstMatch
            input.tap()
            input.typeText("Ship it")
            app.buttons["chat.send"].tap()
            sleep(3)
            evidence("custom-chat-bubble-\(appearance)")
        }
    }

    /// The picker opened only from a small spot in the middle of the swatch;
    /// taps on the rest of the circle or its name did nothing.
    @MainActor
    func testTappingAnywhereOnCustomOpensThePicker() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        let link = settingsRow("settings.themes", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let tile = app.buttons["appearance.bubble.custom"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(tile.label, "Custom bubble color")
        for _ in 0..<3 where !tile.isHittable { app.swipeUp() }
        sleep(1) // Let the page finish sliding in before reading where the swatch is.
        // The swatch is a 50-point circle with its name under it.
        let frame = tile.frame
        let circle = CGPoint(x: frame.midX, y: frame.minY + 25)
        let spots: [(String, CGPoint)] = [
            ("name", CGPoint(x: frame.midX, y: frame.maxY - 8)),
            ("left edge of the circle", CGPoint(x: circle.x - 18, y: circle.y)),
            ("top of the circle", CGPoint(x: circle.x + 6, y: circle.y - 17)),
            ("right edge of the circle", CGPoint(x: circle.x + 18, y: circle.y + 6)),
        ]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let picker = app.staticTexts["Custom bubble color"]
        for (spot, point) in spots {
            origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 4), "Tapping the \(spot) opens the color picker")
            guard picker.exists else { continue }
            evidence("custom-picker-from-\(spot.replacingOccurrences(of: " ", with: "-"))")
            closePicker(picker, in: app)
        }

        // Tap a color in the grid; it becomes your bubble color.
        tile.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        let grid = app.buttons["Grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 4))
        grid.tap()
        let segments = grid.frame
        origin.withOffset(CGVector(dx: segments.minX + 60, dy: segments.maxY + 140)).tap()
        sleep(1)
        evidence("custom-picker-grid")
        closePicker(picker, in: app)
        XCTAssertTrue(tile.isSelected, "The picked color is now your bubble color")
        evidence("custom-picked")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(settingsRow("settings.themes", in: app).value as? String, "Custom bubbles · Cream · Graphite")
    }

    @MainActor
    private func closePicker(_ picker: XCUIElement, in app: XCUIApplication) {
        // A sheet on iPhone has a close button; a popover on iPad closes from outside.
        let close = app.buttons["close"]
        let outside = app.otherElements["PopoverDismissRegion"]
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            XCTAssertTrue(outside.exists, "The picker can be closed")
            outside.tap()
        }
        let closed = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: picker)], timeout: 5),
                       .completed, "The close button closes the picker")
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "appearance-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("appearance-\(name).png"))
        }
    }
}
