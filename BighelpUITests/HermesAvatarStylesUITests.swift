import XCTest

/// Agent Studio's Hermes Desktop styles on demo fixtures: a blob face, shapes,
/// the photo upload and a searched petdex pet, each saved as the agent's avatar.
/// Set BIGHELP_AVATAR_EVIDENCE (TEST_RUNNER_BIGHELP_AVATAR_EVIDENCE) to keep
/// screenshots, and BIGHELP_AVATAR_APPEARANCE to light or dark.
final class HermesAvatarStylesUITests: BighelpUITestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light" }

    @MainActor
    func testFaceAndPetBecomeTheAgentsAvatar() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        openAgents(in: app)

        // A blob face pinned to the sun silhouette.
        openCreator(in: app)
        tap(app.buttons["avatar.creator.style.face"])
        XCTAssertTrue(app.buttons["avatar.creator.face.auto"].waitForExistence(timeout: 5))
        save("01-face", app)
        tap(app.buttons["avatar.creator.face.sun"])
        tap(app.buttons["avatar.creator.face.lock"])
        XCTAssertTrue(app.buttons["Unlock"].exists || app.staticTexts["Unlock"].exists)
        save("02-face-sun-locked", app)

        tap(app.buttons["avatar.creator.style.shapes"])
        tap(app.buttons["avatar.creator.shape.hexagon"])
        tap(app.buttons["avatar.creator.shape-color.3"])
        save("03-shapes", app)

        tap(app.buttons["avatar.creator.style.photo"])
        XCTAssertTrue(app.buttons["avatar.creator.photo"].waitForExistence(timeout: 5))
        save("04-photo", app)

        tap(app.buttons["avatar.creator.style.face"])
        tap(app.buttons["avatar.creator.use"])
        XCTAssertTrue(app.buttons["agent.editor.design-avatar"].waitForExistence(timeout: 10))
        sleep(2)
        save("05-studio-face", app)
        saveAgent(in: app)
        save("06-agents-face", app)

        // The studio reopens on the saved face; then a pet found by search.
        openCreator(in: app)
        XCTAssertTrue(app.buttons["avatar.creator.face.sun"].waitForExistence(timeout: 5),
                      "The creator opens on the saved face")
        tap(app.buttons["avatar.creator.style.pets"])
        XCTAssertTrue(app.buttons["avatar.creator.pet.pip"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["avatar.creator.use"].isEnabled, "Nothing to use until a pet is picked")
        sleep(1)
        save("07-pets", app)
        let search = app.textFields["avatar.creator.pets.search"]
        tap(search)
        search.typeText("royal")
        XCTAssertTrue(app.buttons["avatar.creator.pet.royal-bolt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["avatar.creator.pet.pip"].exists)
        sleep(1)
        save("08-pets-search", app)
        tap(app.buttons["avatar.creator.pet.royal-bolt"])
        let use = app.buttons["avatar.creator.use"]
        XCTAssertTrue(waitUntil(timeout: 8) { use.isEnabled })
        save("09-pet-picked", app)
        tap(use)
        XCTAssertTrue(app.buttons["agent.editor.design-avatar"].waitForExistence(timeout: 10))
        sleep(2)
        save("10-studio-pet", app)
        saveAgent(in: app)
        save("11-agents-pet", app)
    }

    // MARK: Helpers

    @MainActor
    private func openCreator(in app: XCUIApplication) {
        let tile = app.descendants(matching: .any)["agents.featured.finance"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        tile.press(forDuration: 0.8)
        tap(app.buttons["agent.finance.edit"])
        tap(app.buttons["agent.editor.design-avatar"])
        XCTAssertTrue(app.buttons["avatar.creator.use"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func saveAgent(in app: XCUIApplication) {
        let saveButton = app.buttons["agent.editor.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        sleep(2)
        saveButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agents.featured.finance"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
    }

    @MainActor
    private func openAgents(in app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        menu.tap()
        tap(app.buttons["menu.agents"])
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("hermes-\(appearance)-\(name).png"))
    }
}
