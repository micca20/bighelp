import Foundation
import Testing
@testable import Loopdy

struct CanonicalContentReferenceTests {
    @Test func fullContentCoordinatesRemainExplicitAndStableThroughReordering() {
        let reference = CanonicalContentReference(sessionID: "visible-session", rowID: "42")
        let metadata = TimelineMetadata(sourceOrder: 42, contentReference: reference)
        #expect(metadata.ordered(100).contentReference == reference)
        let event = ChatActivityEvent(eventID: "tool", sessionID:"visible-session",turnID:"turn",kind:.tool,
            lifecycle:.succeeded,title:"Tool",summary:nil,detail:nil,occurredAt:1,toolCallID:"call",contentReference:reference)
        #expect(event.routed(to:"replacement-visible").contentReference?.rowID == "42")
        #expect(event.routed(to:"replacement-visible").contentReference?.sessionID == "replacement-visible")
    }
}
