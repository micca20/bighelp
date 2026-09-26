import XCTest

/// Opt-in: walks the Agent Studio avatar creator on demo fixtures and saves
/// screenshots. Set BIGHELP_AVATAR_EVIDENCE (TEST_RUNNER_BIGHELP_AVATAR_EVIDENCE)
/// to the output folder.
final class AvatarCreatorUITests: BighelpUITestCase {
    @MainActor
    func testAvatarCreatorWalkthrough() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_EVIDENCE"] else {
            throw XCTSkip("Set BIGHELP_AVATAR_EVIDENCE to capture the avatar creator.")
        }
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light"
        func save(_ name: String, _ app: XCUIApplication) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(appearance)-\(name).png"))
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()
        openRootTab("tab.agents", in: app, timeout: 20)
        let create = app.buttons["agents.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 10))
        sleep(2)
        save("01-studio", app)

        let design = app.buttons["agent.editor.design-avatar"]
        XCTAssertTrue(design.waitForExistence(timeout: 5))
        design.tap()
        XCTAssertTrue(app.buttons["avatar.creator.use"].waitForExistence(timeout: 10))
        tap(app.buttons["avatar.creator.character.cat"])
        sleep(3)
        save("02-characters", app)
        app.swipeUp()
        sleep(1)
        save("03-characters-lower", app)

        tap(app.buttons["avatar.creator.tab.color"])
        tap(app.buttons["avatar.creator.color.teal"])
        save("04-color", app)

        tap(app.buttons["avatar.creator.colorway.neon"])
        save("05-colorway", app)

        tap(app.buttons["avatar.creator.tab.extras"])
        tap(app.buttons["avatar.creator.topper.crown"])
        app.swipeUp()
        tap(app.buttons["avatar.creator.pattern.hex"])
        save("06-extras", app)

        tap(app.buttons["avatar.creator.tab.moves"])
        tap(app.buttons["avatar.creator.move.dancer"])
        save("07-moves", app)

        // A strong color must clearly recolor the character.
        tap(app.buttons["avatar.creator.tab.character"])
        let inky = app.buttons["avatar.creator.character.octopus"]
        for _ in 0..<3 where !inky.isHittable { app.swipeUp() }
        tap(inky)
        tap(app.buttons["avatar.creator.tab.color"])
        tap(app.buttons["avatar.creator.color.cobalt"])
        sleep(2)
        save("08-inky-cobalt", app)
        tap(app.buttons["avatar.creator.color.sunflower"])
        sleep(2)
        save("09-inky-sunflower", app)

        // Bits swap their face parts on the Extras tab.
        tap(app.buttons["avatar.creator.tab.character"])
        let bop = app.buttons["avatar.creator.character.orb"]
        for _ in 0..<4 where !bop.isHittable { app.swipeUp() }
        save("10-bits", app)
        tap(bop)
        tap(app.buttons["avatar.creator.tab.color"])
        tap(app.buttons["avatar.creator.colorway.original"])
        tap(app.buttons["avatar.creator.tab.extras"])
        tap(app.buttons["avatar.creator.eyes.visor"])
        save("11-bit-eyes", app)
        let crown = app.buttons["avatar.creator.accessory.crown"]
        for _ in 0..<3 where !crown.isHittable { app.swipeUp() }
        tap(crown)
        save("12-bit-top", app)

        tap(app.buttons["avatar.creator.use"])
        XCTAssertTrue(app.buttons["agent.editor.design-avatar"].waitForExistence(timeout: 10))
        sleep(4)
        save("13-studio-with-avatar", app)
    }

    /// Nerd Mode on: new agents start as a copy of the default agent, shown
    /// under Instructions and selected in Advanced.
    @MainActor
    func testNewAgentClonesDefaultAgent() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_EVIDENCE"] else {
            throw XCTSkip("Set BIGHELP_AVATAR_EVIDENCE to capture the avatar creator.")
        }
        func save(_ name: String, _ app: XCUIApplication) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("clone-\(name).png"))
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "YES"]
        app.launch()
        openRootTab("tab.agents", in: app)
        tap(app.buttons["agents.create"])
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp() }
        sleep(1)
        save("01-studio-footer", app)
        let advanced = app.buttons["agent.editor.advanced"]
        for _ in 0..<3 where !advanced.isHittable { app.swipeUp() }
        tap(advanced)
        sleep(1)
        save("02-advanced", app)
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 6), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }
}
