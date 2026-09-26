import XCTest

final class FloatingTabBarUITests: BighelpUITestCase {
    private let destinations = [
        (root: "chats", sidebar: "quick-workspace.sessions"),
        (root: "agents", sidebar: "quick-workspace.menu.agents"),
        (root: "scheduledTasks", sidebar: "quick-workspace.menu.scheduled-tasks"),
        (root: "workspace", sidebar: "quick-workspace.hub"),
    ]

    @MainActor
    private func launch(version: String, appearance: String, accessibility: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.appearance.interface-version", version,
                               "-loopdy.demo.appearance", appearance]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testFourDestinationsShareIconAndCaptionGeometryInBothAppearances() {
        for version in ["v3"] {
            for appearance in ["light", "dark"] {
                let app = launch(version: version, appearance: appearance)
                assertNativeNavigationGeometry(app)
                openRootDestination("chats", sidebarIdentifier: "quick-workspace.sessions", in: app)
                assertNativeNavigationGeometry(app)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "navigation-\(version)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    @MainActor
    func testAccessibilityTextFitsUniformTargetsWithoutOverlapping() {
        let app = launch(version: "v3", appearance: "dark", accessibility: true)
        assertNativeNavigationGeometry(app)
    }

    @MainActor
    func testNewChatOpensChatWithoutLeavingRootNavigationVisible() {
        let app = launch(version: "v3", appearance: "light")
        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
    }

    /// Native rows behind a transparent modal must not receive drawer taps.
    @MainActor
    func testWorkspaceDrawerOwnsFirstTapAndRestoresRootAfterDismissal() {
        let app = launch(version: "v3", appearance: "light")
        openRootDestination("workspace", sidebarIdentifier: "quick-workspace.hub", in: app)
        let rootMenu = app.buttons["quick-workspace.menu"]
        let underlyingActivity = app.buttons["workspace.open.activity"]
        XCTAssertTrue(underlyingActivity.waitForExistence(timeout: 5))
        rootMenu.tap()
        let close = app.buttons["quick-workspace.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        // A transparent cover retains underlying AX elements, but not hit targets.
        XCTAssertFalse(underlyingActivity.isHittable, "The modal must block underlying native rows.")
        close.tap()
        XCTAssertTrue(underlyingActivity.waitForExistence(timeout: 5))
        XCTAssertTrue(underlyingActivity.isHittable)
        rootMenu.tap()
        let activity = app.buttons["quick-workspace.menu.home"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(activity.isHittable)
        activity.tap()
        XCTAssertTrue(app.collectionViews["dashboard.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-drawer-activity-first-tap"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Catches root tab content failing to inherit the custom navigation's reserved space.
    @MainActor
    func testSettingsFinalRowRemainsReachableWithoutRootNavigation() {
        let app = launch(version: "v3", appearance: "light")
        openSettings(in: app)
        let form = app.collectionViews["settings.screen"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<6 { form.swipeUp() }
        // With Nerd Mode on, "Display & data" is the final Advanced row.
        let lastRow = app.buttons["settings.advanced"]
        XCTAssertTrue(lastRow.exists)
        // Settings is a root tab; the tab bar must never cover its last row.
        XCTAssertTrue(lastRow.isHittable)
        let navigation = app.otherElements["primary-navigation"]
        if navigation.exists && navigation.isHittable {
            XCTAssertFalse(navigation.frame.intersects(lastRow.frame))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "profile-final-row-scroll-clearance"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, app.frame.maxY,
                                 "The whole final Settings row must remain inside the screen.")
        XCTAssertTrue(lastRow.isHittable)
    }

    @MainActor
    func testAllRootFinalItemsClearGlassNavigation() {
        let app = launch(version: "v3", appearance: "light")
        app.buttons["quick-workspace.menu"].tap()
        let chats = app.buttons["quick-workspace.sessions"]
        let agents = app.buttons["quick-workspace.menu.agents"]
        let tasks = app.buttons["quick-workspace.menu.scheduled-tasks"]
        let workspace = app.buttons["quick-workspace.hub"]
        for destination in [chats, agents, tasks, workspace] {
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            XCTAssertTrue(destination.isHittable)
            XCTAssertGreaterThanOrEqual(destination.frame.height, 44)
        }
        XCTAssertLessThan(chats.frame.maxY, agents.frame.midY,
                          "Conversation rooms stay above the Agents destination.")
        agents.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testAllRootFinalItemsClearExpandedAccessibilityNavigation() {
        assertRootScrollClearance(accessibility: true, landscape: false)
    }

    @MainActor
    func testAllRootFinalItemsClearGlassNavigationInLandscape() {
        assertRootScrollClearance(accessibility: false, landscape: true)
    }

    @MainActor
    private func assertRootScrollClearance(accessibility: Bool, landscape: Bool) {
        let app = launch(version: "v3", appearance: "light", accessibility: accessibility)
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.frame.width > app.frame.height
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        }
        defer { XCUIDevice.shared.orientation = .portrait }

        let routes = [
            (name: "agents", root: "agents", sidebar: "quick-workspace.menu.agents", screen: "agents.screen"),
            (name: "chats", root: "chats", sidebar: "quick-workspace.sessions", screen: "sessions.screen"),
            (name: "scheduled tasks", root: "scheduledTasks", sidebar: "quick-workspace.menu.scheduled-tasks", screen: "scheduled-tasks.screen"),
            (name: "workspace", root: "workspace", sidebar: "quick-workspace.hub", screen: "workspace.hub"),
            (name: "activity", root: "activity", sidebar: "quick-workspace.menu.home", screen: "dashboard.screen"),
        ]
        for route in routes {
            openRootDestination(route.root, sidebarIdentifier: route.sidebar, in: app)
            let screen = app.descendants(matching: .any)[route.screen].firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5), route.name)
            XCTAssertGreaterThan(screen.frame.height, 0, route.name)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "native-navigation-\(route.name)-\(accessibility ? "accessibility" : "standard")-\(landscape ? "landscape" : "portrait")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        openSettings(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch
            .waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertNativeNavigationGeometry(_ app: XCUIApplication,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let usesPersistentSidebar = app.buttons["root.destination.chats"].exists
        if !usesPersistentSidebar {
            app.buttons["quick-workspace.menu"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["navigation.menu"].firstMatch
                .waitForExistence(timeout: 5), file: file, line: line)
        }
        let buttons = destinations.map {
            app.buttons[usesPersistentSidebar ? "root.destination.\($0.root)" : $0.sidebar].firstMatch
        }
        var previousY: CGFloat = -.infinity
        for (index, button) in buttons.enumerated() {
            XCTAssertTrue(button.exists, destinations[index].root, file: file, line: line)
            XCTAssertTrue(button.isHittable, destinations[index].root, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, file: file, line: line)
            XCTAssertGreaterThan(button.frame.midY, previousY, file: file, line: line)
            previousY = button.frame.midY
            for prior in buttons[..<index] {
                XCTAssertFalse(button.frame.intersects(prior.frame), file: file, line: line)
            }
        }
        if !usesPersistentSidebar {
            app.buttons["quick-workspace.close"].tap()
        }
    }
}
