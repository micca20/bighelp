import Foundation
import Testing
@testable import Loopdy

@MainActor
struct AgentDefaultsClientBehaviorTests {
    @Test func defaultsOnlyBootstrapDoesNotStartAnotherProviderDiscovery() async throws {
        let base = EmptyBootstrapDefaultsClient()
        let client = CachedAgentRuntimeDefaultsClient(base: base, connectionIdentity: "fixture-host")
        _ = try await client.loadDefaults(agentID: "studio")
        #expect(base.providerCalls == 0)
        #expect(client.cachedModelProviders(agentID: "studio") == nil)
        let full = try await client.loadCatalog(agentID: "studio")
        #expect(base.providerCalls == 1)
        #expect(full.providers == base.providers)
        #expect(full.support.reasoningUnavailableReasons[.scheduledTasks] == "Inherited from Hermes")
    }

    @Test func editorDoesNotInventAnIndependentScheduledReasoningPreference() async {
        let base = EmptyBootstrapDefaultsClient()
        let model = AgentRuntimeDefaultsEditorModel(agentID: "studio", client: base)
        await model.load()
        model.selectReasoning("high", for: .scheduledTasks)
        #expect(model.draft.scheduledTasks.reasoningEffort == "")
        #expect(model.errorMessage == "Inherited from Hermes")
        #expect(!model.isDirty)
    }

    @Test func namespaceWithoutARevisionRemainsReadOnly() throws {
        let row = try DirectHermesAgentProfileService.decodeRow(.object([
            "name": .string("studio"), "is_default": .boolean(false), "has_avatar": .boolean(false),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Studio")])]),
            "ui_meta_revisions": .null
        ]))
        #expect(row.namespaceRevision == nil)
    }

    @Test func oversizedInstructionDataIsRejectedInsteadOfTruncated() {
        #expect(throws: WorkspaceClientError.capacityExceeded) {
            try DirectHermesAgentProfileService.text(String(repeating: "x", count: 256_001), maximumBytes: 256_000)
        }
        #expect(throws: Never.self) {
            try DirectHermesAgentProfileService.text(String(repeating: "x", count: 256_000), maximumBytes: 256_000)
        }
    }
}

@MainActor
private final class EmptyBootstrapDefaultsClient: AgentRuntimeDefaultsClient {
    var providerCalls = 0
    let providers = [LoopdyLinkModelProvider(
        id: "fixture", name: "Fixture", isCurrent: true, isCustom: false, models: ["one"]
    )]

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults { .automatic }

    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        AgentRuntimeDefaultsCatalog(
            defaults: .automatic, providers: [],
            support: AgentRuntimeDefaultsSupport(reasoningUnavailableReasons: [.scheduledTasks: "Inherited from Hermes"])
        )
    }

    func loadModelProviders(agentID: String) async throws -> [LoopdyLinkModelProvider] {
        providerCalls += 1
        return providers
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {}
}
