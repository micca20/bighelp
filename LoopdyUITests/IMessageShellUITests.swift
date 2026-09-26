import XCTest

/// The conversation-first shell exercises production routes with isolated demo data.
final class IMessageShellUITests: LoopdyUITestCase {
    @MainActor
    func testBothSessionSurfacesUseRecentActivityWithPriority() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-session-organization",
                               "-loopdy.appearance.interface-version", "v3", "-loopdy.sessions.organizeByProjects", "NO"]
        app.launch()
        let screen = app.descendants(matching: .any)["sessions.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 8))
        func verify(_ ids: [String], prefix: String, container: XCUIElement) {
            let rows = ids.map { app.buttons[prefix + $0].firstMatch }
            for _ in 0..<8 where !rows.last!.isHittable { container.swipeUp() }
            for row in rows { XCTAssertTrue(row.exists, "Missing expected session") }
            for (first, second) in zip(rows, rows.dropFirst()) {
                XCTAssertTrue(first.frame.minY.isFinite && second.frame.minY.isFinite)
                XCTAssertLessThan(first.frame.minY, second.frame.minY)
            }
        }
        verify(["old-pin", "old-active", "new-active", "new-pin"], prefix: "session.row.", container: screen)
        attach("sessions-active-pinned-recency", app)
        verify(["loopdy-old", "demo-finance", "demo-travel"], prefix: "session.row.", container: screen)
        attach("sessions-ordinary-recency", app)
        app.buttons["quick-workspace.menu"].tap()
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        let recent = app.descendants(matching: .any)["navigation.recent-chats"].firstMatch
        for _ in 0..<8 where !recent.isHittable { menu.swipeUp() }
        XCTAssertTrue(recent.isHittable)
        recent.tap()
        verify(["old-pin", "old-active", "new-active", "new-pin"], prefix: "quick-workspace.session.", container: menu)
        attach("quick-sessions-priority-recency", app)
        verify(["loopdy-old", "demo-finance", "demo-travel"], prefix: "quick-workspace.session.", container: menu)
        attach("quick-sessions-ordinary-recency", app)
    }

    @MainActor
    private func launch(appearance: String = "light", largeText: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
                               "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.demo.appearance", appearance]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    @MainActor
    func testWorkspaceHubIsDistinctFromFolderPicker() {
        let app = launch()
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        app.buttons["quick-workspace.menu"].tap()
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        let workspace = app.buttons["quick-workspace.hub"]
        let exists = workspace.waitForExistence(timeout: 3)
        XCTAssertTrue(exists, "Workspace features must be reachable independently of the folder picker.")
        guard exists else { return }
        for _ in 0..<4 where !workspace.isHittable { menu.swipeUp() }
        XCTAssertTrue(workspace.isHittable)
        workspace.tap()
        let hub = app.descendants(matching: .any)["workspace.hub"].firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 5))
        attach("workspace-hub-root", app)
        let search = app.searchFields["Find a tool"]
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("Appearance")
        let appearance = app.buttons["workspace.open.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.detail.appearance"].firstMatch.waitForExistence(timeout: 5))
        attach("workspace-hub-appearance", app)
    }

    @MainActor
    func testNavigationAndAgentEditorUseClearBasicAndAdvancedSections() {
        let app = launch()
        app.buttons["quick-workspace.menu"].tap()
        let navigation = app.descendants(matching: .any)["navigation.menu"].firstMatch
        let nativeMenuExists = navigation.waitForExistence(timeout: 5)
        XCTAssertTrue(nativeMenuExists, "Navigation must use the new native list, not the old side popup.")
        guard nativeMenuExists else { return }
        attach("minimal-navigation", app)
        app.buttons["quick-workspace.menu.agents"].tap()
        let more = app.buttons["agent.finance.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let actions = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        let edit = app.buttons["agent.finance.edit"]
        for _ in 0..<5 where !edit.isHittable { actions.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["agent.editor.identity-header"].exists)
        XCTAssertTrue(app.staticTexts["agent.editor.behavior-header"].exists)
        XCTAssertTrue(app.textViews["agent.editor.instructions"].exists,
                      "Basic behavior stays editable, not buried in another menu.")
        XCTAssertFalse(app.staticTexts["Choose any Pet Companion or a PNG, JPEG, or HEIF photo. A static avatar is prepared locally before saving."].exists)
        attach("minimal-agent-editor", app)
        let editor = app.descendants(matching: .any)["agent.editor.edit"].firstMatch
        let advanced = app.buttons["agent.editor.advanced"]
        for _ in 0..<4 where !advanced.isHittable { editor.swipeUp() }
        XCTAssertTrue(advanced.isHittable)
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["agent.runtime.subagents.model"].waitForExistence(timeout: 3))
        attach("minimal-agent-advanced", app)
        app.navigationBars["Advanced"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Agent"].waitForExistence(timeout: 3))
        app.buttons["agent.editor.cancel"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 3))
    }

    @MainActor
    func testChatsLandFirstAndSettingsPreferencesReturnOnFirstTap() {
        let app = launch()
        let firstRow = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        // iPhone roots show the bottom tab bar; it must not cover the first chat.
        let navigation = app.otherElements["primary-navigation"]
        XCTAssertTrue(navigation.exists)
        XCTAssertFalse(navigation.frame.intersects(firstRow.frame))
        openRootTab("tab.profile", in: app, timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["profile.display-name"].waitForExistence(timeout: 5))
        let preference = app.switches["settings.chat.fold-completed-turns"].firstMatch
        let form = app.descendants(matching: .any)["settings.screen"].firstMatch
        for _ in 0..<8 where !preference.isHittable { form.swipeUp() }
        XCTAssertTrue(preference.isHittable, "Basic preferences stay directly editable.")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "settings-direct-control-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // Native forms expose an outer labeled switch and its inner UISwitch.
        let nativeSwitch = preference.switches.firstMatch
        XCTAssertTrue(nativeSwitch.exists && nativeSwitch.isHittable)
        let previous = preference.value as? String
        nativeSwitch.tap()
        XCTAssertNotEqual(preference.value as? String, previous)
        attach("chat-preferences", app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.buttons["session.row.demo-finance"].waitForExistence(timeout: 3))
        attach("conversation-first", app)
    }

    @MainActor
    func testChatUsesNativeBackAndKeepsDraftAfterIdentityMenu() {
        let app = launch()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.back"].exists, "A pushed chat must retain a native Back action.")
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("Keep this unsent draft")
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 3))
        assertSoftwareKeyboardClears(input, in: app)
        XCTAssertTrue(openChatInfo(in: app))
        let details = app.otherElements["chat.people-and-chat"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Info"].exists)
        attach("direct-chat-details", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 3))
        app.buttons["chat.options"].tap()
        XCTAssertTrue(app.buttons["chat.open-people"].waitForExistence(timeout: 3))
        app.tap()
        XCTAssertEqual(input.value as? String, "Keep this unsent draft")
        attach("chat-draft-native-navigation", app)
        app.buttons["chat.back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    @MainActor
    func testDarkChatAndComposerRemainReachableAtLargeText() {
        let app = launch(appearance: "dark", largeText: true)
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 5))
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("Readable draft")
        XCTAssertTrue(app.buttons["chat.send"].isHittable)
        XCTAssertTrue(app.buttons["chat.attachment"].isHittable)
        assertSoftwareKeyboardClears(input, in: app)
        attach("chat-dark-accessibility-keyboard", app)
    }

    @MainActor
    func testEverySettingsSectionUsesNativeNavigationAndReturnsToChats() {
        let app = launch(appearance: "dark")
        openRootTab("tab.profile", in: app, timeout: 10)
        let sections = [
            ("notifications", "Notifications"),
            ("permissions", "Device access"),
            ("connectivityAndNotifications", "Hermes connection")
        ]
        for (identifier, title) in sections {
            settingsRow("settings.menu.\(identifier)", in: app).tap()
            let navigation = app.navigationBars[title]
            XCTAssertTrue(navigation.waitForExistence(timeout: 5), title)
            attach("settings-\(identifier)-dark", app)
            navigation.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        }
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.buttons["session.row.demo-finance"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSecondaryDestinationsAndLandscapeChatStayReachable() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        for (route, screen) in [("agents", "agents.screen"),
                                ("scheduled-tasks", "scheduled-tasks.screen")] {
            app.buttons["quick-workspace.menu"].tap()
            let destination = app.buttons["quick-workspace.menu.\(route)"]
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            destination.tap()
            XCTAssertTrue(app.descendants(matching: .any)[screen].firstMatch.waitForExistence(timeout: 5))
            if route == "agents" {
                XCTAssertTrue(revealSearchField(app.searchFields["Search agents and groups"], in: app))
                XCTAssertTrue(app.buttons["agents.create"].exists)
            } else {
                XCTAssertTrue(app.buttons["scheduled-tasks.create"].exists)
            }
            attach("native-\(route)", app)
        }
        app.buttons["quick-workspace.menu"].tap()
        let chats = app.buttons["quick-workspace.sessions"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        chats.tap()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        XCTAssertTrue(row.isHittable)
        attach("chats-landscape", app)
        row.tap()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Landscape draft")
        XCTAssertTrue(app.buttons["chat.send"].isHittable)
        assertSoftwareKeyboardClears(input, in: app)
        attach("chat-landscape-keyboard", app)
    }

    @MainActor
    func testNativeModelAndReasoningSelectionPreservesDraft() {
        let app = launch()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Keep my model-choice draft")
        app.buttons["chat.options"].tap()
        let changeModel = app.buttons["chat.session-controls"]
        XCTAssertTrue(changeModel.waitForExistence(timeout: 3))
        changeModel.tap()
        let seeAll = app.buttons["chat.models.see-all"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 3))
        seeAll.tap()
        let search = app.searchFields["Search providers and models"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("gpt-5.6")
        let model = app.buttons["model-picker.openai.gpt-5.6"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        let reasoning = app.descendants(matching: .any)["model-picker.reasoning-slider"].firstMatch
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reasoning,")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let high = app.buttons["High"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 3))
        high.tap()
        XCTAssertEqual(reasoning.value as? String, "High")
        attach("native-model-reasoning", app)
        app.buttons["model-picker.apply"].tap()
        XCTAssertTrue(reasoning.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep my model-choice draft")
    }

    @MainActor
    func testPartnerThemeChatRetainsAccessibleWorkspaceMenu() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                               "-test-chat-sidebar-collapsed", "-preview-ui-v3",
                               "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.appearance.theme", "nous", "-loopdy.demo.appearance", "light"]
        app.launch()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Keep my themed draft")
        let options = app.buttons["chat.options"]
        XCTAssertTrue(options.isHittable)
        attach("partner-theme-chat", app)
        openChatWorkspaceMenu(in: app)
        XCTAssertTrue(app.buttons["quick-workspace.menu.agents"].waitForExistence(timeout: 5))
        attach("in-chat-workspace", app)
        app.buttons["quick-workspace.settings"].tap()
        XCTAssertTrue(app.buttons["settings.themes"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFixtureApprovalRequiresExplicitDecisionInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
            app.launch()
            let newChat = app.buttons["root.new-chat"].firstMatch
            XCTAssertTrue(newChat.waitForExistence(timeout: 10))
            newChat.tap()
            let action = app.buttons["quick.approval"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.tap()
            let review = app.buttons["Review approval"]
            XCTAssertTrue(review.waitForExistence(timeout: 5))
            for _ in 0..<8 where !review.isHittable { app.tables["chat.timeline"].swipeUp() }
            XCTAssertTrue(review.isHittable)
            attach("native-approval-preview-\(appearance)", app)
            review.tap()
            let status = app.descendants(matching: .any)["approval.status"].firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertEqual(status.value as? String, "Awaiting your decision.")
            let deny = app.buttons["approval.deny"]
            for _ in 0..<6 where !deny.isHittable { app.swipeUp() }
            XCTAssertTrue(deny.isHittable)
            attach("native-approval-details-\(appearance)", app)
            deny.tap()
            let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                status.value as? String == "Denied by Hermes."
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 5), .completed)
            XCTAssertFalse(deny.isEnabled)
            attach("native-approval-confirmed-denial-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testFirstRunProgressSurvivesRelaunchWithoutConnectingAHost() {
        let app = makeApp()
        let baseArguments = ["-force-signed-out-onboarding", "-preview-ui-v3",
                             "-loopdy.appearance.interface-version", "v3"]
        app.launchArguments = baseArguments + ["-loopdy.onboarding.first-run-v1.step", "0"]
        app.launch()
        let step = app.descendants(matching: .any)["onboarding.step"].firstMatch
        func waitForSurface(_ identifier: String) {
            let surface = app.descendants(matching: .any)[identifier].firstMatch
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard surface.exists else { return false }
                let frame = surface.frame
                return surface.isHittable && frame.width > 0
                    && abs(frame.minX - app.frame.minX) <= 1
                    && frame.maxX <= app.frame.maxX + 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                           "The destination must finish entering before capture")
        }
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        XCTAssertEqual(step.value as? String, "welcome")
        attach("native-first-run-welcome", app)
        app.buttons["onboarding.get-started"].tap()
        XCTAssertEqual(step.value as? String, "connection", "Setup should not require a customization detour")
        app.buttons["onboarding.back"].tap()
        XCTAssertEqual(step.value as? String, "welcome")
        app.buttons["onboarding.customize-appearance"].tap()
        XCTAssertEqual(step.value as? String, "appearance")
        waitForSurface("onboarding.appearance")
        attach("native-first-run-appearance", app)
        app.terminate()
        app.launchArguments = baseArguments
        app.launch()
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        XCTAssertEqual(step.value as? String, "appearance", "Process relaunch must retain the last step")
        app.buttons["onboarding.appearance.continue"].tap()
        XCTAssertEqual(step.value as? String, "connection")
        waitForSurface("onboarding.connection")
        attach("native-first-run-connect", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        XCTAssertEqual(step.value as? String, "connection")
        XCTAssertFalse(app.buttons["tab.profile"].exists, "Unconfigured onboarding cannot enter the workspace")
        app.buttons["onboarding.back"].tap()
        XCTAssertEqual(step.value as? String, "welcome")
        app.buttons["onboarding.customize-appearance"].tap()
        XCTAssertEqual(step.value as? String, "appearance")
        app.buttons["onboarding.back"].tap()
        XCTAssertEqual(step.value as? String, "welcome")
    }

    @MainActor
    func testNativeAgentDetailsRetainOwnerBoundEditingAndDirtyDraft() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-agents-directory",
                               "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        app.buttons["quick-workspace.menu"].tap()
        app.buttons["quick-workspace.menu.agents"].tap()
        let manage = app.buttons["agent.studio.more"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        let list = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        attach("native-agent-details", app)
        let edit = app.buttons["agent.studio.edit"]
        for _ in 0..<6 where !edit.isHittable { list.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let name = app.textFields["agent.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Updated")
        app.buttons["agent.editor.cancel"].tap()
        let keep = app.buttons["Keep editing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        XCTAssertTrue((name.value as? String ?? "").contains("Updated"))
        attach("native-agent-dirty-editor", app)
        app.buttons["agent.editor.cancel"].tap()
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertTrue(revealSearchField(app.searchFields["Search agents and groups"], in: app))
    }

    @MainActor
    func testRootAndChatHaveNativeAccessibilityDescriptionsAndTraits() throws {
        let app = launch()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        func audit() throws {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait]) { issue in
                let evidence = XCTAttachment(string: issue.element?.debugDescription ?? "No element supplied")
                evidence.name = "accessibility-audit-element"
                evidence.lifetime = .keepAlways
                self.add(evidence)
                return false
            }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "accessibility-root-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try audit()
        row.tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 5))
        try audit()
        attach("native-chat-accessibility-semantics", app)
    }

    @MainActor
    func testAccentPickerAndCustomEditorKeepNativeNavigation() {
        let app = launch(appearance: "dark")
        openRootTab("tab.profile", in: app, timeout: 10)
        let themes = app.buttons["settings.themes"]
        XCTAssertTrue(themes.waitForExistence(timeout: 5))
        XCTAssertTrue(themes.isHittable)
        openThemeList(in: app)
        XCTAssertTrue(app.navigationBars["Accent Themes"].waitForExistence(timeout: 5))
        func accentRow(_ identifier: String) -> XCUIElement {
            let row = app.buttons[identifier].firstMatch
            // This is the theme picker's own list, not the Settings root.
            let list = app.descendants(matching: .any)["settings.theme-picker"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 3), "The accent list must own scrolling")
            func isFullyVisible() -> Bool {
                let frame = row.frame
                return row.isHittable
                    && frame.minY >= app.navigationBars["Accent Themes"].frame.maxY
                    && frame.maxY <= list.frame.maxY - 8
            }
            for _ in 0..<18 {
                guard app.navigationBars["Accent Themes"].exists else { break }
                if row.exists, isFullyVisible() { return row }
                let top = max(list.frame.minY, app.navigationBars["Accent Themes"].frame.maxY) + 12
                let bottom = list.frame.maxY - 12
                let midpoint = (top + bottom) / 2
                let distance = min(110, (bottom - top) / 4)
                let needsDown = row.exists && row.frame.minY < top
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: list.frame.midX, dy: midpoint))
                let end = origin.withOffset(CGVector(dx: list.frame.midX,
                                                     dy: midpoint + (needsDown ? distance : -distance)))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            XCTAssertTrue(row.exists && isFullyVisible(), "Full theme row must be visible: \(identifier)")
            return row
        }
        for theme in ["loopdy", "nous", "superpilot"] {
            let choice = accentRow("settings.theme.\(theme)")
            choice.tap()
            XCTAssertEqual(choice.value as? String, "Selected", "First center tap must select \(theme)")
            XCTAssertTrue(app.navigationBars["Accent Themes"].exists)
            _ = accentRow("settings.theme.\(theme)")
            attach("native-accent-\(theme)-light-dark-preview", app)
        }
        accentRow("settings.custom-theme.new").tap()
        XCTAssertTrue(app.navigationBars["New Theme"].waitForExistence(timeout: 5))
        let name = app.textFields["settings.custom-theme.name"]
        XCTAssertTrue(name.isHittable)
        name.tap()
        let initialName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: initialName.count))
        name.typeText("Accent review")
        XCTAssertEqual(name.value as? String, "Accent review")
        XCTAssertTrue(app.buttons["settings.custom-theme.save"].isHittable)
        attach("native-custom-theme-editor", app)
        app.navigationBars["New Theme"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Accent Themes"].waitForExistence(timeout: 3))
        accentRow("settings.theme.loopdy").tap()
    }

    @MainActor
    func testNativeHomeSwipeDeletesOnlyTheSelectedUpdate() {
        let app = launch()
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        app.buttons["quick-workspace.menu"].tap()
        let home = app.buttons["quick-workspace.menu.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        let dashboard = app.descendants(matching: .any)["dashboard.screen"].firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        let update = app.buttons["dashboard.update.row.inbox-finance-payment"].firstMatch
        for _ in 0..<12 {
            if update.isHittable { break }
            dashboard.swipeUp()
        }
        XCTAssertTrue(update.isHittable)
        attach("native-home-before-swipe", app)
        update.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 1) { delete.tap() }
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
        XCTAssertTrue(dashboard.exists, "Deleting an update must not open its conversation.")
        let remaining = app.buttons["dashboard.update.row.inbox-travel-itinerary"].firstMatch
        XCTAssertTrue(remaining.exists, "Deleting one row must preserve sibling updates.")
        attach("native-home-after-swipe", app)
        let attention = app.buttons["dashboard.attention.row.attention-payment"].firstMatch
        for _ in 0..<10 {
            if attention.isHittable { break }
            dashboard.swipeDown()
        }
        XCTAssertTrue(attention.isHittable)
        attention.swipeLeft()
        if delete.waitForExistence(timeout: 1) { delete.tap() }
        XCTAssertTrue(attention.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard.attention.row.attention-calendar"].firstMatch.exists)
        XCTAssertTrue(dashboard.exists)
        attach("native-home-attention-after-swipe", app)
    }

    @MainActor
    func testGroupConversationHeaderOpensChatSettings() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-agents-directory",
                               "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3"]
        app.launch()
        XCTAssertTrue(app.buttons["quick-workspace.menu"].waitForExistence(timeout: 10))
        app.buttons["quick-workspace.menu"].tap()
        app.buttons["quick-workspace.menu.agents"].tap()
        let group = app.buttons["agents.group.research-circle"]
        let directory = app.descendants(matching: .any)["agents.screen"].firstMatch
        for _ in 0..<10 where !(group.exists && group.isHittable) { directory.swipeUp() }
        XCTAssertTrue(group.exists && group.isHittable)
        group.tap()
        let people = app.buttons["chat.people"]
        XCTAssertTrue(people.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["Message"].exists)
        attach("group-chat-native-header", app)
        people.tap()
        XCTAssertTrue(app.otherElements["chat.people-and-chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Info"].exists)
        attach("group-chat-settings", app)
    }

    @MainActor
    private func assertSoftwareKeyboardClears(_ input: XCUIElement, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        // A connected hardware keyboard can leave a zero-height Keyboard node.
        // Existence or its minY alone must never qualify software-key clearance.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.frame.height > 120
                && keyboard.keys.count > 10 && keyboard.keys["space"].isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 5)
        if result != .completed {
            let snapshot = XCTAttachment(string: app.debugDescription)
            snapshot.name = "software-keyboard-accessibility"
            snapshot.lifetime = .keepAlways
            add(snapshot)
        }
        XCTAssertEqual(result, .completed,
                       "Software keys must be visible and hittable", file: file, line: line)
        XCTAssertGreaterThan(input.frame.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY,
                                 file: file, line: line)
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
