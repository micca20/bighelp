import XCTest

/// Vision Pro in light and dark: the main screens, the tab strip beside the
/// window, the Transparency setting and the 3D agent in the room. With
/// BIGHELP_VISION_EVIDENCE set, each step saves a screenshot for review (see
/// SpatialAvatarUITests for how the Mac answers).
final class VisionReadabilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMainScreensInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            let arguments = [
                "-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                "-loopdy.home.opens-chat", "YES", "-loopdy.settings.nerd-mode", "NO",
            ]
            app.launchArguments = arguments
            app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launch()

            let menu = app.buttons["chat.menu"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 20), "The agent's chat opens")
            Thread.sleep(forTimeInterval: 2)
            save("\(appearance)-1-chat", app)
            XCTAssertTrue(app.buttons["tab.feed"].firstMatch.waitForExistence(timeout: 10), "Tabs sit beside the window")

            app.buttons["tab.feed"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["board.feed"].firstMatch.waitForExistence(timeout: 10))
            save("\(appearance)-2-feed", app)
            app.buttons["tab.sessions"].firstMatch.tap()

            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
            XCTAssertTrue(app.buttons["menu.projects"].firstMatch.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            save("\(appearance)-3-menu", app)
            app.buttons["menu.projects"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["projects.screen"].firstMatch.waitForExistence(timeout: 10))
            save("\(appearance)-4-projects", app)
            // A form: hints in empty fields must read too.
            app.buttons["projects.new"].firstMatch.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            save("\(appearance)-4b-new-project", app)
            cancel.tap()
            app.buttons["projects.card.loopdy"].firstMatch.tap()
            XCTAssertTrue(app.buttons["project.new-chat"].firstMatch.waitForExistence(timeout: 10))
            save("\(appearance)-5-project", app)

            app.terminate()
            app.launchArguments += ["-initial-tab", "profile"]
            app.launch()
            XCTAssertTrue(app.buttons["home.drawer.open"].firstMatch.waitForExistence(timeout: 20))
            save("\(appearance)-6-settings", app)
            let list = app.collectionViews.firstMatch
            let transparency = app.sliders["appearance.transparency"].firstMatch
            for _ in 0..<8 where !(transparency.exists && transparency.isHittable) { list.swipeUp() }
            XCTAssertTrue(transparency.waitForExistence(timeout: 5), "Appearance has a transparency slider on Vision Pro")
            save("\(appearance)-7-transparency", app)
            let colors = app.descendants(matching: .any)["settings.themes"].firstMatch
            for _ in 0..<3 where !(colors.exists && colors.isHittable) { list.swipeDown() }
            XCTAssertTrue(colors.waitForExistence(timeout: 5), "Settings has Colors")
            colors.tap()
            XCTAssertTrue(app.descendants(matching: .any)["appearance.mode"].firstMatch.waitForExistence(timeout: 10))
            save("\(appearance)-8-colors", app)
            app.terminate()

            // The ends of the Transparency slider (a launch argument pins it).
            for (label, value) in [("most-solid", "0"), ("most-transparent", "1")] {
                app.launchArguments = arguments + ["-loopdy.appearance.windowTransparency", value]
                app.launch()
                XCTAssertTrue(app.buttons["chat.menu"].firstMatch.waitForExistence(timeout: 20))
                Thread.sleep(forTimeInterval: 1)
                save("\(appearance)-9-\(label)", app)
                app.terminate()
            }
        }
    }

    /// Agent Studio: the hero doesn't overlap, Design avatar takes a pinch, and
    /// the designer shows the pick in 3D with moods, headwear and a pattern,
    /// then in the room at full size.
    @MainActor
    func testAgentStudioDesignsIn3D() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
            "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", "light", "-initial-tab", "agents",
        ]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 20))
        let create = app.buttons["Create agent"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Agents has a create button")
        create.tap()
        let design = app.buttons["agent.editor.design-avatar"].firstMatch
        XCTAssertTrue(design.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        save("studio-1-new-agent", app)
        let title = app.staticTexts["agent.editor.hero-title"].firstMatch
        XCTAssertGreaterThanOrEqual(design.frame.height, 44, "Design avatar is a real button")
        XCTAssertGreaterThanOrEqual(design.frame.minY, title.frame.maxY, "Design avatar sits under the name")
        design.tap()
        let stage = app.descendants(matching: .any)["avatar.creator.preview"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "Design avatar opens the designer")
        Thread.sleep(forTimeInterval: 2)
        save("studio-2a-designer", app)
        let dragon = app.buttons["avatar.creator.character.dragon"].firstMatch
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.creator.character.'")).firstMatch
        for _ in 0..<4 where !(dragon.exists && dragon.isHittable) { tiles.swipeUp(velocity: .slow) }
        dragon.tap()
        Thread.sleep(forTimeInterval: 2)
        save("studio-2-designer-3d", app)
        app.buttons["avatar.creator.try.thinking"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.5)
        save("studio-3-thinking", app)
        app.buttons["avatar.creator.tab.extras"].firstMatch.tap()
        let crown = app.buttons["avatar.creator.topper.crown"].firstMatch
        XCTAssertTrue(crown.waitForExistence(timeout: 5))
        crown.tap()
        let pattern = app.buttons["avatar.creator.pattern.lava"].firstMatch
        for _ in 0..<4 where !(pattern.exists && pattern.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        if pattern.exists { pattern.tap() }
        app.buttons["avatar.creator.try.moves"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        save("studio-4-crown-pattern", app)
        let room = app.buttons["avatar.creator.in-room"].firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 5))
        room.tap()
        Thread.sleep(forTimeInterval: 3)
        save("studio-5a-after-in-room", app)
        XCTAssertTrue(app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch.waitForExistence(timeout: 15),
                      "The look steps into the room")
        Thread.sleep(forTimeInterval: 4)
        save("studio-5-in-room", app)
        app.buttons["avatar.creator.use"].firstMatch.tap()
        XCTAssertTrue(design.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        save("studio-6-agent-3d", app)
    }

    /// Tool rows and details are grey text, and messages scroll under the header.
    @MainActor
    func testToolRowsInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                "-test-tool-disclosure-scroll", "-loopdy.chat.foldCompletedTurns", "NO",
                "-loopdy.demo.appearance", appearance, "-loopdy.settings.nerd-mode", "NO",
            ]
            app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["chat.composer-shell"].firstMatch.waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 2)
            save("\(appearance)-10-tools", app)
            // Messages sliding under the header must not show through it.
            let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
            (timeline.exists ? timeline : app.collectionViews.firstMatch).swipeDown(velocity: .slow)
            Thread.sleep(forTimeInterval: 1.5)
            save("\(appearance)-11-under-header", app)
            // The work trail and its tool rows, at the top.
            for _ in 0..<3 { (timeline.exists ? timeline : app.collectionViews.firstMatch).swipeDown() }
            Thread.sleep(forTimeInterval: 1.5)
            save("\(appearance)-12-work-trail", app)
            app.terminate()
        }
    }

    /// Resized from its corners, the agent grows with its volume and opens at
    /// that size next time (a launch argument stands in for the last size).
    @MainActor
    func testTheAgentGrowsWithItsVolume() throws {
        var frames: [CGRect] = []
        for size in ["1", "1.8"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
                "-loopdy.settings.nerd-mode", "NO", "-initial-tab", "profile",
                "-bighelp.spatial-avatar.size", size,
            ]
            app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launch()
            let list = app.collectionViews.firstMatch
            let show = app.switches["settings.spatial-avatar.show"].firstMatch
            XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 15))
            for _ in 0..<8 where !show.exists { list.swipeUp() }
            XCTAssertTrue(show.waitForExistence(timeout: 5))
            let avatar = app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch
            if !avatar.waitForExistence(timeout: 3) {
                (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
            }
            XCTAssertTrue(avatar.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 3)
            frames.append(avatar.frame)
            save("avatar-size-\(size)", app)
            app.terminate()
        }
        XCTAssertEqual(frames[1].width / frames[0].width, 1.8, accuracy: 0.05, "The agent is 1.8 times as big")
    }

    @MainActor
    func testTheAgentStandsInTheRoomIn3D() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
            "-loopdy.settings.nerd-mode", "NO", "-bighelp.spatial-avatar.pinch-action", "type",
        ]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        // Settings › In your space brings the agent in beside bighelp.
        app.terminate()
        app.launchArguments += ["-initial-tab", "profile"]
        app.launch()
        let list = app.collectionViews.firstMatch
        let show = app.switches["settings.spatial-avatar.show"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<8 where !show.exists { list.swipeUp() }
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
        Thread.sleep(forTimeInterval: 6)
        save("avatar-0-after-simple-mode", app)
        XCTAssertTrue(app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch.waitForExistence(timeout: 15),
                      "The agent steps into the room")
        Thread.sleep(forTimeInterval: 3)
        save("avatar-1-room", app)
        Thread.sleep(forTimeInterval: 1.2)
        save("avatar-2-room-moving", app)
    }

    /// Renders of kit characters in 3D, for approving the art
    /// (BIGHELP_KIT_CHARACTERS picks which, comma-separated).
    @MainActor
    func testKitCharactersIn3D() throws {
        let requested = ProcessInfo.processInfo.environment["BIGHELP_KIT_CHARACTERS"] ?? "lobster,dog,dragon,cube"
        // BIGHELP_KIT_SPIN (radians) turns them to show their depth.
        let spin = ProcessInfo.processInfo.environment["BIGHELP_KIT_SPIN"]
        for character in requested.split(separator: ",").map(String.init) {
            let app = XCUIApplication()
            app.launchArguments = [
                "-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
                "-loopdy.settings.nerd-mode", "NO", "-bighelp.spatial-avatar.pinch-action", "type",
                "-test-agent-companion", "finance:\(character)", "-initial-tab", "profile",
            ] + (spin.map { ["-test-spatial-avatar-spin", $0] } ?? [])
            app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launch()
            let list = app.collectionViews.firstMatch
            let show = app.switches["settings.spatial-avatar.show"].firstMatch
            XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 15))
            for _ in 0..<8 where !show.exists { list.swipeUp() }
            // Scrolled too far, the switch sits under the header where a tap misses it.
            for _ in 0..<3 where show.exists && show.frame.minY < list.frame.minY + 120 {
                list.swipeDown(velocity: .slow)
            }
            XCTAssertTrue(show.waitForExistence(timeout: 5))
            // Only switch it on if the agent isn't already in the room.
            let avatar = app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch
            if !avatar.waitForExistence(timeout: 3) {
                (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
            }
            let started = Date()
            let appeared = avatar.waitForExistence(timeout: 45)
            print("KIT_CHARACTER \(character) appeared=\(appeared) after \(Date().timeIntervalSince(started))s")
            if !appeared { save("kit-\(character)-missing", app) }
            XCTAssertTrue(appeared, "\(character) steps into the room")
            Thread.sleep(forTimeInterval: 4)
            save("kit-\(character)\(spin == nil ? "" : "-turned")", app)
            app.terminate()
        }
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VISION_EVIDENCE"] else { return }
        let base = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let shot = base.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: shot)
        FileManager.default.createFile(atPath: base.appendingPathComponent("\(name).request").path, contents: nil)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: shot.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
