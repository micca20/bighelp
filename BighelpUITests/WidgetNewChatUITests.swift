import XCTest

/// The home screen widget's New Chat opens the app from the background with a
/// link naming the agent it last drew. It must open a real, sendable chat.
final class WidgetNewChatUITests: BighelpUITestCase {
    @MainActor
    func testWidgetNewChatFromBackgroundOpensASendableChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))

        // An agent the widget remembers but that has since been deleted.
        app.open(URL(string: "loopdy://new-chat?agent=deleted-agent")!)
        let composer = app.textViews["chat.composer.text"]
        let opened = composer.waitForExistence(timeout: 20)
        let alert = app.alerts.firstMatch
        XCTAssertFalse(alert.exists, alert.exists ? alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ") : "")
        XCTAssertTrue(opened, "The widget opens a new chat")
        composer.tap()
        composer.typeText("Hello from the widget")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        wait(for: [enabled], timeout: 10)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "widget-new-chat"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
