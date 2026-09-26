import XCTest
import UIKit

final class AccountNameUITests: LoopdyUITestCase {
    @MainActor
    func testNameHasExplicitSaveAndSurvivesReopen() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        openProfileEditor(in: app)
        let field = app.textFields["profile.display-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let oldName = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        var name = "Maya \(UUID().uuidString.prefix(5))"
        field.typeText(name)
        let save = app.buttons["profile.save-name"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "A name-only edit must expose Save")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let status = app.staticTexts["profile.name-save-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("saved"))
        XCTAssertEqual(field.value as? String, name)
        saveEvidence(app, name: "account-name-saved-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(field.frame.height, 0)
        field.tap()
        field.typeText(" Lee")
        name += " Lee"
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        XCTAssertEqual(field.value as? String, name)
        XCTAssertFalse(app.keyboards.keys["space"].isHittable,
                       "Done must dismiss the usable software keyboard, including iPad's retained empty AX node.")
        // The grouped form can leave its confirmation row below the short
        // landscape viewport after scrolling the focused name into view.
        for _ in 0..<3 where !status.exists { app.swipeUp() }
        let saved = status.waitForExistence(timeout: 5)
        if !saved {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "account-name-landscape-save-status-missing"
            hierarchy.lifetime = .deleteOnSuccess
            add(hierarchy)
        }
        XCTAssertTrue(saved)
        if saved { XCTAssertTrue(status.label.localizedCaseInsensitiveContains("saved")) }
        saveEvidence(app, name: "account-name-saved-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app.launch()
        openProfileEditor(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name, "Saved name must survive process recreation")
    }

    @MainActor
    private func openProfileEditor(in app: XCUIApplication) {
        openRootTab("tab.profile", in: app, timeout: 8)
        XCTAssertTrue(app.textFields["profile.display-name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        for retired in ["profile.loopdy-link.account", "profile.loopdy-link.devices", "profile.loopdy-link.pair"] {
            XCTAssertFalse(app.buttons[retired].exists)
        }
    }

    @MainActor
    private func saveEvidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
