import XCTest

/// Opt-in: the agent's pet must stay visible on every agent-home screen.
/// Set LOOPDY_HOME_EVIDENCE to the output folder.
final class AgentHomePetUITests: LoopdyUITestCase {
    @MainActor
    func testPetStaysVisibleAcrossTabs() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOOPDY_HOME_EVIDENCE"] else {
            throw XCTSkip("Set LOOPDY_HOME_EVIDENCE to capture the agent home.")
        }
        func save(_ name: String, _ app: XCUIApplication) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("pet-\(name).png"))
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO", "-test-agent-companion", "finance:octopus"]
        app.launch()
        XCTAssertTrue(app.buttons["agent.hero.avatar"].waitForExistence(timeout: 25))
        sleep(2)
        save("1-chat", app)
        for tab in ["feed", "ideas", "goals", "apps", "sessions"] {
            app.buttons["tab.\(tab)"].tap()
            sleep(2)
            save("2-\(tab)", app)
        }
    }
}

/// Opt-in: each kind of work has its own little scene in the Dynamic Island.
final class AgentIslandUITests: LoopdyUITestCase {
    @MainActor
    func testIslandScenes() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOOPDY_HOME_EVIDENCE"] else {
            throw XCTSkip("Set LOOPDY_HOME_EVIDENCE to capture the island.")
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let kinds = (ProcessInfo.processInfo.environment["LOOPDY_ISLAND_KINDS"] ?? "thinking,coding,tools,images")
            .split(separator: ",").map(String.init)
        for kind in kinds {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                   "-loopdy.settings.nerd-mode", "NO", "-test-agent-companion", "finance:octopus",
                                   "-test-island-activity", kind]
            app.launch()
            let island = app.descendants(matching: .any)["agent.island"]
            XCTAssertTrue(island.waitForExistence(timeout: 25), kind)
            for frame in 0..<3 {
                usleep(700_000)
                try? app.screenshot().pngRepresentation.write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent("island-\(kind)-\(frame).png"))
            }
            island.tap()
            sleep(1)
            try? app.screenshot().pngRepresentation.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("island-\(kind)-compact.png"))
            app.terminate()
        }
    }
}
