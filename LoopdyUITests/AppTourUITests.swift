import XCTest

/// Walks every primary surface and attaches a screenshot of each, so design
/// passes are judged against the running app rather than code. Set
/// LOOPDY_UI_EVIDENCE (TEST_RUNNER_LOOPDY_UI_EVIDENCE) to also write PNGs.
/// Steps are guarded: a missing surface is skipped, not failed, because this
/// is an evidence tour rather than a behavioral contract.
final class AppTourUITests: LoopdyUITestCase {
    @MainActor
    func testTourOfPrimarySurfaces() {
        for appearance in ["light", "dark"] {
            tourChatsAndSettings(appearance)
            tourAgentsAndGroups(appearance)
            tourTasks(appearance)
        }
    }

    @MainActor
    private func launch(_ appearance: String, _ extra: [String]) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func tourChatsAndSettings(_ appearance: String) {
        let app = launch(appearance, ["-preview-simple-chat"])
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        capture("\(appearance)-01-chats", in: app)

        row.tap(); sleep(2)
        capture("\(appearance)-02-chat", in: app)
        if tap(app.buttons["chat.attachment"]) {
            capture("\(appearance)-03-chat-plus-sheet", in: app)
            dismissSheet(in: app)
        }
        if tap(app.buttons["chat.options"]) {
            capture("\(appearance)-04-chat-options", in: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.6)).tap(); sleep(1)
        }
        if openChatInfo(in: app) {
            capture("\(appearance)-05-people-and-chat", in: app)
            dismissSheet(in: app)
        }
        if tap(app.buttons["chat.voice"]) {
            sleep(2)
            capture("\(appearance)-06-voice", in: app)
            let end = ["voice.end", "voice.live-unavailable.close", "End", "Close"]
                .map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
            if let end { end.tap() } else { app.swipeDown() }
            sleep(2)
        }
        goBack(in: app)

        openTab("tab.profile", in: app)
        capture("\(appearance)-07-settings", in: app)
        app.swipeUp(); sleep(1)
        capture("\(appearance)-08-settings-lower", in: app)
        let nerd = app.switches["settings.nerd-mode"]
        for _ in 0..<4 where !nerd.isHittable { app.swipeUp() }
        if nerd.exists {
            nerd.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); sleep(1)
            app.swipeUp(); app.swipeUp(); sleep(1)
            capture("\(appearance)-09-settings-nerd", in: app)
            if tap(app.buttons["settings.advanced.hermes-tools"]) {
                capture("\(appearance)-10-hermes-tools", in: app)
                goBack(in: app)
            }
            for _ in 0..<6 where !nerd.isHittable { app.swipeDown() }
            if nerd.isHittable {
                nerd.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); sleep(1)
            }
        }
        app.terminate()
    }

    @MainActor
    private func tourAgentsAndGroups(_ appearance: String) {
        let app = launch(appearance, ["-test-agents-directory"])
        openTab("tab.agents", in: app)
        capture("\(appearance)-11-agents", in: app)
        if tap(app.buttons["agent.studio.more"]) {
            capture("\(appearance)-12-agent-sheet", in: app)
            if tap(app.buttons["agent.studio.edit"]) {
                capture("\(appearance)-13-agent-edit", in: app)
                app.swipeUp(); sleep(1)
                capture("\(appearance)-14-agent-edit-lower", in: app)
                tap(app.buttons["agent.editor.cancel"])
                tap(app.buttons["Discard changes"])
            } else {
                app.swipeDown(); sleep(1)
            }
        }
        if tap(app.buttons["agents.create"]) {
            capture("\(appearance)-15-agent-studio-new", in: app)
            tap(app.buttons["agent.editor.cancel"]) || tap(app.buttons["Cancel"].firstMatch)
            tap(app.buttons["Discard changes"])
        }
        if tap(app.buttons["agents.groups.create"]) {
            capture("\(appearance)-16-new-group", in: app)
            tap(app.buttons["Cancel"].firstMatch)
        }
        let group = app.buttons["agents.group.research-circle"]
        for _ in 0..<3 where !group.isHittable { app.swipeUp() }
        if tap(group) {
            sleep(2)
            capture("\(appearance)-17-group-chat", in: app)
        }
        app.terminate()
    }

    @MainActor
    private func tourTasks(_ appearance: String) {
        let app = launch(appearance, [])
        openTab("tab.scheduled-tasks", in: app)
        capture("\(appearance)-18-tasks", in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-task.row.")).firstMatch
        if tap(row) {
            capture("\(appearance)-19-task-detail", in: app)
            app.swipeUp(); sleep(1)
            capture("\(appearance)-20-task-detail-lower", in: app)
            goBack(in: app)
        }
        if tap(app.buttons["scheduled-tasks.create"]) {
            capture("\(appearance)-21-task-editor", in: app)
            app.swipeUp(); sleep(1)
            capture("\(appearance)-22-task-editor-lower", in: app)
        }
        app.terminate()
    }

    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap(); sleep(2)
        return true
    }

    @MainActor
    private func dismissSheet(in app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.exists && done.isHittable { done.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        }
        sleep(1)
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let custom = app.buttons["Back"].firstMatch
        let back = custom.waitForExistence(timeout: 2) ? custom : app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap(); sleep(1) }
    }

    @MainActor
    private func openTab(_ identifier: String, in app: XCUIApplication) {
        openRootTab(identifier, in: app, timeout: 5)
        sleep(2)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["LOOPDY_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
