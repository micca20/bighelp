import Testing
@testable import Loopdy

@MainActor
struct ToolDisclosureHydrationTests {
    @Test func canonicalRebuildRetainsReaderChoicesOutsideReplacedRows() throws {
        let live = ChatActivityEvent(eventID: "live", sessionID: "session", turnID: "turn", kind: .tool,
                                     lifecycle: .running, title: "Terminal", summary: nil, detail: nil,
                                     occurredAt: 1, toolCallID: "same-call", toolName: "terminal",
                                     arguments: "{\"command\":\"pwd\"}", sourceOrder: 1)
        let model = ChatModel(conversationID: "session", client: ConversationFixtureClient(),
                              initialItems: [], initialActivityEvents: [live])
        guard case .activity(let before) = try #require(model.transcriptEntries.first) else {
            Issue.record("Expected actual activity row"); return
        }
        model.activityDisclosures.setExpanded(true, for: before)
        model.activityDisclosures.setExpanded(true, for: live)
        let terminal = ChatActivityEvent(eventID: "canonical", sessionID: "session", turnID: "turn", kind: .tool,
                                         lifecycle: .succeeded, title: "Terminal", summary: nil, detail: nil,
                                         occurredAt: 2, toolCallID: "same-call", toolName: "terminal",
                                         arguments: live.arguments, result: "Complete", sourceOrder: 1)
        model.reconcileHydratedSession(SessionRecord(id: "session", kind: .direct, agentIDs: ["default"],
                                                      title: "Regression", items: [], activityEvents: [terminal],
                                                      hasAcceptedMessage: true))
        guard case .activity(let after) = try #require(model.transcriptEntries.first) else {
            Issue.record("Expected rebuilt activity row"); return
        }
        #expect(before.id != after.id, "Exercise the canonical row-recreation trigger, not an in-place update")
        #expect(after.events.count == 1)
        #expect(after.events.first?.eventID == "canonical")
        #expect(model.activityDisclosures.isExpanded(after))
        #expect(model.activityDisclosures.isExpanded(terminal))
        model.activityDisclosures.setExpanded(false, for: terminal)
        model.reconcileHydratedSession(SessionRecord(id: "session", kind: .direct, agentIDs: ["default"],
                                                      title: "Regression", items: [], activityEvents: [terminal],
                                                      hasAcceptedMessage: true))
        #expect(!model.activityDisclosures.isExpanded(terminal))
    }
}
