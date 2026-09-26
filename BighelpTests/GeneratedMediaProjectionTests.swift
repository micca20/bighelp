import Foundation
import Testing
@testable import Bighelp

struct GeneratedMediaProjectionTests {
    @Test func onlyCanonicalGenerationToolsCreateMediaCards() {
        #expect(GeneratedMediaProjection.kind(for: event(tool: "image_generate")) == .image)
        #expect(GeneratedMediaProjection.kind(for: event(tool: "video_generate")) == .video)
        #expect(GeneratedMediaProjection.kind(for: event(tool: "xai_video_edit")) == .video)
        #expect(GeneratedMediaProjection.kind(for: event(tool: "xai_video_extend")) == .video)
        #expect(GeneratedMediaProjection.kind(for: event(tool: "vision_analyze")) == nil)
        #expect(GeneratedMediaProjection.kind(for: event(tool: nil, title: "image_generate")) == nil)
    }

    @Test func deferredToolDispatchUsesExplicitInnerToolName() {
        let dispatched = event(tool: "tool_call", arguments: "{\"name\":\"image_generate\",\"arguments\":{\"prompt\":\"cloud\"}}")
        #expect(GeneratedMediaProjection.kind(for: dispatched) == .image)
        #expect(GeneratedMediaProjection.kind(for: event(tool: "terminal", arguments: "{\"command\":\"image_generate\"}")) == nil)
    }

    @Test func completionRetainsExactActivityIdentityAndPosition() {
        let initial = event(tool: "image_generate")
        let completed = initial.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 12, result: "MEDIA:/private/generated.png")
        #expect(initial.id == completed.id)
        #expect(initial.sourceOrder == completed.sourceOrder)
        #expect(GeneratedMediaProjection.kind(for: initial) == GeneratedMediaProjection.kind(for: completed))
    }

    @Test func differentConcurrentCallsNeverShareIdentity() {
        let a = event(tool: "image_generate", callID: "call_a")
        let b = event(tool: "image_generate", callID: "call_b")
        #expect(a.id != b.id)
        #expect(GeneratedMediaProjection.kind(for: a) == .image)
        #expect(GeneratedMediaProjection.kind(for: b) == .image)
    }

    private func event(tool: String?, title: String = "Tool activity", callID: String = "call_a", arguments: String? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "event_\(callID)", sessionID: "session_a", turnID: "turn_a", kind: .tool,
                          lifecycle: .running, title: title, summary: nil, detail: nil, occurredAt: 10,
                          toolCallID: callID, toolName: tool, arguments: arguments, sourceOrder: 3)
    }
}
