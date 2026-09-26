import Foundation

/// One atomically observed visible-session binding supplied by the native runtime.
/// The coordinator still verifies every field against its captured owner/profile
/// and the requested Project before the value can resolve a Git target.
struct NativeStockGitVisibleSession: Equatable, Sendable {
    let coordinate: WorkspaceSessionCoordinate
    let projectID: String
}

@MainActor
struct NativeStockGitProjectPresentation {
    let coordinator: NativeStockGitCoordinator
    let projects: ProjectLifecycleStore
}

@MainActor
private final class NativeStockGitLifetime {
    var isActive = true
}

/// Owns stock Git and Project lifecycle clients for exactly one authenticated
/// native owner. ProjectGitClient calls require a verified visible session;
/// Project-detail review uses the registered Project snapshot directly.
@MainActor
final class NativeStockGitCoordinator: ProjectGitClient, StockGitManaging {
    typealias VisibleSessionResolver = @MainActor (String) -> NativeStockGitVisibleSession?

    private let authority: NativeStockGitTargetAuthority
    private let client: DirectHermesStockGitClient

    /// Factory used by NativeWorkspaceRuntime in place of the plugin-only Git
    /// client. The returned coordinator itself is the ProjectGitClient and also
    /// vends the ProjectLifecycleStore used by native Project administration.
    static func makeProjectGitClient(
        hostName: String,
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveVisibleSession: @escaping VisibleSessionResolver
    ) -> NativeStockGitCoordinator {
        NativeStockGitCoordinator(
            hostName: hostName,
            rpc: rpc,
            http: http,
            owner: owner,
            currentOwner: currentOwner,
            resolveVisibleSession: resolveVisibleSession
        )
    }

    private init(
        hostName: String,
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveVisibleSession: @escaping VisibleSessionResolver
    ) {
        let authority = NativeStockGitTargetAuthority(
            hostName: hostName,
            rpc: rpc,
            http: http,
            owner: owner,
            currentOwner: currentOwner,
            resolveVisibleSession: resolveVisibleSession
        )
        self.authority = authority
        client = DirectHermesStockGitClient(
            rpc: rpc,
            http: http,
            owner: owner,
            currentOwner: { [weak authority] in authority?.currentOwner() },
            resolveTarget: { [weak authority] profileID, sessionID, projectID in
                authority?.resolveTarget(
                    profileID: profileID,
                    visibleSessionID: sessionID,
                    projectID: projectID
                )
            },
            validateTarget: { [weak authority] target in
                authority?.owns(target) == true
            }
        )
    }

    func projects(profileID: String) throws -> ProjectLifecycleStore {
        try authority.projects(profileID: profileID)
    }

    func projectPresentation(profileID: String) throws -> NativeStockGitProjectPresentation {
        NativeStockGitProjectPresentation(
            coordinator: self,
            projects: try projects(profileID: profileID)
        )
    }

    /// Creates a retained child scope only when `projects` is the exact store
    /// owned by this coordinator for the target profile. No session is required
    /// because this path starts from a registered Project detail, not a chat.
    func projectReview(
        projectID: String,
        projects: ProjectLifecycleStore
    ) -> NativeStockGitProjectReviewCoordinator? {
        guard authority.manages(projects),
              let target = projects.stockGitTarget(projectID: projectID) else { return nil }
        return NativeStockGitProjectReviewCoordinator(
            target: target,
            client: self,
            isCurrent: { [weak authority] in authority?.owns(target) == true }
        )
    }

    func retire() {
        authority.retire()
    }

    func snapshot(
        for target: StockGitProjectTarget,
        scope: StockGitReviewScope
    ) async throws -> StockGitSnapshot {
        try await authority.prepare(profileID: target.profileID)
        return try await client.snapshot(for: target, scope: scope)
    }

    func diff(
        for target: StockGitProjectTarget,
        file: String,
        scope: StockGitReviewScope,
        staged: Bool
    ) async throws -> StockGitDiff {
        try await authority.prepare(profileID: target.profileID)
        return try await client.diff(for: target, file: file, scope: scope, staged: staged)
    }

    func fileDiffAgainstHead(
        for target: StockGitProjectTarget,
        file: String
    ) async throws -> StockGitDiff {
        try await authority.prepare(profileID: target.profileID)
        return try await client.fileDiffAgainstHead(for: target, file: file)
    }

    func prepare(
        _ action: StockGitAction,
        target: StockGitProjectTarget
    ) throws -> StockGitPreparedAction {
        try client.prepare(action, target: target)
    }

    func execute(
        _ prepared: StockGitPreparedAction,
        confirmationToken: String
    ) async throws -> StockGitActionResult {
        try await authority.prepare(profileID: prepared.target.profileID)
        return try await client.execute(prepared, confirmationToken: confirmationToken)
    }

    func capabilities(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        try await authority.prepare(profileID: agentID)
        return try await client.capabilities(
            agentID: agentID,
            sessionID: sessionID,
            workspaceID: workspaceID
        )
    }

    func status(
        agentID: String,
        sessionID: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        try await authority.prepare(profileID: agentID)
        return try await client.status(
            agentID: agentID,
            sessionID: sessionID,
            workspaceID: workspaceID
        )
    }

    func diff(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken: String,
        offset: Int,
        limit: Int
    ) async throws -> ProjectGitDiffPage {
        try await authority.prepare(profileID: agentID)
        return try await client.diff(
            agentID: agentID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            path: path,
            side: side,
            statusToken: statusToken,
            offset: offset,
            limit: limit
        )
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        try await authority.prepare(profileID: request.agentID)
        return try await client.prepare(request)
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        try await authority.prepare(profileID: request.mutation.agentID)
        return try await client.execute(request)
    }
}

/// Retains the client/store relationship for one Project detail destination.
/// Its weak lifetime fence makes a temporarily retained SwiftUI store inert as
/// soon as the destination's coordinator is released.
@MainActor
final class NativeStockGitProjectReviewCoordinator: Identifiable {
    let id = UUID()
    let store: StockGitStore

    private let lifetime: NativeStockGitLifetime

    fileprivate init(
        target: StockGitProjectTarget,
        client: any StockGitManaging,
        isCurrent parentIsCurrent: @escaping @MainActor () -> Bool
    ) {
        let lifetime = NativeStockGitLifetime()
        self.lifetime = lifetime
        store = StockGitStore(
            target: target,
            client: client,
            isCurrent: { [weak lifetime] in
                lifetime?.isActive == true && parentIsCurrent()
            }
        )
    }

    func retire() {
        guard lifetime.isActive else { return }
        lifetime.isActive = false
        store.retire()
    }
}

@MainActor
private final class NativeStockGitTargetAuthority {
    private struct ProfileKey: Hashable {
        let bytes: Data
        init(_ profileID: String) { bytes = Data(profileID.utf8) }
    }

    private let hostName: String
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let sourceCurrentOwner: @MainActor () -> WorkspaceOwner?
    private let resolveVisibleSession: NativeStockGitCoordinator.VisibleSessionResolver
    private let lifetime = NativeStockGitLifetime()
    private var projectStores: [ProfileKey: ProjectLifecycleStore] = [:]

    init(
        hostName: String,
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveVisibleSession: @escaping NativeStockGitCoordinator.VisibleSessionResolver
    ) {
        self.hostName = hostName
        self.rpc = rpc
        self.http = http
        self.owner = owner
        sourceCurrentOwner = currentOwner
        self.resolveVisibleSession = resolveVisibleSession
    }

    func currentOwner() -> WorkspaceOwner? {
        guard lifetime.isActive, sourceCurrentOwner() == owner else { return nil }
        return owner
    }

    func projects(profileID rawProfileID: String) throws -> ProjectLifecycleStore {
        try checkOwner()
        let profileID = try DirectHermesCoreRequestScope.profile(rawProfileID)
        let key = ProfileKey(profileID)
        if let store = projectStores[key] { return store }
        let client = DirectHermesProjectLifecycleClient(
            rpc: rpc,
            http: http,
            owner: owner,
            currentOwner: { [weak self] in self?.currentOwner() }
        )
        let store = ProjectLifecycleStore(
            hostName: hostName,
            profileID: profileID,
            client: client,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.currentOwner() == self.owner
            }
        )
        projectStores[key] = store
        return store
    }

    func manages(_ store: ProjectLifecycleStore) -> Bool {
        guard let current = try? projects(profileID: store.profileID) else { return false }
        return current === store
    }

    func prepare(profileID: String) async throws {
        let store = try projects(profileID: profileID)
        try await store.refreshStockGitAuthority()
        try checkOwner()
    }

    func resolveTarget(
        profileID: String,
        visibleSessionID: String,
        projectID: String
    ) -> StockGitProjectTarget? {
        guard currentOwner() == owner,
              let visible = resolveVisibleSession(visibleSessionID),
              visible.coordinate.owner == owner,
              same(visible.coordinate.profileID, profileID),
              same(visible.coordinate.sessionID, visibleSessionID),
              visible.coordinate.storedSessionID != nil,
              same(visible.projectID, projectID),
              let store = projectStores[ProfileKey(profileID)],
              let target = store.stockGitTarget(projectID: projectID),
              same(target.profileID, profileID),
              same(target.projectID, projectID) else { return nil }
        return target
    }

    func owns(_ target: StockGitProjectTarget) -> Bool {
        guard currentOwner() == owner,
              let store = projectStores[ProfileKey(target.profileID)] else { return false }
        return store.ownsStockGitTarget(target)
    }

    func retire() {
        guard lifetime.isActive else { return }
        lifetime.isActive = false
        projectStores.values.forEach { $0.retire() }
        projectStores.removeAll()
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw WorkspaceClientError.ownerChanged }
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
