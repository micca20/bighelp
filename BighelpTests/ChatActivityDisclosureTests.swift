import Testing
@testable import Bighelp

@MainActor
struct ChatActivityDisclosureTests {
    private func event(_ id: String = "live-event", session: String = "session", call: String = "call", lifecycle: ChatActivityLifecycle = .running) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: session, turnID: "turn", kind: .tool,
                          lifecycle: lifecycle, title: "Tool", summary: nil, detail: nil,
                          occurredAt: 1, toolCallID: call, toolName: "terminal",
                          arguments: "{\"command\":\"pwd\"}", result: lifecycle == .running ? nil : "complete")
    }

    @Test func explicitChoiceSurvivesLifecycleAndCanonicalEventReplacement() {
        let store = ChatActivityDisclosureStore()
        let running = event()
        let finished = event("canonical-event", lifecycle: .succeeded)
        store.setExpanded(true, for: running)
        #expect(store.isExpanded(finished))
        store.setExpanded(false, for: finished)
        #expect(!store.isExpanded(running))
        #expect(!store.isExpanded(event(session: "different")))
        #expect(!store.isExpanded(event(call: "different")))
        #expect(!ChatActivityDisclosureStore().isExpanded(finished))
    }

    @Test func parentRecreationAndRegroupingKeepIndependentReaderChoices() {
        let store = ChatActivityDisclosureStore()
        let first = event()
        let second = event("event-two", call: "two")
        let original = ChatActivityTurn(id: "original", events: [first, second])
        store.setExpanded(true, for: original)
        store.setExpanded(true, for: first)
        store.setExpanded(false, for: second)
        let regrouped = ChatActivityTurn(id: "different-segment", events: [event("canonical-event", lifecycle: .succeeded)])
        #expect(store.isExpanded(regrouped))
        #expect(store.isExpanded(first))
        #expect(!store.isExpanded(second))
        store.setExpanded(false, for: original)
        #expect(!store.isExpanded(original))
        #expect(store.isExpanded(first), "Closing the parent does not silently close a tool")
        store.setExpanded(true, for: original)
        #expect(store.isExpanded(first))
        #expect(!store.isExpanded(second))
    }
}
