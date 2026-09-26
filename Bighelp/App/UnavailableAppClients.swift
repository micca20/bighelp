import Foundation

/// Before native authority is selected, the shell has no transport. These
/// placeholders never open cloud credentials, send requests or synthesize data.
/// NativeWorkspaceRuntime replaces them; fixtures are selected explicitly.
@MainActor
final class UnavailableAppCatalogClient: AgentDirectoryClient, AgentRuntimeDefaultsClient,
    HermesWorkspaceCatalogClient, ScheduledTasksClient, ApprovalRequestLoading, ApprovalClient {
    func list() async throws -> [AgentProfile] { throw WorkspaceClientError.transportUnavailable }
    func create(_ draft: AgentDraft) async throws -> AgentProfile { throw WorkspaceClientError.transportUnavailable }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile { throw WorkspaceClientError.transportUnavailable }
    func resetForAccountBoundary() {}
    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults { throw WorkspaceClientError.transportUnavailable }
    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws { throw WorkspaceClientError.transportUnavailable }
    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] { throw WorkspaceClientError.transportUnavailable }
    func load(agentID: String) async throws -> HermesWorkspaceCatalog { throw WorkspaceClientError.transportUnavailable }
    func select(id: String, agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog { throw WorkspaceClientError.transportUnavailable }
    func create(name: String, folderPath: String, agentID: String) async throws -> HermesWorkspaceCatalog { throw WorkspaceClientError.transportUnavailable }
    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog { throw WorkspaceClientError.transportUnavailable }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int, limit: Int, agentID: String) async throws -> HermesWorkspaceFolderPage { throw WorkspaceClientError.transportUnavailable }
    func list(agentID: String?) async throws -> [ScheduledTask] { throw WorkspaceClientError.transportUnavailable }
    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask { throw WorkspaceClientError.transportUnavailable }
    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask { throw WorkspaceClientError.transportUnavailable }
    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask { throw WorkspaceClientError.transportUnavailable }
    func runNow(id: String, agentID: String) async throws -> ScheduledTask { throw WorkspaceClientError.transportUnavailable }
    func delete(id: String, agentID: String) async throws { throw WorkspaceClientError.transportUnavailable }
    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] { throw WorkspaceClientError.transportUnavailable }
    func loadApproval(id: String) async throws -> LoadedApprovalRequest { throw WorkspaceClientError.transportUnavailable }
    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt { throw WorkspaceClientError.transportUnavailable }
}

@MainActor
final class UnavailableAppSessionCatalogClient: SessionCatalogClient {
    var canDeleteConversation: Bool { false }
    var allowsLocalAgentReassignment: Bool { false }
    func list() async throws -> [SessionRecord] { throw WorkspaceClientError.transportUnavailable }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord { throw WorkspaceClientError.transportUnavailable }
    func hydrate(_ record: SessionRecord) async throws -> SessionRecord { throw WorkspaceClientError.transportUnavailable }
}
