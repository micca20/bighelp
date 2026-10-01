import XCTest

/// Settings › Voice (TTS or GPT Live 1, every Hermes speech provider) and
/// Settings › Appearance › Chat layout.
final class VoiceAndChatLayoutSettingsUITests: BighelpUITestCase {
    private func save(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_SETTINGS_EVIDENCE"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    func testVoiceModeToggleAndLocalSpeechProvider() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-voice-settings-fixture",
                               "-loopdy.voice.conversation-mode", "codexLive"]
        app.launch()
        openSettings(in: app)

        // The toggle lives right on the Settings page.
        let mode = app.segmentedControls["settings.voice.mode"]
        for _ in 0..<6 where !(mode.exists && mode.isHittable) { app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        XCTAssertTrue(mode.buttons["GPT Live 1"].isSelected)
        save("01-settings-voice-section", app)
        mode.buttons["TTS"].tap()
        XCTAssertTrue(mode.buttons["TTS"].isSelected)

        let voiceSettings = settingsRow("settings.chat.voice-settings", in: app)
        XCTAssertTrue(voiceSettings.waitForExistence(timeout: 3))
        voiceSettings.tap()
        let pageMode = app.segmentedControls["voice.settings.conversation-mode"]
        XCTAssertTrue(pageMode.waitForExistence(timeout: 3))
        XCTAssertTrue(pageMode.buttons["TTS"].isSelected)

        let provider = app.buttons["voice.settings.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        save("02-voice-tts", app)
        provider.tap()
        // One page, local voices first.
        let piper = app.buttons["voice.provider.piper"]
        XCTAssertTrue(piper.waitForExistence(timeout: 3))
        for id in ["kittentts", "neutts", "kokoro", "edge"] {
            XCTAssertTrue(app.buttons["voice.provider." + id].exists, id)
        }
        save("03-provider-list", app)
        piper.tap()

        // A local provider has a voice but no key.
        let voice = app.textFields["voice.settings.voice-id"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        XCTAssertEqual(voice.value as? String, "en_US-lessac-medium")
        XCTAssertFalse(app.secureTextFields["voice.settings.api-key"].exists)
        let save = app.buttons["voice.settings.save"]
        XCTAssertTrue(save.isEnabled)
        self.save("04-piper-selected", app)
        save.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Saved'"), object: save)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 5), .completed)
        let sample = app.buttons["voice.settings.play-sample"]
        for _ in 0..<3 where !sample.isHittable { app.swipeUp() }
        XCTAssertTrue(sample.isEnabled)
        sample.tap()
        XCTAssertFalse(app.staticTexts["voice.settings.sample-error"].waitForExistence(timeout: 2))

        // OpenAI can point at a self-hosted OpenAI-compatible server.
        for _ in 0..<3 where !provider.isHittable { app.swipeDown() }
        provider.tap()
        let openAI = app.buttons["voice.provider.openai"]
        for _ in 0..<4 where !(openAI.exists && openAI.isHittable) { app.swipeUp() }
        openAI.tap()
        XCTAssertTrue(app.textFields["voice.settings.server-url"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["voice.settings.api-key"].exists)
        self.save("05-openai-server", app)

        // GPT Live 1 hides the speech provider and Save.
        for _ in 0..<3 where !pageMode.isHittable { app.swipeDown() }
        pageMode.buttons["GPT Live 1"].tap()
        XCTAssertTrue(app.buttons["voice.settings.live-provider"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["voice.settings.provider"].exists)
        XCTAssertFalse(app.buttons["voice.settings.save"].exists)
        self.save("06-gpt-live-1", app)
    }

    /// TTS voice mode: speech to text on this device or with Hermes' provider.
    @MainActor
    func testSpeechToTextChoiceForTTSVoice() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-voice-settings-fixture",
                               "-loopdy.voice.conversation-mode", "turnBased"]
        app.launch()
        openSettings(in: app)
        let voiceSettings = settingsRow("settings.chat.voice-settings", in: app)
        XCTAssertTrue(voiceSettings.waitForExistence(timeout: 5))
        voiceSettings.tap()

        let choice = app.buttons["voice.settings.transcription"]
        for _ in 0..<6 where !(choice.exists && choice.isHittable) { app.swipeUp() }
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        XCTAssertTrue(choice.label.contains("This device"), choice.label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
            "waits longer the longer you talk")).firstMatch.exists, "Hands-free explains it waits for pauses")
        choice.tap()
        let hermes = app.buttons["Hermes"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 3))
        hermes.tap()
        XCTAssertTrue(choice.label.contains("Hermes"), choice.label)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
            "speech-to-text provider set up in Hermes")).firstMatch.waitForExistence(timeout: 3))
        save("07-speech-to-text", app)
    }

    @MainActor
    func testChatLayoutOptionsLiveUnderAppearance() throws {
        let app = makeApp()
        // Not launch arguments: those would lock the settings for the whole run.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openSettings(in: app)
        let layout = settingsRow("settings.appearance.chat-layout", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        layout.tap()

        let avatar = app.segmentedControls["chat-layout.avatar-size"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 3))
        let reset = app.buttons["chat-layout.reset"]
        func resetLayout() {
            for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
            reset.tap()
            for _ in 0..<4 where !avatar.isHittable { app.swipeDown() }
        }
        resetLayout()
        XCTAssertTrue(avatar.buttons["Auto"].isSelected)
        XCTAssertTrue(app.otherElements["chat-layout.preview"].exists
                      || app.descendants(matching: .any)["chat-layout.preview"].exists)
        save("07-chat-layout-default", app)

        avatar.buttons["Small"].tap()
        let name = app.switches["chat-layout.shows-name"]
        XCTAssertTrue(name.exists)
        if name.value as? String == "1" { name.switches.firstMatch.exists ? name.switches.firstMatch.tap() : name.tap() }
        let text = app.sliders["chat-layout.text-size"]
        XCTAssertTrue(text.exists)
        text.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(text.value as? String, "Larger")
        save("08-chat-layout-custom", app)

        resetLayout()
        XCTAssertTrue(avatar.buttons["Auto"].isSelected)
        XCTAssertEqual(text.value as? String, "Default")
    }
}
