import XCTest

/// A team call from a group chat (demo room, canned voices): the call button
/// sits in the group's header, the call shows everyone, says who's talking
/// and what they're saying, and Mute and End work.
final class TeamCallUITests: BighelpUITestCase {
    @MainActor
    func testTeamCallSpeaksEachMemberAndHangsUpLight() {
        runTeamCall(appearance: "light")
    }

    @MainActor
    func testTeamCallSpeaksEachMemberAndHangsUpDark() {
        runTeamCall(appearance: "dark")
    }

    @MainActor
    private func runTeamCall(appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-team-call",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        openRootTab("tab.agents", in: app, timeout: 10)
        let room = app.buttons["agents.group.team-call-demo"]
        XCTAssertTrue(room.waitForExistence(timeout: 8))
        room.tap()
        XCTAssertTrue(app.otherElements["chat.header-surface"].waitForExistence(timeout: 8))

        let call = app.buttons["chat.team-call"]
        XCTAssertTrue(call.waitForExistence(timeout: 8))
        XCTAssertEqual(call.label, "Team call")
        capture("team-call-entry-\(appearance)", in: app)
        call.tap()

        XCTAssertTrue(app.otherElements["team-call.screen"].waitForExistence(timeout: 5))
        for profile in ["finance", "home", "travel"] {
            XCTAssertTrue(app.descendants(matching: .any)["team-call.member.\(profile)"].exists, profile)
        }
        let status = app.descendants(matching: .any)["team-call.status"]
        XCTAssertTrue(status.exists)
        capture("team-call-start-\(appearance)", in: app)

        // The demo microphone asks a question; members answer one after another.
        var states: [String] = []
        var captured: Set<String> = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let label = status.label
            if states.last != label { states.append(label) }
            if label == "Hearing you…", captured.insert("hearing").inserted {
                capture("team-call-hearing-\(appearance)", in: app)
            }
            if label.hasSuffix("is talking"), captured.insert("speaking").inserted {
                XCTAssertTrue(app.descendants(matching: .any)["team-call.caption"].exists)
                capture("team-call-speaking-\(appearance)", in: app)
            }
            if label == "Mina Shah is talking" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(states.filter { $0.hasSuffix("is talking") },
                       ["Avery Park is talking", "Jordan Lee is talking", "Mina Shah is talking"],
                       "Each member speaks in turn, in the room's order")

        let mute = app.buttons["team-call.mute"]
        mute.tap()
        XCTAssertEqual(mute.label, "Unmute")
        capture("team-call-muted-\(appearance)", in: app)
        mute.tap()
        XCTAssertEqual(mute.label, "Mute")

        app.buttons["team-call.end"].tap()
        XCTAssertTrue(app.otherElements["team-call.screen"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["chat.header-surface"].waitForExistence(timeout: 5))
        // What you said went to the room like a typed message.
        let question = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "one idea for Saturday"))
        XCTAssertTrue(question.firstMatch.waitForExistence(timeout: 5))
        capture("team-call-after-\(appearance)", in: app)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_TEAM_CALL_EVIDENCE"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
