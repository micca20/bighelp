import Foundation

/// Reads the person's other hosts with their own saved sign-ins. Each host
/// keeps one connection, owned by the host registry; a host that wasn't
/// connected is connected for the read and let go after it. The selected host
/// is never read here: it's live in the app already.
@MainActor
final class RegistryFleetReader: FleetHostReading {
    private let registry: BighelpHostRegistry

    init(registry: BighelpHostRegistry) { self.registry = registry }

    var hosts: [FleetHost] {
        registry.hosts.map { FleetHost(id: $0.id, name: $0.name, isSelected: $0.id == registry.selectedHostID) }
    }

    func select(_ hostID: UUID) { registry.select(hostID) }
    func canOpen(_ hostID: UUID) -> Bool { registry.hosts.contains { $0.id == hostID } }

    func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
        do {
            return try await readNow(hostID, avatars: avatars)
        } catch {
            // Picked while it was read: the app owns it now, and it's live.
            if registry.selectedHostID == hostID { throw CancellationError() }
            throw error
        }
    }

    private func readNow(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
        guard registry.selectedHostID != hostID, registry.isWorkspaceReady,
              let host = registry.hosts.first(where: { $0.id == hostID }) else { throw CancellationError() }
        let store = registry.workspace(for: host)
        let connectsHere = !store.isConnected
        if connectsHere {
            guard !store.isConnecting else { throw FleetReadError(message: "Still connecting to this host.") }
            await store.reconnect()
        }
        // Let the connection go again, unless the app switched to this host meanwhile.
        defer { if connectsHere, registry.selectedHostID != hostID { store.suspendForPresentationExit() } }
        guard registry.selectedHostID != hostID else { throw CancellationError() }
        guard store.isConnected, let client = store.nativeClient, let saved = store.savedConnection,
              DirectHermesIdentity.matches(saved.identity, host.principalIdentity),
              let authority = saved.workspaceAuthority else {
            throw FleetReadError(message: store.hasSavedConnection
                ? "Couldn't reach this host." : "Sign in to this host again in Settings.")
        }

        let generation = store.connectionGeneration
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: generation)
        let current: @MainActor () -> WorkspaceOwner? = { [weak registry, weak store] in
            guard let registry, let store, registry.selectedHostID != hostID, store.isConnected,
                  store.connectionGeneration == generation else { return nil }
            return owner
        }
        let workspace = DirectHermesWorkspaceClient(rpc: client, http: client, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: current)
        let manifest = try await store.discoverCapabilityManifest(expectedOwner: generation)
        var availability = manifest.operationAvailability
        for capability in manifest.supportedOperations.union(DirectHermesReleaseContract.profileOperations) {
            availability[capability] = .available
        }
        try workspace.installCapabilities(WorkspaceCapabilities(owner: owner, values: availability))

        let profiles = try await DirectHermesAgentDirectoryClient(
            workspace: workspace, owner: owner, currentOwner: current
        ).list()
        let pinned = Self.pinnedAgentIDs(scope: authority.cacheScopeID) ?? profiles.filter(\.isDefault).map(\.id)

        var chats: [FleetChat] = []
        var activity: [String: FleetActivity] = [:]
        for profile in profiles.prefix(40) {
            let listed = try await workspace.perform(.sessionsList, payload: [
                "profile": .string(profile.id), "limit": .integer(20), "offset": .integer(0),
                "archived": .string("exclude"), "order": .string("recent"),
                "exclude_sources": .string("tool,kanban,bot_room,cron"),
            ], owner: owner)
            var live: [String: String] = [:]
            if let active = try? await workspace.perform(.nativeSessionActiveList,
                                                         payload: ["profile": .string(profile.id)], owner: owner) {
                for row in active["sessions"]?.array ?? [] {
                    guard let key = row.object?["session_key"]?.string, let status = row.object?["status"]?.string
                    else { continue }
                    live[key] = status
                }
            }
            for row in listed["sessions"]?.array ?? [] {
                guard let chat = Self.chat(row, hostID: hostID, profileID: profile.id, live: live) else { continue }
                chats.append(chat)
            }
            if live.values.contains(where: Self.workingStatuses.contains) { activity[profile.id] = .working }
            else if live.values.contains("waiting") { activity[profile.id] = .waiting }
        }

        let tasks = (try? await DirectHermesScheduledTasksClient(
            workspace: workspace, owner: owner, currentOwner: current, http: client
        ).list(agentID: nil)) ?? []

        let agents = profiles.map { profile in
            FleetAgent(hostID: hostID, profileID: profile.id, name: profile.name, role: profile.role,
                       avatarFile: profile.avatar.flatMap { avatars.store($0) }, isPinned: pinned.contains(profile.id),
                       isDefault: profile.isDefault, activity: activity[profile.id])
        }
        return FleetSnapshot(agents: agents, chats: chats,
                             tasks: tasks.map { FleetTask(hostID: hostID, scheduledTask: $0) }, refreshedAt: Date())
    }

    static let workingStatuses: Set<String> = ["starting", "working", "streaming", "resuming"]

    /// Agents pinned on this host, as the app saved them while it was selected.
    private static func pinnedAgentIDs(scope: String) -> [String]? {
        guard let defaults = UserDefaults(suiteName: "app.loopdy.native-workspace." + scope) else { return nil }
        return AgentDirectoryStore.savedPinnedAgentIDs(in: defaults, hostBucket: scope)
    }

    /// One row of Hermes' session list, leniently: a row it can't read is skipped.
    static func chat(_ value: BighelpJSONValue, hostID: UUID, profileID: String,
                             live: [String: String]) -> FleetChat? {
        guard let row = value.object,
              let id = try? DirectHermesSessionValidation.string(row["id"]),
              let started = (try? DirectHermesSessionValidation.date(row["started_at"])) ?? nil else { return nil }
        let updated = (try? DirectHermesSessionValidation.date(row["last_active"] ?? row["last_activity_at"])) ?? nil
        let title = ((try? DirectHermesSessionValidation.optionalText(row["title"], maximum: 4_096)) ?? nil) ?? ""
        let preview = ((try? DirectHermesSessionValidation.optionalText(row["preview"], maximum: 64 * 1_024)) ?? nil) ?? ""
        let status = live[id]
        return FleetChat(hostID: hostID, profileID: profileID, storedSessionID: id, appSessionID: nil,
                         title: title, preview: HermesUserMessageDisplay.preview(preview),
                         updatedAt: updated ?? started,
                         isActive: status.map(workingStatuses.contains) ?? false)
    }
}

extension FleetTask {
    init(hostID: UUID, scheduledTask task: ScheduledTask) {
        self.init(hostID: hostID, jobID: task.id, profileID: task.agentID, name: task.name,
                  schedule: ScheduledTaskCopy.friendlySchedule(task), nextRun: task.nextRun, status: task.status)
    }
}
