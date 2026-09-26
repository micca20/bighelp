import XCTest

final class CompanionUITests: LoopdyUITestCase {
    @MainActor
    private func launch(character: String? = nil, chat: Bool = false, question: Bool = false, animatedQuestion: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.appearance.interface-version", "v3"]
        if let character { app.launchArguments += ["-test-companion-character", character] }
        if chat { app.launchArguments += ["-start-chat"] }
        if question || animatedQuestion { app.launchArguments += ["-test-companion-reaction", "question"] }
        if question { app.launchArguments += ["-test-companion-reduced-motion"] }
        app.launch()
        if !chat { openActivity(in: app) }
        return app
    }

    @MainActor
    func testEveryCompanionRendersOnHome() throws {
        verifyHomeCharacters(["lobster", "messenger", "zeus", "octopus", "robot", "dragon", "owl", "cat", "fox", "dog"])
    }

    @MainActor
    func testQuestionsRenderOnHome() throws {
        verifyHomeCharacters(["lobster", "messenger", "zeus", "octopus", "robot", "dragon", "owl", "cat", "fox", "dog"], question: true)
    }

    @MainActor
    func testAnimationAndReduceMotion() throws {
        for reduced in [false, true] {
            let app = launch(character: "dog", question: reduced, animatedQuestion: !reduced)
            let pet = app.descendants(matching: .any)["companion-home"].firstMatch
            XCTAssertTrue(pet.waitForExistence(timeout: 6))
            XCTAssertEqual(pet.value as? String, "asking a question")
            let first = pet.screenshot().pngRepresentation
            evidence(reduced ? "boo-static-first" : "boo-animated-first")
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            let second = pet.screenshot().pngRepresentation
            evidence(reduced ? "boo-static-second" : "boo-animated-second")
            if reduced { XCTAssertEqual(first, second, "Reduce Motion must keep the pet still") }
            else { XCTAssertNotEqual(first, second, "The rendered pose must advance") }
            app.terminate()
        }
    }

    @MainActor
    func testHomeCompanionPlacement() throws {
        verifyHomeCharacters(["lobster", "dog"])
    }

    @MainActor
    private func verifyHomeCharacters(_ characters: [String], question: Bool = false) {
        for character in characters {
            let app = launch(character: character, question: question)
            let pet = app.descendants(matching: .any)["companion-home"].firstMatch
            XCTAssertTrue(pet.waitForExistence(timeout: 6), character)
            XCTAssertTrue(app.buttons["workspace.menu"].isHittable)
            XCTAssertGreaterThan(pet.frame.width, 0)
            XCTAssertGreaterThan(pet.frame.height, 0)
            XCTAssertTrue(app.frame.contains(pet.frame), character)
            if question { XCTAssertEqual(pet.value as? String, "asking a question") }
            evidence("home-\(character)\(question ? "-question" : "")")
            app.terminate()
        }
    }

    @MainActor
    func testSettingsToggleAndColorControlsAreReachable() throws {
        let app = launch(character: "dog")
        openSettings(in: app)
        var entry = settingsRow("companion-settings-entry", in: app)
        if !entry.waitForExistence(timeout: 2), settingsRow("settings.menu.appearance", in: app).exists {
            settingsRow("settings.menu.appearance", in: app).tap()
            entry = settingsRow("companion-settings-entry", in: app)
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        let enabled = app.switches["companion.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        XCTAssertEqual(enabled.value as? String, "1")
        let theme = app.switches["companion.default.match-theme"]
        XCTAssertTrue(theme.exists)
        XCTAssertTrue(app.descendants(matching: .any)["companion.default.character"].firstMatch.exists)
        evidence("companion-settings")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let disabled = NSPredicate(format: "value == '0'")
        expectation(for: disabled, evaluatedWith: enabled)
        waitForExpectations(timeout: 3)
        evidence("companion-disabled")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: enabled)
        waitForExpectations(timeout: 3)
        let picker = app.buttons["companion.default.character"]
        picker.tap()
        app.buttons["Bolt"].tap()
        XCTAssertTrue(picker.label.contains("Bolt") || String(describing: picker.value).contains("Bolt"))
        let agentPicker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'companion.agent.'")).firstMatch
        if !agentPicker.isHittable { app.swipeUp() }
        XCTAssertTrue(agentPicker.isHittable)
        agentPicker.tap()
        app.buttons["Ember"].tap()
        XCTAssertTrue(agentPicker.label.contains("Ember") || String(describing: agentPicker.value).contains("Ember"))
        agentPicker.tap()
        app.buttons["Use app default"].tap()
        XCTAssertTrue(agentPicker.label.contains("Use app default") || String(describing: agentPicker.value).contains("Use app default"))
        evidence("companion-overrides")
    }

    @MainActor
    func testPetDoesNotBlockChatComposerOrNavigation() throws {
        let app = launch(character: "octopus", chat: true)
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 6))
        XCTAssertTrue(chatNewChatButton(in: app).isHittable)
        let pet = app.descendants(matching: .any)["companion-chat"].firstMatch
        if pet.waitForExistence(timeout: 2) {
            XCTAssertFalse(pet.frame.intersects(composer.frame))
            let start = pet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35))
            start.press(forDuration: 0.15, thenDragTo: end)
            expectation(for: NSPredicate { _, _ in pet.frame.midY > app.frame.height * 0.55 }, evaluatedWith: pet)
            waitForExpectations(timeout: 4)
            XCTAssertTrue(chatNewChatButton(in: app).isHittable)
            XCTAssertFalse(pet.frame.intersects(composer.frame))
            XCTAssertTrue(app.frame.contains(pet.frame))
        } else {
            XCTFail("The enabled pet should expose its resting or active chat presence")
        }
        evidence("chat-pet")
    }

    @MainActor
    func testVoiceUsesAppDefaultWithoutBlockingControls() throws {
        let app = launch(character: "octopus", chat: true)
        addUIInterruptionMonitor(withDescription: "Voice permission") { alert in
            let deny = alert.buttons["Don’t Allow"]
            if deny.exists { deny.tap(); return true }
            let otherDeny = alert.buttons["Don't Allow"]
            if otherDeny.exists { otherDeny.tap(); return true }
            return false
        }
        XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 6))
        app.buttons["chat.voice"].tap()
        let end = app.buttons["voice.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 6))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let pet = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Clip companion'")).firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 3))
        XCTAssertFalse(pet.frame.intersects(end.frame))
        evidence("voice-clip")
        end.tap()
    }

    @MainActor
    private func evidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
