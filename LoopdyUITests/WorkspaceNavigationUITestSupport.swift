import XCTest

extension LoopdyUITestCase {
    @MainActor
    func openRootDestination(_ destination: String, sidebarIdentifier: String,
                             in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let persistentDestination = app.buttons["root.destination.\(destination)"].firstMatch
        let sidebar = app.collectionViews["root.sidebar"]
        if sidebar.exists {
            // AX can call a row hittable while its center is under the bottom toolbar.
            // Scroll the real sidebar before the one navigation tap.
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.buttons.matching(identifier: "root.new-chat").allElementsBoundByIndex
                .filter { $0.frame.midX > sidebar.frame.maxX && $0.frame.midY > sidebar.frame.midY }
                .map { $0.frame.minY }.min() ?? sidebar.frame.maxY
            let destinationIDs = ["chats", "agents", "scheduledTasks", "activity", "workspace",
                                  "directLinks", "diagnostics", "settings"].map { "root.destination.\($0)" }
            for _ in 0..<8 {
                if persistentDestination.exists && persistentDestination.isHittable
                    && persistentDestination.frame.minY >= top
                    && persistentDestination.frame.maxY <= bottom {
                    persistentDestination.tap()
                    return
                }
                let firstVisibleIndex = sidebar.buttons.allElementsBoundByIndex
                    .compactMap { destinationIDs.firstIndex(of: $0.identifier) }.min() ?? 0
                let targetIndex = destinationIDs.firstIndex(of: "root.destination.\(destination)") ?? 0
                let moveDown = persistentDestination.exists
                    ? persistentDestination.frame.minY < top
                    : targetIndex < firstVisibleIndex
                let upper = sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45))
                let lower = sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.68))
                // A full flick can skip the target and virtualize it out of the AX tree.
                (moveDown ? upper : lower).press(forDuration: 0.05,
                    thenDragTo: moveDown ? lower : upper, withVelocity: .slow,
                    thenHoldForDuration: 0.1)
            }
            XCTFail("Persistent sidebar destination must be fully visible: \(destination)",
                    file: file, line: line)
        } else {
            openSidebarDestination(sidebarIdentifier, in: app, file: file, line: line)
        }
    }

    @MainActor
    func openAgents(in app: XCUIApplication,
                    file: StaticString = #filePath, line: UInt = #line) {
        openRootTab("tab.agents", in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 5),
                      "Agents must remain reachable through the current native navigation.",
                      file: file, line: line)
    }

    @MainActor
    func openSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Settings sits in ☰ on iPhone and in the sidebar on iPad.
        openRootTab("tab.profile", in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 5),
                      "The Settings destination must open through the current sidebar.", file: file, line: line)
    }

    /// Root lists keep search under the large title; it appears on pull-down.
    @MainActor
    @discardableResult
    func revealSearchField(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        if field.waitForExistence(timeout: 2) { return true }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        // Tap the status bar (iOS scroll-to-top), then flick and pull down past
        // the top edge, which is what reveals the search field.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
        if field.waitForExistence(timeout: 1) { return true }
        for _ in 0..<12 {
            list.swipeDown()
            if field.waitForExistence(timeout: 0.5) { return true }
        }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        return field.waitForExistence(timeout: 2)
    }

    @MainActor
    func openActivity(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSidebarDestination("quick-workspace.menu.home", in: app, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.screen"].firstMatch.waitForExistence(timeout: 5),
                      "The Activity destination must open through the current sidebar.", file: file, line: line)
    }

    @MainActor
    func openChatWorkspaceMenu(in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 8), "The chat header must expose its options menu.",
                      file: file, line: line)
        guard options.exists else { return }
        options.tap()
        let workspace = app.buttons["chat.workspace-menu"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 5),
                      "The chat options menu must offer the Quick Workspace entry.", file: file, line: line)
        guard workspace.exists else { return }
        workspace.tap()
    }

    @MainActor
    func openSidebarDestination(_ identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let destinations = app.buttons.matching(identifier: identifier)
        // A persistent iPad sidebar already exposes the same destination.
        if !destinations.allElementsBoundByIndex.contains(where: \.isHittable) {
            let rootMenu = app.buttons["quick-workspace.menu"].firstMatch
            let chatOptions = app.buttons["chat.options"].firstMatch
            let nestedMenu = app.buttons["workspace.menu"].firstMatch
            if !(rootMenu.exists && rootMenu.isHittable) && chatOptions.exists && chatOptions.isHittable {
                // The chat header's Quick Workspace entry now lives inside the ⋯ menu.
                openChatWorkspaceMenu(in: app, file: file, line: line)
            } else {
                let menu = rootMenu.exists && rootMenu.isHittable ? rootMenu : nestedMenu
                XCTAssertTrue(menu.waitForExistence(timeout: 8), "The visible screen must expose its sidebar.",
                              file: file, line: line)
                guard menu.exists else { return }
                menu.tap()
            }
        }
        let nativeMenu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        for _ in 0..<8 where !destinations.allElementsBoundByIndex.contains(where: \.isHittable) {
            if nativeMenu.exists { nativeMenu.swipeUp() }
        }
        let destination = destinations.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(destination, "Sidebar destination must be reachable: \(identifier)",
                        file: file, line: line)
        guard let destination else { return }
        destination.tap()
    }
}
