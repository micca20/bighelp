import Foundation

/// Keeps feature models stable through reconnect while each operation uses an
/// immutable, exact-owner delegate. Old in-flight delegates cannot borrow a
/// replacement connection or a new plugin context.
@MainActor
final class WorkspaceOwnedClientBox<Client> {
    typealias Factory = @MainActor (
        DirectHermesWorkspaceClient, WorkspaceOwner, @escaping @MainActor () -> WorkspaceOwner?
    ) throws -> Client

    private struct ContextStamp: Equatable {
        let runtimeID: String
        let etag: String
        init(_ context: DirectHermesNativeContext) {
            runtimeID = context.runtimeID
            etag = context.etag
        }
    }

    private let connections: WorkspaceConnectionStore
    private let authority: WorkspaceAuthority
    private let factory: Factory
    private let contextSensitive: Bool
    private var revision = UUID()
    private var cachedOwner: WorkspaceOwner?
    private var cachedContext: ContextStamp?
    private var cached: Client?

    init(connections: WorkspaceConnectionStore, authority: WorkspaceAuthority,
         contextSensitive: Bool = false, factory: @escaping Factory) {
        self.connections = connections
        self.authority = authority
        self.contextSensitive = contextSensitive
        self.factory = factory
    }

    /// Reading this observable owner stamp also lets retained controls update
    /// when a reconnect finishes verifying the new connection's capabilities.
    var hasCurrentCapabilities: Bool {
        guard let owner = connections.owner else { return false }
        return connections.capabilities.owner == owner
    }

    func value() throws -> Client {
        guard let owner = connections.owner, owner.authority == authority,
              let workspace = connections.workspace else { throw WorkspaceClientError.transportUnavailable }
        let stamp = contextSensitive ? workspace.nativeContext.map(ContextStamp.init) : nil
        if cachedOwner == owner, cachedContext == stamp, let cached { return cached }
        let revision = revision
        let value = try factory(workspace, owner) { [weak self] in
            guard let self, self.revision == revision, self.connections.owner == owner,
                  !self.contextSensitive
                    || self.connections.workspace?.nativeContext.map(ContextStamp.init) == stamp else { return nil }
            return owner
        }
        cachedOwner = owner
        cachedContext = stamp
        cached = value
        return value
    }

    func reset() {
        revision = UUID()
        cached = nil
        cachedOwner = nil
        cachedContext = nil
    }
}

@MainActor
final class WorkspaceAgentDirectoryProxy: AgentDirectoryClient {
    let box: WorkspaceOwnedClientBox<any AgentDirectoryClient>
    init(box: WorkspaceOwnedClientBox<any AgentDirectoryClient>) { self.box = box }
    func list() async throws -> [AgentProfile] { try await box.value().list() }
    func create(_ draft: AgentDraft) async throws -> AgentProfile { try await box.value().create(draft) }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        try await box.value().update(id: id, draft: draft)
    }
    func resetForAccountBoundary() { box.reset() }
}

@MainActor
final class WorkspaceAgentDefaultsProxy: AgentRuntimeDefaultsConfirmingClient {
    let box: WorkspaceOwnedClientBox<any AgentRuntimeDefaultsClient>
    init(box: WorkspaceOwnedClientBox<any AgentRuntimeDefaultsClient>) { self.box = box }
    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        try await box.value().loadCatalog(agentID: agentID)
    }
    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        try await box.value().loadDefaults(agentID: agentID)
    }
    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        try await box.value().loadModelProviders(agentID: agentID)
    }
    func refreshModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        try await box.value().refreshModelProviders(agentID: agentID)
    }
    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]? {
        (try? box.value())?.cachedModelProviders(agentID: agentID)
    }
    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {
        try await box.value().saveDefaults(defaults, agentID: agentID)
    }
    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String,
                      confirmation: AgentRuntimeDefaultsSaveConfirmation) async throws {
        guard let client = try box.value() as? any AgentRuntimeDefaultsConfirmingClient else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        try await client.saveDefaults(defaults, agentID: agentID, confirmation: confirmation)
    }
}

@MainActor
final class WorkspaceScheduledTasksProxy: ScheduledTasksClient {
    let box: WorkspaceOwnedClientBox<any ScheduledTasksClient>
    init(box: WorkspaceOwnedClientBox<any ScheduledTasksClient>) { self.box = box }
    func list(agentID: String?) async throws -> [ScheduledTask] { try await box.value().list(agentID: agentID) }
    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] { try await box.value().deliveryTargets() }
    func detail(id: String, agentID: String) async throws -> ScheduledTask {
        try await box.value().detail(id: id, agentID: agentID)
    }
    func runs(id: String, agentID: String, limit: Int) async throws -> [ScheduledTaskRun] {
        try await box.value().runs(id: id, agentID: agentID, limit: limit)
    }
    func blueprints() async throws -> [ScheduledTaskBlueprint] {
        try await box.value().blueprints()
    }
    func instantiate(_ blueprint: ScheduledTaskBlueprint, values: [String: String], agentID: String) async throws -> ScheduledTask {
        try await box.value().instantiate(blueprint, values: values, agentID: agentID)
    }
    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask { try await box.value().create(draft) }
    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        try await box.value().update(id: id, agentID: agentID, changes: changes)
    }
    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        try await box.value().setPaused(paused, id: id, agentID: agentID)
    }
    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        try await box.value().runNow(id: id, agentID: agentID)
    }
    func delete(id: String, agentID: String) async throws { try await box.value().delete(id: id, agentID: agentID) }
}

@MainActor
final class WorkspaceProjectsProxy: HermesWorkspaceCatalogClient {
    let box: WorkspaceOwnedClientBox<any HermesWorkspaceCatalogClient>
    init(box: WorkspaceOwnedClientBox<any HermesWorkspaceCatalogClient>) { self.box = box }
    func load(agentID: String) async throws -> HermesWorkspaceCatalog { try await box.value().load(agentID: agentID) }
    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        try await box.value().load(agentID: agentID, sessionID: sessionID)
    }

    func select(id: String, agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        try await box.value().select(id: id, agentID: agentID, sessionID: sessionID)
    }
    func create(name: String, folderPath: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        try await box.value().create(name: name, folderPath: folderPath, agentID: agentID)
    }
    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        try await box.value().archive(id: id, agentID: agentID)
    }
    func describe(id: String, description: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        try await box.value().describe(id: id, description: description, agentID: agentID)
    }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int, limit: Int,
                           agentID: String) async throws -> HermesWorkspaceFolderPage {
        try await box.value().folderSuggestions(parentPath: parentPath, prefix: prefix, offset: offset,
                                               limit: limit, agentID: agentID)
    }
}
