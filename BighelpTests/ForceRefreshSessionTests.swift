import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ForceRefreshSessionTests {
    private enum RefreshFailure: Error {
        case rejected
    }

    @Test func successfulRefreshUsesTheExactRetainedSessionAndModel() async throws {
        let (store, record, model, _) = try makeHarness(id: "force-refresh-success")
        var calls = 0
        store.configureCanonicalSessionReentry { source, retained in
            calls += 1
            #expect(source.id == record.id)
            #expect(retained === model)
        }

        try await store.forceRefreshSession(id: record.id)

        #expect(calls == 1)
        #expect(store.canReturnToWarmSession(id: record.id))
        guard case .chat(let current)? = store.preparedModel(for: .chat(conversationID: record.id)) else {
            Issue.record("Force Refresh lost the prepared chat")
            return
        }
        #expect(current === model)
    }

    @Test func concurrentRefreshesJoinOneCanonicalReentry() async throws {
        let (store, record, _, _) = try makeHarness(id: "force-refresh-concurrent")
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        store.configureCanonicalSessionReentry { _, _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
        }

        let first = Task { try await store.forceRefreshSession(id: record.id) }
        while calls == 0 { await Task.yield() }
        let second = Task { try await store.forceRefreshSession(id: record.id) }
        for _ in 0..<20 { await Task.yield() }

        #expect(calls == 1)
        release?.resume()
        try await first.value
        try await second.value
        #expect(store.canReturnToWarmSession(id: record.id))
    }

    @Test func failedRefreshPreservesDraftAttachmentsAndSendReadiness() async throws {
        let (store, record, model, _) = try makeHarness(id: "force-refresh-failure")
        model.draft = "Keep this draft"
        let attachment = try ChatAttachment(
            id: "force-refresh-attachment",
            fileName: "notes.txt",
            mimeType: "text/plain",
            data: Data("Keep this attachment".utf8)
        )
        try model.addDraftAttachment(attachment)
        let attachmentIDs = model.orderedDraftAttachments.map(\.id)
        #expect(model.canSend)
        store.configureCanonicalSessionReentry { _, _ in throw RefreshFailure.rejected }

        await #expect(throws: RefreshFailure.self) {
            try await store.forceRefreshSession(id: record.id)
        }

        #expect(model.draft == "Keep this draft")
        #expect(model.orderedDraftAttachments.map(\.id) == attachmentIDs)
        #expect(model.canSend)
        guard case .chat(let current)? = store.preparedModel(for: .chat(conversationID: record.id)) else {
            Issue.record("Failed Force Refresh retired the prepared chat")
            return
        }
        #expect(current === model)
    }

    @Test func refreshCanRepairAnExactRetainedSessionThatIsNoLongerWarm() async throws {
        let (store, record, model, warmth) = try makeHarness(id: "force-refresh-stale")
        warmth.isCurrent = false
        #expect(!store.canReturnToWarmSession(id: record.id))
        var calls = 0
        store.configureCanonicalSessionReentry { source, retained in
            calls += 1
            #expect(source.id == record.id)
            #expect(retained === model)
            warmth.isCurrent = true
        }

        try await store.forceRefreshSession(id: record.id)

        #expect(calls == 1)
        #expect(store.canReturnToWarmSession(id: record.id))
    }

    @Test func sameOwnerForegroundRecoversAfterNavigationSuspension() async throws {
        let (store, record, model, warmth) = try makeHarness(id: "foreground-suspended")
        model.draft = "Keep the unsent foreground draft"
        var calls = 0
        store.configureCanonicalSessionReentry { source, retained in
            calls += 1
            #expect(source.id == record.id)
            #expect(retained === model)
            warmth.isCurrent = true
        }
        store.cancelNavigationHydrations()
        warmth.isCurrent = false
        #expect(!store.canReturnToWarmSession(id: record.id))

        try await store.forceRefreshSession(id: record.id)

        #expect(calls == 1)
        #expect(model.draft == "Keep the unsent foreground draft")
        #expect(store.canReturnToWarmSession(id: record.id))
        guard case .chat(let retained)? = store.preparedModel(for: .chat(conversationID: record.id)) else {
            Issue.record("Foreground recovery discarded the retained model")
            return
        }
        #expect(retained === model)
    }

    private final class Warmth {
        var isCurrent = true
    }

    private func makeHarness(id: String) throws -> (
        store: ShellFeatureStore,
        record: SessionRecord,
        model: ChatModel,
        warmth: Warmth
    ) {
        let warmth = Warmth()
        let owner = WorkspaceOwner(
            authority: try .direct(
                endpointIdentity: "https://force-refresh.example.test",
                providerID: "fixture",
                userID: id
            ),
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let record = SessionRecord(
            id: id,
            kind: .direct,
            agentIDs: ["default"],
            title: "Force Refresh"
        )
        let catalog = SessionCatalogStore(
            client: DemoSessionCatalogClient(records: [record]),
            records: [record]
        )
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            navigationWorkspaceOwner: { owner },
            nativeWarmSessionIsCurrent: { source, retained in
                warmth.isCurrent && source.id == id && retained.conversationID == id
            }
        )
        #expect(store.prepareNewChat(.chat(conversationID: id)))
        guard case .chat(let model)? = store.preparedModel(for: .chat(conversationID: id)) else {
            throw RefreshFailure.rejected
        }
        return (store, record, model, warmth)
    }
}
