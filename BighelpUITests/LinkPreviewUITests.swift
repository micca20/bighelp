import XCTest

/// Web links show a preview card (picture, title, summary, site) in the Feed
/// and under chat messages. Demo runs use made-up previews, never the network.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class LinkPreviewUITests: BighelpUITestCase {
    @MainActor
    func testFeedAndChatShowLinkPreviews() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.demo.appearance", appearance, "-loopdy.settings.nerd-mode", "NO"]
            app.launch()

            let feedTab = app.buttons["tab.feed"]
            XCTAssertTrue(feedTab.waitForExistence(timeout: 20))
            feedTab.tap()
            let post = app.descendants(matching: .any)["board.feed.post.feed-2"]
            XCTAssertTrue(post.waitForExistence(timeout: 10))
            let feedCard = post.descendants(matching: .any)["link-preview"]
            for _ in 0..<4 where !(feedCard.exists && feedCard.isHittable) { app.swipeUp() }
            XCTAssertTrue(loaded(feedCard), "The Feed post's link shows the page's preview")
            sleep(1)
            evidence("feed-\(appearance)")

            app.terminate()
            app.launch()
            let menu = app.buttons["home.drawer.open"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
            app.buttons["menu.chats"].tap()
            let chat = app.buttons["session.row.demo-travel"]
            XCTAssertTrue(chat.waitForExistence(timeout: 8))
            chat.tap()
            let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 8))
            let input = composer.textViews.firstMatch
            input.tap()
            input.typeText("Here's the hotel: https://example.com/lisbon-hotel")
            app.buttons["chat.send"].tap()
            let chatCard = app.descendants(matching: .any).matching(identifier: "link-preview").firstMatch
            XCTAssertTrue(loaded(chatCard), "A link you send shows its preview under your message")
            sleep(2)
            evidence("chat-\(appearance)")
            app.terminate()
        }
    }

    /// The card has the page's own title, not just the site.
    @MainActor
    private func loaded(_ card: XCUIElement) -> Bool {
        let titled = NSPredicate(format: "exists == true AND label CONTAINS %@", "A story from example.com")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: titled, object: card)], timeout: 10)
            == .completed
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "link-preview-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("link-preview-\(name).png"))
    }
}
