import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ResponseHapticsTests {
    @Test func pulsesAreLightweightLeadingEdgeEventsWithImmediateGates() {
        var now = 10.0
        var pulses = 0
        let controller = ResponseHapticsController(clock: { now }, supportsHaptics: true, output: { pulses += 1 })
        let event = ResponseTextGrowth(conversationID: "chat", messageID: "answer")
        func receive(enabled: Bool = true, active: Bool = true, visible: Bool = true, conversation: String = "chat") {
            controller.receive(event, conversationID: conversation, isEnabled: enabled, isSceneActive: active, isVisible: visible)
        }
        receive()
        #expect(pulses == 1)
        now = 10.1
        receive()
        #expect(pulses == 1)
        now = 10.2
        receive()
        #expect(pulses == 2)
        now = 11
        receive(enabled: false)
        receive(active: false)
        receive(visible: false)
        receive(conversation: "other-chat")
        #expect(pulses == 2)
        // Advancing time alone never schedules a trailing or replayed pulse.
        now = 20
        #expect(pulses == 2)
        receive()
        #expect(pulses == 3)
        now = .nan
        receive()
        #expect(pulses == 3)
    }

    @Test func unsupportedHardwareDoesNotEmitFeedback() {
        var pulses = 0
        let controller = ResponseHapticsController(supportsHaptics: false, output: { pulses += 1 })
        controller.receive(.init(conversationID: "chat", messageID: "answer"), conversationID: "chat", isEnabled: true, isSceneActive: true, isVisible: true)
        #expect(pulses == 0)
        #expect(!controller.isSurfaceUncovered)
    }

    @Test func onlyNewAssistantBodyGrowthQualifies() {
        let first = message("Hello 👋")
        #expect(ResponseHapticsPolicy.isGrowing(from: nil, to: first))
        #expect(ResponseHapticsPolicy.isGrowing(from: first, to: message("Hello 👋, world")))
        #expect(!ResponseHapticsPolicy.isGrowing(from: first, to: first))
        #expect(!ResponseHapticsPolicy.isGrowing(from: first, to: message("Hello")))
        #expect(!ResponseHapticsPolicy.isGrowing(from: first, to: message("An entirely replaced longer answer")))
        #expect(!ResponseHapticsPolicy.isGrowing(from: nil, to: message(" \n")))
        #expect(!ResponseHapticsPolicy.isGrowing(from: nil, to: message("Preparing attachment…")))
        let human = TimelineItem(id: "human", role: .human, sender: .user(snapshot: .init(name: "You")), content: .message("Hello"), metadata: .init())
        #expect(!ResponseHapticsPolicy.isGrowing(from: nil, to: human))
        let system = TimelineItem(id: "diagnostic", role: .assistant, sender: .system(id: "system", snapshot: .init(name: "System")), content: .message("A diagnostic"), metadata: .init())
        #expect(!ResponseHapticsPolicy.isGrowing(from: nil, to: system))
    }

    private func message(_ text: String) -> TimelineItem {
        TimelineItem(id: "answer", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Assistant")), content: .message(text), metadata: .init(delivery: "Streaming"))
    }
}
