import Foundation
import Testing
@testable import Loopdy

@MainActor
struct GeneratedMediaLifecycleTests {
    @Test func completedGeneratedMediaStaysOutsideCompletedWorkFolders() throws {
        let finished = event("a", order: 1)
            .updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2)
            .resolvingGeneratedMedia(try result("a"))
        let model = makeModel(events: [finished], resolver: ControlledMediaResolver())
        let rows = ChatCompletedTurnProjection.rows(from: model.transcriptEntries, isSending: false, enabled: true)
        #expect(rows.map(\.id) == model.transcriptEntries.map(\.id))
        #expect(rows.allSatisfy { row in if case .entry = row { return true }; return false })
    }

    @Test func concurrentCompletionsEnrichSameOrderedSlots() async throws {
        let resolver = ControlledMediaResolver()
        let a = event("a", order: 1)
        let b = event("b", order: 2)
        let model = makeModel(events: [a, b], resolver: resolver)
        let originalIDs = model.transcriptEntries.map(\.id)
        model.acceptActivity(a.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 3))
        model.acceptActivity(b.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 4))
        await resolver.waitForCount(2)
        resolver.complete(index: 1, resolution: try result("b"))
        await settle()
        resolver.complete(index: 0, resolution: try result("a"))
        await settle()
        #expect(model.transcriptEntries.map(\.id) == originalIDs)
        #expect(model.activityLedger.event(id: a.id)?.generatedMedia?.attachments.first?.fileName == "a.png")
        #expect(model.activityLedger.event(id: b.id)?.generatedMedia?.attachments.first?.fileName == "b.png")
    }

    @Test func cancelledResolutionDoesNotPopulateAChangedOwner() async throws {
        let resolver = ControlledMediaResolver()
        let a = event("a", order: 1).updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2)
        let model = makeModel(events: [a], resolver: resolver)
        await resolver.waitForCount(1)
        model.cancelGeneratedMediaResolutionRequests()
        resolver.complete(index: 0, resolution: try result("a"))
        await settle()
        #expect(model.activityLedger.event(id: a.id)?.generatedMedia == nil)
    }

    @Test func staleTaskCannotClearANewerResolutionHandle() async throws {
        let resolver = ControlledMediaResolver()
        let a = event("a", order: 1).updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2)
        let model = makeModel(events: [a], resolver: resolver)
        await resolver.waitForCount(1)
        model.cancelGeneratedMediaResolutionRequests()
        model.reconcileHydratedSession(session(events: [a]))
        await resolver.waitForCount(2)
        resolver.complete(index: 0, resolution: try result("stale"))
        await settle()
        model.acceptActivity(a.updating(lifecycle: .succeeded, summary: "More detail", detail: "Metadata arrived", occurredAt: 3))
        await settle()
        #expect(resolver.calls.count == 2)
        resolver.completeAll(resolution: try result("a"))
        await settle()
    }

    private func makeModel(events: [ChatActivityEvent], resolver: ControlledMediaResolver) -> ChatModel {
        ChatModel(conversationID: "media-local", client: ConversationFixtureClient(), initialItems: [],
                  initialActivityEvents: events, sourceSession: session(events: events), generatedMediaResolver: resolver)
    }
    private func session(events: [ChatActivityEvent]) -> SessionRecord {
        SessionRecord(id: "media-local", kind: .direct, agentIDs: ["default"], title: "Media",
                      remoteStoredID: "media-stored", remoteSource: "loopdy", activityEvents: events)
    }
    private func event(_ id: String, order: Int) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "event_\(id)", sessionID: "media-local", turnID: "turn_1", kind: .tool,
                          lifecycle: .running, title: "Generate", summary: nil, detail: nil, occurredAt: order,
                          toolCallID: "call_\(id)", toolName: "image_generate", sourceOrder: order)
    }
    private func result(_ name: String) throws -> GeneratedMediaResolution {
        .init(state: .ready, attachments: [try ChatAttachment(id: "attachment_fixture_\(name)", fileName: "\(name).png", mimeType: "image/png", data: Data([137, 80, 78, 71]))])
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor
private final class ControlledMediaResolver: GeneratedMediaResolving {
    struct Call { let event: ChatActivityEvent; var continuation: CheckedContinuation<GeneratedMediaResolution, Error>? }
    var calls: [Call] = []
    func resolve(agentID: String, storedID: String, event: ChatActivityEvent) async throws -> GeneratedMediaResolution {
        try await withCheckedThrowingContinuation { calls.append(.init(event: event, continuation: $0)) }
    }
    func waitForCount(_ count: Int) async {
        for _ in 0..<1000 { if calls.count >= count { return }; await Task.yield() }
        Issue.record("Expected \(count) media resolver calls, observed \(calls.count)")
    }
    func complete(index: Int, resolution: GeneratedMediaResolution) {
        guard calls.indices.contains(index) else { Issue.record("Missing resolver call"); return }
        calls[index].continuation?.resume(returning: resolution)
        calls[index].continuation = nil
    }
    func completeAll(resolution: GeneratedMediaResolution) { for i in calls.indices { complete(index: i, resolution: resolution) } }
}
