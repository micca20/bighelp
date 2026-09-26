import XCTest
import UIKit

final class AgentsUITests: LoopdyUITestCase {
    @MainActor
    private func launch(appearance: String = "light", accessibility: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-test-agents-directory",
            "-loopdy.demo.appearance", appearance
        ]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        openAgents(in: app)
        XCTAssertTrue(revealSearchField(agentSearch(in: app), in: app))
        return app
    }

    @MainActor
    private func agentSearch(in app: XCUIApplication) -> XCUIElement {
        app.searchFields["Search agents and groups"].firstMatch
    }

    @MainActor
    func testAgentTapOpensChatRatherThanManagement() {
        let app = launch()
        let agent = app.buttons["agent.studio"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        agent.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["agent.actions"].exists)
    }

    @MainActor
    func testNativeSwipePinAndEditHaveVisibleManagementEquivalent() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap()
        search.typeText("Build\n")
        let row = app.buttons["agent.build"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()

        app.buttons["agent.build.more"].tap()
        let unpin = app.buttons["agent.build.pin"]
        for _ in 0..<6 where !unpin.exists || !unpin.isHittable {
            app.descendants(matching: .any)["agent.actions.list"].firstMatch.swipeUp()
        }
        XCTAssertTrue(unpin.waitForExistence(timeout: 3))
        XCTAssertEqual(unpin.label, "Unpin")
        unpin.tap()
        XCTAssertTrue(unpin.waitForNonExistence(timeout: 3))

        row.swipeLeft()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 5))
        app.buttons["agent.editor.cancel"].tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testGroupTapOpensChatAndSearchMatchesMembers() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap()
        search.typeText("Field Notes\n")
        let group = app.buttons["agents.group.research-circle"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(group.label.contains("3 agents"))
        group.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testGroupGesturesAndRenameMenu() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap(); search.typeText("Field Notes\n")
        let row = app.buttons["agents.group.research-circle"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3)); pin.tap()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 3))
        app.buttons["Unpin"].tap()
        row.press(forDuration: 1)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.alerts["Rename group"].waitForExistence(timeout: 3))
        let name = app.alerts.textFields.firstMatch
        name.tap(); name.typeText(" Renamed")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let renamed = NSPredicate(format: "label CONTAINS %@", "Renamed")
        expectation(for: renamed, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        row.swipeLeft()
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3)); archive.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        app.buttons["agents.groups.archived-toggle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        app.buttons["Unarchive"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testEditorCancellationRequiresConfirmationOnlyForUnsavedChanges() {
        let app = launch()
        app.buttons["agent.studio.more"].tap()
        app.buttons["agent.studio.edit"].tap()
        let name = app.textFields["agent.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Updated")
        app.buttons["agent.editor.cancel"].tap()
        let keep = app.buttons["Keep editing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        XCTAssertTrue(name.exists)
        XCTAssertTrue((name.value as? String)?.contains("Updated") == true)
        app.buttons["agent.editor.cancel"].tap()
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testLastRowClearsSearchAndNavigationInPortraitAndLandscape() {
        verifyClearance(accessibility: false, appearance: "light")
    }

    @MainActor
    func testAccessibilityTextClearsSearchInDarkMode() {
        verifyClearance(accessibility: true, appearance: "dark")
    }

    @MainActor
    private func verifyClearance(accessibility: Bool, appearance: String) {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(appearance: appearance, accessibility: accessibility)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let list = app.descendants(matching: .any)["agents.screen"].firstMatch
            let lastRow = app.buttons["agent.long-name"]
            let search = agentSearch(in: app)
            XCTAssertTrue(revealSearchField(search, in: app))
            for _ in 0..<24 {
                if lastRow.exists, lastRow.isHittable { break }
                list.swipeUp()
            }
            XCTAssertTrue(lastRow.exists)
            XCTAssertTrue(lastRow.isHittable)
            let manage = app.buttons["agent.long-name.more"]
            XCTAssertGreaterThanOrEqual(manage.frame.width, 44)
            XCTAssertGreaterThanOrEqual(manage.frame.height, 44)
            XCTAssertTrue(app.frame.intersects(lastRow.frame))
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "agents-clearance-\(appearance)-\(orientation.rawValue)-ax-\(accessibility)"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
