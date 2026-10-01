import XCTest

/// A long SOUL stays in a fixed-height box that scrolls on its own, so the rest of
/// the editor (the agent's model in particular) stays easy to reach. Set
/// BIGHELP_AGENT_EDITOR_EVIDENCE (TEST_RUNNER_BIGHELP_AGENT_EDITOR_EVIDENCE) to save screenshots.
final class AgentEditorLongSoulUITests: BighelpUITestCase {
    @MainActor
    func testLongSoulScrollsInsideItsBoxAndTheModelStaysReachable() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-long-soul"]
        app.launch()
        let editor = openFinanceEditor(in: app)

        let soul = app.textViews["agent.editor.instructions"]
        XCTAssertTrue(soul.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(soul.frame.height, 320, "A long SOUL doesn't stretch its box.")
        save("01-long-soul", app)

        // Scrolling the page past the SOUL reaches the model without fighting the text box.
        let model = app.buttons["agent.runtime.mainChats.model"]
        for _ in 0..<6 where !model.isHittable {
            // Drag the page by its edge, outside the SOUL box.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.35)))
        }
        XCTAssertTrue(model.isHittable, "The agent's default model is reachable below a long SOUL.")
        save("02-model-reachable", app)

        // The SOUL itself scrolls inside its box.
        let before = soul.frame
        soul.swipeUp()
        XCTAssertEqual(soul.frame.height, before.height, accuracy: 1)

        // The shared picker: search, providers, reasoning and an apply button, as in chat.
        model.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-picker.surface"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["model-picker.reasoning-slider"].firstMatch.exists)
        XCTAssertTrue(app.buttons["model-picker.apply"].exists)
        save("03-shared-picker", app)
        app.buttons["model-picker.dismiss"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
    }

    /// The expand button opens the SOUL full screen. Done keeps the changes in
    /// the form; Save from there saves the agent.
    @MainActor
    func testExpandedInstructionsKeepChangesAndCanSave() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        let editor = openFinanceEditor(in: app)

        let expand = app.buttons["agent.editor.instructions.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let focused = app.textViews["agent.editor.instructions.expand.focused"]
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(focused.frame.height, 300, "The focused editor uses most of the screen")
        focused.tap()
        focused.typeText(" Keep answers short.")
        save("04-expanded", app)

        app.buttons["agent.editor.instructions.expand.done"].tap()
        let soul = app.textViews["agent.editor.instructions"]
        XCTAssertTrue(soul.waitForExistence(timeout: 5))
        XCTAssertTrue((soul.value as? String)?.contains("Keep answers short.") == true,
                      "Changes made full screen stay in the form")
        save("05-back-with-changes", app)

        expand.tap()
        let saveButton = app.buttons["agent.editor.instructions.expand.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "Save saves the agent and closes the editor")
    }

    /// A personality's instructions expand the same way.
    @MainActor
    func testPersonalityInstructionsExpandAndKeepChanges() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openSettings(in: app)
        settingsRow("profile.personalities", in: app).tap()
        let add = app.buttons["personalities.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let expand = app.buttons["personality.editor.instructions.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let focused = app.textViews["personality.editor.instructions.expand.focused"]
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        // It opens ready to type.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard opens with the editor")
        for key in ["w", "a", "r", "m"] {
            // The first letter shows as a capital; the rest don't.
            app.keyboards.firstMatch.keys.matching(NSPredicate(format: "label ==[c] %@", key)).firstMatch.tap()
        }
        XCTAssertEqual(focused.value as? String, "Warm", "Keys type into the expanded editor")
        save("06-personality-expanded", app)
        app.buttons["personality.editor.instructions.expand.done"].tap()
        let field = app.descendants(matching: .any)["personality.editor.instructions"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Autocorrect may settle "Warm" as its "warm" suggestion on the way out.
        XCTAssertEqual((field.value as? String)?.lowercased(), "warm", "Changes made full screen stay in the form")
        save("07-personality-back", app)
    }

    @MainActor
    private func openFinanceEditor(in app: XCUIApplication) -> XCUIElement {
        let navigation = app.buttons["home.drawer.open"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 8))
        navigation.tap()
        let agents = app.buttons["menu.agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        let more = app.buttons["agent.finance.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let actions = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        let edit = app.buttons["agent.finance.edit"]
        for _ in 0..<5 where !edit.isHittable { actions.swipeUp() }
        edit.tap()
        let editor = app.descendants(matching: .any)["agent.editor.edit"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        return editor
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AGENT_EDITOR_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
