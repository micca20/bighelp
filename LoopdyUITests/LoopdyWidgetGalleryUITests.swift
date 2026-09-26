import XCTest

/// Opens the real system widget gallery and proves iOS lists Loopdy's widgets.
/// Screenshots are attached for review. Skips instead of failing if the
/// Springboard gallery UI is unreachable on this simulator runtime.
final class LoopdyWidgetGalleryUITests: XCTestCase {
    func testLoopdyWidgetsAppearInTheSystemGallery() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))

        // Long-press empty Home Screen space to enter jiggle mode.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 2.0)
        let edit = springboard.buttons["Edit"]
        if edit.waitForExistence(timeout: 4) {
            edit.tap()
            let addWidget = springboard.buttons["Add Widget"]
            if addWidget.waitForExistence(timeout: 4) { addWidget.tap() }
        } else {
            let add = springboard.buttons["Add"].exists ? springboard.buttons["Add"] : springboard.buttons["Add Widget"]
            guard add.waitForExistence(timeout: 4) else { throw XCTSkip("Widget gallery entry point not found") }
            add.tap()
        }

        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) else { throw XCTSkip("Widget gallery search not found") }
        search.tap()
        search.typeText("Loopdy")
        attach(springboard, "gallery-search")

        let loopdy = springboard.cells.containing(.staticText, identifier: "Loopdy").firstMatch
        let loopdyText = springboard.staticTexts["Loopdy"].firstMatch
        XCTAssertTrue(loopdy.waitForExistence(timeout: 8) || loopdyText.waitForExistence(timeout: 2),
                      "iOS did not list Loopdy in the widget gallery")
        (loopdy.exists ? loopdy : loopdyText).tap()
        sleep(2)
        attach(springboard, "gallery-loopdy-page-1")
        let names = ["Active Sessions", "Scheduled Tasks", "New Chat", "Activity Feed"]
        var seen = Set<String>()
        for page in 2...8 {
            for name in names where springboard.staticTexts[name].exists { seen.insert(name) }
            if seen.count == names.count { break }
            springboard.swipeLeft()
            sleep(1)
            attach(springboard, "gallery-loopdy-page-\(page)")
        }
        XCTAssertEqual(seen, Set(names), "Widget gallery showed: \(seen.sorted())")
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }
}
