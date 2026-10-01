import XCTest

/// A YouTube link in a chat shows a video card; Play starts YouTube's player in
/// place. The card's title comes from demo data, but the player is the real one,
/// so this needs the network. Screenshots go to BIGHELP_UI_EVIDENCE when set.
final class YouTubeCardUITests: BighelpUITestCase {
    @MainActor
    func testPlayStartsTheVideoInTheChat() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "dark", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.chats"].tap()
        let chat = app.buttons["session.row.demo-travel"]
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        chat.tap()
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        let input = composer.textViews.firstMatch
        input.tap()
        input.typeText("Watch this: https://youtu.be/aqz-KE-bpKQ")
        app.buttons["chat.send"].tap()

        let play = app.buttons["youtube.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "A YouTube link shows a video card")
        XCTAssertTrue(app.buttons["youtube.open"].waitForExistence(timeout: 5))
        sleep(2)
        evidence("card")
        play.tap()
        let player = app.webViews["youtube.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "Play puts YouTube's player in the card")
        sleep(10)
        evidence("playing")
        for problem in ["Error 153", "Video player configuration error", "Video unavailable", "An error occurred"] {
            XCTAssertFalse(player.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", problem)).firstMatch.exists,
                           "YouTube refused the player: \(problem)")
        }
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "youtube-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("youtube-\(name).png"))
    }
}
