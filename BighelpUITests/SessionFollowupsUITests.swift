import XCTest

final class SessionFollowupsUITests: BighelpUITestCase {
    @MainActor func testLightChatInfoAppearanceApplyAndReopen() { exercise(appearance: "light") }
    @MainActor func testDarkChatInfoAppearanceApplyAndReopen() { exercise(appearance: "dark") }

    @MainActor private func exercise(appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
            "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
        app.launch()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        capture("chats-" + appearance)
        row.tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 8))
        capture("canvas-" + appearance)
        capture("chat-menu-" + appearance)
        let appearanceBar = app.navigationBars["Appearance"]
        func openAppearance() {
            chatMenuItem("chat.appearance", in: app).tap()
        }
        openAppearance()
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 5))
        let sky = app.buttons["Sky background"].firstMatch
        XCTAssertTrue(sky.waitForExistence(timeout: 4))
        if !sky.isHittable { app.swipeUp() }
        XCTAssertTrue(sky.isHittable)
        sky.tap()
        let apply = app.buttons["session-appearance.apply"].firstMatch
        XCTAssertTrue(apply.isEnabled)
        capture("appearance-selection-" + appearance)
        apply.tap()
        XCTAssertTrue(appearanceBar.waitForNonExistence(timeout: 5))
        openAppearance()
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Sky background"].firstMatch.value as? String, "Selected")
        appearanceBar.buttons["Cancel"].tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 5))
        capture("canvas-customized-" + appearance)
        openAppearance()
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 5))
        let reset = app.buttons["session-appearance.reset"]
        for _ in 0..<3 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(appearanceBar.waitForNonExistence(timeout: 5))
        openAppearance()
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["App background"].firstMatch.value as? String, "Selected")
        capture("appearance-inherited-" + appearance)
        let photo = app.buttons["session-appearance.choose-photo"]
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        let covered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !photo.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [covered], timeout: 5), .completed)
        capture("native-photo-picker-" + appearance)
        guard let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Native photo picker must offer cancellation"); return
        }
        cancel.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable)
        XCTAssertEqual(app.buttons["App background"].firstMatch.value as? String, "Selected")
    }

    @MainActor func testChatMenuOpensFilesAndAppearanceOnFirstTap() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
            "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "dark"]
        app.launch()
        let row = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 8))
        let files = chatMenuItem("chat.files", in: app)
        XCTAssertTrue(files.isHittable)
        XCTAssertTrue(app.buttons["chat.appearance"].isHittable)
        capture("chat-menu-actions")
        files.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5), "Files must open its own screen on the first tap")
        capture("chat-files-destination")
        app.navigationBars["Files"].buttons["Done"].tap()
        chatMenuItem("chat.appearance", in: app).tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        capture("chat-appearance-destination")
    }

    @MainActor func testFloatingIdentityHasPhotoScaleAndTranscriptBehindIt() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "dark"]
        app.launch()
        // Every one-agent chat leads with the big live avatar.
        let identity = app.buttons["agent.hero.avatar"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.exists)
        XCTAssertEqual(app.navigationBars.count, 0, "The parent chat route must not retain a second navigation bar above floating controls")
        capture("floating-header-baseline")
        XCTAssertGreaterThanOrEqual(identity.frame.height, 76, "Photo-scale avatar and readable name need real header space, not an inline toolbar slot")
        XCTAssertLessThanOrEqual(timeline.frame.minY, identity.frame.minY, "Transcript must extend behind the floating header")
    }

    @MainActor func testAttachmentMenuDismissalPreservesReadyDraft() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "dark"]
        app.launch()
        let input = app.textViews["chat.composer.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        let draft = "Keep this draft after opening the attachments menu."
        input.typeText(draft)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled)
        app.buttons["chat.attachment"].tap()
        let menu = app.navigationBars["Add to chat"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        capture("dark-attachment-menu")
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "The sheet must actually release input before testing Send")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(send.isEnabled, "Menu dismissal must not retire the sender for the still-visible draft")
        capture("draft-after-menu-dismissal")
        send.tap()
        XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 8), "One tap must submit and clear the draft")
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
