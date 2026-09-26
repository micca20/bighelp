import Foundation

enum NativeWorkspaceLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case ownerChanged
    case invalidConstruction
    case durableSessionUnavailable
    case profileStateCouldNotBeVerified(profileID: String)
    case protectedProfileState(profileID: String, sessionIDs: [String])
    case sharedStateMismatch

    var errorDescription: String? {
        switch self {
        case .ownerChanged:
            "The selected Hermes connection changed. Reopen this lifecycle screen."
        case .invalidConstruction:
            "Profile and session lifecycle controls require the retained native Hermes owner."
        case .durableSessionUnavailable:
            "Hermes confirmed this stored session, but the current profile catalog could not resolve its exact durable identity. Refresh Sessions before trying again."
        case .profileStateCouldNotBeVerified:
            "bighelp could not verify every saved draft for this profile, so the profile change was not sent."
        case .protectedProfileState(_, let sessionIDs):
            "Resolve or save the pending work in \(sessionIDs.count) profile session(s) before renaming or deleting this profile. No profile change was sent."
        case .sharedStateMismatch:
            "Hermes confirmed the profile change, but the shared bighelp stores did not reconcile to the exact readback. Reopen Profiles; do not repeat the server operation."
        }
    }
}

/// Retains the one production native owner used by lifecycle views. It builds
/// fixed-route clients from the selected connection and exposes the exact view
/// callbacks; callers must supply navigation/cache reconciliation explicitly.
@MainActor
final class NativeWorkspaceLifecycleCoordinator {
    typealias AdoptedSessionHandler = @MainActor (SessionSummary) async throws -> Void
    typealias RetiredProfileHandler = @MainActor (
        HermesProfileLifecycleChange, [String]
    ) async throws -> Void
    typealias ReconciledProfileHandler = @MainActor (
        HermesProfileLifecycleResult
    ) async throws -> Void
    typealias ReconciledClosedRuntimeHandler = @MainActor (
        String, HermesSessionCloseResult
    ) async throws -> Void

    let owner: WorkspaceOwner
    let hostName: String
    let sessionMaintenanceClient: DirectHermesSessionMaintenanceClient
    let profileLifecycleClient: DirectHermesProfileLifecycleClient

    private let connections: WorkspaceConnectionStore
    private let catalog: SessionCatalogStore
    private let agents: AgentDirectoryStore
    private let bridge: NativeWorkspaceSessionBridge
    private let adoptedSession: AdoptedSessionHandler
    private let retiredProfile: RetiredProfileHandler
    private let reconciledProfile: ReconciledProfileHandler

    init(
        owner: WorkspaceOwner,
        connections: WorkspaceConnectionStore,
        catalog: SessionCatalogStore,
        agents: AgentDirectoryStore,
        bridge: NativeWorkspaceSessionBridge,
        adoptedSession: @escaping AdoptedSessionHandler,
        retiredProfile: @escaping RetiredProfileHandler,
        reconciledProfile: @escaping ReconciledProfileHandler,
        reconciledClosedRuntime: @escaping ReconciledClosedRuntimeHandler
    ) throws {
        guard owner.authority.kind == .direct,
              connections.owner == owner,
              bridge.authority == owner.authority,
              let host = connections.selectedDirectHost,
              let direct = connections.hosts.selectedWorkspace?.nativeClient else {
            throw NativeWorkspaceLifecycleError.invalidConstruction
        }
        self.owner = owner
        hostName = host.name
        self.connections = connections
        self.catalog = catalog
        self.agents = agents
        self.bridge = bridge
        self.adoptedSession = adoptedSession
        self.retiredProfile = retiredProfile
        self.reconciledProfile = reconciledProfile
        let currentOwner: @MainActor () -> WorkspaceOwner? = { [weak connections] in
            connections?.owner
        }
        sessionMaintenanceClient = DirectHermesSessionMaintenanceClient(
            rpc: direct, http: direct, owner: owner, currentOwner: currentOwner,
            resolveClosableRuntime: { request in
                guard currentOwner() == owner, bridge.authority == owner.authority else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
                return try await bridge.resolveClosableRuntime(request)
            },
            reconcileClosedRuntime: { result in
                guard currentOwner() == owner, bridge.authority == owner.authority else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
                let visibleID = try bridge.reconcileClosedRuntime(result)
                guard currentOwner() == owner,
                      let retained = catalog.session(id: visibleID),
                      retained.kind == .direct, retained.agentIDs.count == 1,
                      retained.agentIDs[0].utf8.elementsEqual(result.profileID.utf8),
                      retained.remoteStoredID.map({
                          $0.utf8.elementsEqual(result.storedSessionID.utf8)
                      }) == true,
                      !retained.isActive else {
                    throw NativeWorkspaceLifecycleError.sharedStateMismatch
                }
                try await reconciledClosedRuntime(visibleID, result)
                guard currentOwner() == owner else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
            }
        )
        profileLifecycleClient = DirectHermesProfileLifecycleClient(
            rpc: direct, http: direct, owner: owner, currentOwner: currentOwner
        )
    }

    func sessionMaintenanceView(profileID: String) -> SessionMaintenanceView {
        SessionMaintenanceView(
            hostName: hostName,
            profileID: profileID,
            client: sessionMaintenanceClient,
            onAdoptSession: { [self] request in
                try await onAdoptSession(request)
            }
        )
    }

    func profileLifecycleView(selectedProfileID: String) -> ProfileLifecycleView {
        ProfileLifecycleView(
            hostName: hostName,
            selectedProfileID: selectedProfileID,
            client: profileLifecycleClient,
            retireProfileOwnership: { [self] change in
                try await retireProfileOwnership(change)
            },
            onProfileChanged: { [self] result in
                try await onProfileChanged(result)
            }
        )
    }

    /// Resolves imported, foreign and lineage results through the authoritative
    /// profile catalog, prepares the current bridge coordinate, then delegates
    /// to Root's retained navigation/model adoption path.
    func onAdoptSession(_ request: SessionMaintenanceAdoptionRequest) async throws {
        try requireOwner()
        let record: SessionRecord
        do {
            record = try await catalog.resolveStoredSession(
                profileID: request.profileID,
                storedSessionID: request.storedSessionID
            )
        } catch NativeWorkspaceLifecycleError.durableSessionUnavailable {
            let prepared = try await bridge.prepareStoredSession(
                profileID: request.profileID,
                storedSessionID: request.storedSessionID
            )
            record = try catalog.installWorkspaceRecord(prepared, ownerIsCurrent: { [self] in
                connections.owner == owner
            })
        }
        try requireOwner()
        guard let coordinate = bridge.currentCoordinate(for: record.id),
              coordinate.owner == owner,
              coordinate.profileID.utf8.elementsEqual(request.profileID.utf8),
              coordinate.storedSessionID.map({
                  $0.utf8.elementsEqual(request.storedSessionID.utf8)
              }) == true else {
            throw NativeWorkspaceLifecycleError.durableSessionUnavailable
        }
        try await adoptedSession(record.summary)
        try requireOwner()
    }

    /// Called by the fixed-route lifecycle client after review recheck and
    /// before mutation. Default activation changes no current ownership.
    /// Rename/delete refuse while any target draft, uncertain submission,
    /// prompt, live turn, group membership or unreadable local payload remains.
    func retireProfileOwnership(_ change: HermesProfileLifecycleChange) async throws {
        try requireOwner()
        let profileID: String
        switch change {
        case .renamed(let from, _): profileID = from
        case .deleted(let deleted): profileID = deleted
        case .defaultActivated:
            return
        case .imported, .descriptionChanged, .onboardingFactsSaved:
            throw NativeWorkspaceLifecycleError.invalidConstruction
        }

        catalog.flushPersistence()
        var blocked = Set<String>()
        let scoped = catalog.records.filter { record in
            record.agentIDs.contains { $0.utf8.elementsEqual(profileID.utf8) }
        }
        for summary in scoped {
            let record: SessionRecord
            do {
                record = try catalog.restoreSessionContent(id: summary.id)
            } catch {
                throw NativeWorkspaceLifecycleError.profileStateCouldNotBeVerified(
                    profileID: profileID
                )
            }
            if record.kind == .botMode
                || record.isLocalPresentationDraft
                || !record.draft.isEmpty
                || record.referenceState?.submission != nil
                || record.hasDeferredReferenceState
                || record.hasActiveWork {
                blocked.insert(record.id)
            }
        }
        for state in try bridge.profileSessionOwnership(profileID: profileID)
            where state.blocksDestructiveRetirement {
            blocked.insert(state.sessionID)
        }
        guard blocked.isEmpty else {
            throw NativeWorkspaceLifecycleError.protectedProfileState(
                profileID: profileID,
                sessionIDs: blocked.sorted()
            )
        }

        let retiredStreamIDs = try bridge.retireProfileSessions(profileID: profileID)
        let affectedSessionIDs = Set(scoped.map(\.id)).union(retiredStreamIDs).sorted()
        try await retiredProfile(change, affectedSessionIDs)
        try requireOwner()
    }

    /// Reconciles only after the lifecycle client has exact server readback.
    /// Internal caches/stores are refreshed first; Root then receives one
    /// mandatory callback to reconcile selected profile and navigation.
    func onProfileChanged(_ result: HermesProfileLifecycleResult) async throws {
        try requireOwner()
        switch result.change {
        case .renamed(let from, let to):
            agents.remapProfilePreferences(from: from, to: to)
            try catalog.remapProfileOwnership(from: from, to: to)
            bridge.invalidateCatalogAfterProfileChange()
        case .deleted(let profileID):
            agents.removeProfilePreferences(profileID: profileID)
            bridge.invalidateCatalogAfterProfileChange()
        case .imported:
            bridge.invalidateCatalogAfterProfileChange()
        case .defaultActivated, .descriptionChanged, .onboardingFactsSaved:
            break
        }

        try await agents.reloadAfterProfileLifecycleChange()
        try requireOwner()
        try await catalog.load(requireAuthoritativeRefresh: true)
        try requireOwner()
        try verifySharedReadback(result)
        try await reconciledProfile(result)
        try requireOwner()
    }

    private func verifySharedReadback(_ result: HermesProfileLifecycleResult) throws {
        let agentIDs = agents.profiles.map(\.id)
        func containsAgent(_ id: String) -> Bool {
            agentIDs.contains { $0.utf8.elementsEqual(id.utf8) }
        }
        let expectedAgentIDs = Set(result.catalog.profiles.map { Data($0.id.utf8) })
        let actualAgentIDs = Set(agentIDs.map { Data($0.utf8) })
        guard actualAgentIDs == expectedAgentIDs else {
            throw NativeWorkspaceLifecycleError.sharedStateMismatch
        }
        switch result.change {
        case .renamed(let from, let to):
            guard containsAgent(to), !containsAgent(from),
                  !catalog.records.contains(where: { record in
                      record.agentIDs.contains { $0.utf8.elementsEqual(from.utf8) }
                  }) else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
        case .deleted(let profileID):
            guard !containsAgent(profileID),
                  !catalog.records.contains(where: { record in
                      record.agentIDs.contains { $0.utf8.elementsEqual(profileID.utf8) }
                  }) else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
        case .imported(let profileID), .defaultActivated(let profileID),
             .descriptionChanged(let profileID), .onboardingFactsSaved(let profileID):
            guard containsAgent(profileID) else {
                throw NativeWorkspaceLifecycleError.sharedStateMismatch
            }
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard connections.owner == owner,
              owner.authority == bridge.authority else {
            throw NativeWorkspaceLifecycleError.ownerChanged
        }
    }
}