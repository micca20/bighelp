import XCTest

final class GeneratedMediaUITests: BighelpUITestCase {
    @MainActor
    func testPDFTileOpensNativePreviewAndFilesExporter() {
        let app = launch(mode: "pdf")
        let tile = app.buttons["Preview attachment-preview.pdf"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        XCTAssertTrue(tile.isHittable)
        tile.tap()
        XCTAssertTrue(app.navigationBars["attachment-preview.pdf"].waitForExistence(timeout: 5))
        let save = app.buttons["chat.attachment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save to Files")
        let rendered = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Native attachment preview")).firstMatch
        XCTAssertTrue(rendered.waitForExistence(timeout: 10), "Wait for the actual PDF content, not just its navigation bar.")
        evidence("native-pdf-preview")
        save.tap()
        let export = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "native-files-exporter-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        evidence("native-pdf-files-exporter")
        XCTAssertTrue(export.isHittable)
        XCTAssertEqual(export.label, "Save")
        let exportName = "loopdy-proof-" + UUID().uuidString
        let name = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(name.exists)
        name.tap()
        let prior = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prior.count) + exportName)
        XCTAssertTrue(export.isEnabled)
        if export.isEnabled {
            export.tap()
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            evidence("native-pdf-export-complete")
            save.tap()
            XCTAssertTrue(export.waitForExistence(timeout: 8))
            let savedFile = app.collectionViews["File View"].descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", exportName)).firstMatch
            XCTAssertTrue(savedFile.waitForExistence(timeout: 8), "Read the exact saved file back from Files after export.")
            evidence("native-pdf-export-readback")
        }
    }

    @MainActor
    func testImagePreviewOffersFilesAndPhotos() {
        let app = launch(mode: "attachment-image")
        let tile = app.buttons["Preview preview.png"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        tile.tap()
        XCTAssertTrue(app.navigationBars["preview.png"].waitForExistence(timeout: 5))
        let save = app.buttons["chat.attachment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["Save to Files"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save to Photos"].firstMatch.exists)
        evidence("native-image-save-destinations")
    }

    @MainActor
    func testImageSavesToPhotosThroughNativePermission() {
        let app = launch(mode: "attachment-image")
        let monitor = addUIInterruptionMonitor(withDescription: "Add fixture image to Photos") { alert in
            guard alert.staticTexts.allElementsBoundByIndex.contains(where: { $0.label.localizedCaseInsensitiveContains("photos") }) else { return false }
            let allow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Allow")).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let tile = app.buttons["Preview preview.png"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        tile.tap()
        let save = app.buttons["chat.attachment.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        let photos = app.buttons["Save to Photos"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        photos.tap()
        app.tap()
        XCTAssertTrue(app.alerts.staticTexts["Saved to Photos."].waitForExistence(timeout: 10))
        evidence("native-image-saved-to-photos")
    }

    @MainActor
    private func launch(mode: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.appearance.interface-version", "v3", "-test-generated-media", mode]
        app.launch()
        return app
    }

    @MainActor
    func testImageReplacesGradientWithoutChangingCardHeight() throws {
        var baseline: CGRect?
        for mode in ["running", "image"] {
            let app = launch(mode: mode)
            let card = app.descendants(matching: .any)["chat.generated-media.media-preview"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 6))
            if let baseline {
                XCTAssertEqual(card.frame.height, baseline.height, accuracy: 1,
                               "The media viewport must not jump when the image becomes available")
            } else { baseline = card.frame }
            XCTAssertTrue(chatNewChatButton(in: app).isHittable)
            evidence("media-\(mode)")
            app.terminate()
        }
    }

    @MainActor
    func testInvalidVideoSettlesInsteadOfSpinningForever() throws {
        let app = launch(mode: "invalid-video")
        XCTAssertTrue(app.staticTexts["Video unavailable"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Preparing video…"].exists)
        evidence("invalid-video-terminal")
    }

    @MainActor
    func testVideoAndTerminalStatesRenderNatively() throws {
        for mode in ["video", "failed", "cancelled"] {
            let app = launch(mode: mode)
            let card = app.descendants(matching: .any)["chat.generated-media.media-preview"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 6))
            if mode == "video" {
                let player = app.descendants(matching: .any)["chat.generated-video.player.media_fixture_video_0001"].firstMatch
                XCTAssertTrue(player.waitForExistence(timeout: 6))
                let play = app.buttons["chat.generated-video.playback"].firstMatch
                XCTAssertTrue(play.waitForExistence(timeout: 3))
                XCTAssertEqual(play.label, "Play")
                play.tap()
                let playing = NSPredicate(format: "label == %@", "Pause")
                expectation(for: playing, evaluatedWith: play)
                waitForExpectations(timeout: 3)
                XCTAssertFalse(app.staticTexts["Video unavailable"].exists)
            } else {
                let expected = mode == "failed" ? "Image generation failed" : "Generation stopped"
                XCTAssertTrue(app.staticTexts[expected].exists)
            }
            evidence("media-\(mode)")
            app.terminate()
        }
    }

    @MainActor
    private func evidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
