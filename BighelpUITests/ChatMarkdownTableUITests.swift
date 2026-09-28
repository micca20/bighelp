import XCTest

/// A reply with a pipe table shows a real grid (header, rows) instead of rows of
/// pipes, and still streams in. BIGHELP_TABLE_EVIDENCE (TEST_RUNNER_…) saves screenshots.
final class ChatMarkdownTableUITests: BighelpUITestCase {
    @MainActor
    func testPipeTableRendersAsAGrid() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-companion-disabled", "-test-table-reply", "-loopdy.demo.appearance", appearance]
            app.launch()
            let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
                ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 5))
            newChat.tap()
            confirmNewChatPicker(in: app)
            let input = app.textViews["Message"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("How much will the toilet leak cost?")
            app.buttons["chat.send"].tap()

            let table = app.descendants(matching: .any)["chat.markdown-table"].firstMatch
            XCTAssertTrue(table.waitForExistence(timeout: 15), "The table is drawn as its own grid")
            XCTAssertTrue(table.staticTexts["Likely cause"].exists, "The header is a cell, not a line of pipes")
            XCTAssertTrue(table.staticTexts.matching(NSPredicate(format: "label == %@", "Total: $270")).firstMatch.exists,
                          "Cells read with their column name")
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "|---|")).firstMatch.exists)
            sleep(2)
            if let folder = ProcessInfo.processInfo.environment["BIGHELP_TABLE_EVIDENCE"] {
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try? app.screenshot().pngRepresentation.write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent("table-\(appearance).png"))
            }
            app.terminate()
        }
    }
}
