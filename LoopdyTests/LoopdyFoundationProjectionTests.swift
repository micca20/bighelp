import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyFoundationProjectionTests {
    @Test("foundation projection preserves the existing session and ordered timeline identity")
    func projectionPreservesCanonicalSessionIdentity() {
        let record = SessionRecord(
            id: "existing-session",
            kind: .direct,
            agentIDs: ["loopdy"],
            title: "Existing conversation",
            draft: "Continue here",
            items: [
                TimelineItem(
                    id: "second",
                    role: .assistant,
                    sender: .agent(id: "loopdy", snapshot: .init(name: "Loopdy")),
                    content: .message("Second"),
                    metadata: .init(sourceOrder: 2)
                ),
                TimelineItem(
                    id: "first",
                    role: .human,
                    sender: .user(snapshot: .init(name: "You")),
                    content: .message("First"),
                    metadata: .init(sourceOrder: 1)
                ),
            ]
        )

        let projection = LoopdyFoundationSession(projecting: record, agentName: "Loopdy")

        #expect(projection.id == record.id)
        #expect(projection.title == record.title)
        #expect(projection.draft == record.draft)
        #expect(projection.orderedEvents.map(\.id) == ["first", "second"])
        #expect(projection.orderedEvents.map(\.sourceOrder) == [1, 2])
    }
}
