import SwiftUI
import XCTest
@testable import Bighelp

final class HostActivityRenderTests: XCTestCase {
    @MainActor
    func testProductionActivityCardsRenderAtPhoneWidth() throws {
        let attributes = try XCTUnwrap(LoopdySessionActivityAttributes.make(sessionID: "session-render",
            sessionTitle: "PRIVATE TITLE", agentID: "agent", agentName: "Juno"))
        typealias State = LoopdySessionActivityAttributes.ContentState
        let rows: [(String, State, Bool)] = [
            ("Working", State(phase: .usingTool, currentAction: "Private command", progress: 38, completedSteps: 8, activeSubagentCount: 0, latestTool: "secret", timestamp: 100), false),
            ("Delegating", State(phase: .delegating, currentAction: "Response ready", progress: 0, completedSteps: 8, activeSubagentCount: 2, latestTool: nil, timestamp: 100), false),
            ("Attention", State(phase: .waiting, currentAction: "Private question", progress: 0, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false),
            ("Stale", State.initial(agentName: "Juno", timestamp: 100), true),
            ("Finished", State(phase: .completed, currentAction: "Finished", progress: 100, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false),
            ("Failed", State(phase: .failed, currentAction: "Could not finish", progress: 100, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false)
        ]
        for dark in [false, true] {
            let view = VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    // The card draws the app's page color itself, as it does on the Lock Screen.
                    BighelpLiveActivityCard(attributes: attributes, state: row.1, isStale: row.2)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }.padding(16).frame(width: 393).background(dark ? Color.black : Color(white: 0.55))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 500)
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "activity-cards-dark" : "activity-cards-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let large = ImageRenderer(content: BighelpLiveActivityCard(attributes: attributes, state: rows[2].1)
            .frame(width: 320).environment(\.dynamicTypeSize, .accessibility3))
        let attachment = XCTAttachment(image: try XCTUnwrap(large.uiImage))
        attachment.name = "activity-attention-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
