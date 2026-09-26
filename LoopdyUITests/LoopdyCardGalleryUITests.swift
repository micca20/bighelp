import XCTest

final class LoopdyCardGalleryUITests: LoopdyUITestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThreeUnrelatedCardsRenderFromTheSharedCatalog() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-use-loopdy-card-gallery"]
        app.launch()

        let menu = app.buttons["quick-workspace.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["quick-workspace.menu.home"].tap()

        let dashboard = app.descendants(matching: .any)["dashboard.screen"].firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))

        let identifiers = (0..<3).map { "dashboard.loopdy-card.loopdy-card-gallery-\($0)" }
        for identifier in identifiers {
            let card = app.descendants(matching: .any)[identifier]
            for _ in 0..<12 where !card.isHittable { dashboard.swipeUp() }
            XCTAssertTrue(card.waitForExistence(timeout: 3), identifier)
        }

        for value in ["Significant earthquakes", "Bitcoin", "Chicago weather", "$64,321.12", "Partly cloudy"] {
            let text = app.staticTexts[value]
            for _ in 0..<12 where !text.exists { dashboard.swipeDown() }
            for _ in 0..<12 where !text.exists { dashboard.swipeUp() }
            XCTAssertTrue(text.waitForExistence(timeout: 3), value)
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Loopdy Card gallery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
