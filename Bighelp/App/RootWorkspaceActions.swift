import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    @ViewBuilder
    func nativeCapabilitiesDestination(_ kind: CapabilitiesManagementKind, destination: WorkspaceDestination) -> some View {
        if let presentation = capabilitiesPresentation,
           presentation.kind == kind, currentWorkspaceOwner == presentation.owner,
           workspaceAgentID == presentation.profileID {
            CapabilitiesManagementView(kind: kind, hostName: workspaceHostName,
                profileName: workspaceProfileName, dependencies: presentation.dependencies)
                .id(presentation.id)
                .toolbar {
                    if kind == .skills {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Edit Skills") { appState.open(.skillsAndTools) }
                        }
                    }
                }
        } else {
            WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                reason: "Open this feature again after connecting to the selected host and profile.")
        }
    }
    func openWorkspaceDestination(_ destination: WorkspaceDestination) {
        if destination == .sessionMaintenance || destination == .profileLifecycle {
            openLifecycleDestination(destination)
            return
        }
        lifecycleCoordinator = nil
        lifecycleProfileID = nil
        lifecyclePresentationID = nil
        if NativeAdministrationPresentation.supports(destination), !usesWorkspaceFixtures {
            managementStore?.retire()
            managementStore = nil
            administrationPresentation?.retire()
            administrationPresentation = nil
            if let owner = currentWorkspaceOwner,
               let connections = workspaceConnections,
               let direct = connections.hosts.selectedWorkspace?.nativeClient,
               let invalidationSource = connections.nativeInvalidationSource(authority: owner.authority) {
                let profileID = workspaceAgentID
                let servingProfileID = connections.workspace?.nativeContext?.servingProfileID
                guard invalidationSource.owner == owner,
                      Data(invalidationSource.profileID.utf8) == Data(profileID.utf8),
                      invalidationSource.servingProfileID.map({ Data($0.utf8) })
                        == servingProfileID.map({ Data($0.utf8) }) else {
                    actionErrorMessage = "Management updates could not be connected. Reopen this feature after refreshing the selected host."
                    return
                }
                let stockGit: NativeStockGitProjectPresentation?
                if destination == .projects, let runtime = nativeRuntime {
                    do { stockGit = try runtime.stockGitPresentation(profileID: profileID) }
                    catch {
                        actionErrorMessage = "Project changes could not be connected. Reopen Projects after refreshing this host."
                        return
                    }
                } else {
                    stockGit = nil
                }
                administrationPresentation = NativeAdministrationPresentation(
                    destination: destination, hostName: workspaceHostName, profileID: profileID,
                    servingProfileID: servingProfileID,
                    rpc: direct, http: direct, owner: owner, currentOwner: {
                        guard Data(workspaceAgentID.utf8) == Data(profileID.utf8) else { return nil }
                        return currentWorkspaceOwner
                    }, connections: connections, invalidationSource: invalidationSource, stockGit: stockGit)
            }
            appState.open(.workspaceManagement(destination))
            return
        }
        if let kind = CapabilitiesManagementKind(destination: destination), !usesWorkspaceFixtures {
            managementStore?.retire()
            managementStore = nil
            capabilitiesPresentation = nil
            if let owner = currentWorkspaceOwner,
               let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient {
                let profileID = workspaceAgentID
                let current: @MainActor () -> WorkspaceOwner? = {
                    guard workspaceAgentID == profileID else { return nil }
                    return currentWorkspaceOwner
                }
                let actionStatusClient = DirectHermesHostOperationsClient(rpc: direct, http: direct,
                    owner: owner, currentOwner: current)
                capabilitiesPresentation = NativeCapabilitiesPresentation(
                    kind: kind, owner: owner, profileID: profileID,
                    dependencies: CapabilitiesManagementDependencies(
                        skills: DirectHermesSkillsHubClient(http: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient),
                        mcp: DirectHermesMCPClient(http: direct, rpc: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient),
                        plugins: DirectHermesPluginLifecycleClient(http: direct, owner: owner, currentOwner: current),
                        toolsets: DirectHermesToolsetClient(http: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient)
                    )
                )
            }
            appState.open(.workspaceManagement(destination))
            return
        }
        switch destination {
        case .activity:
            appState.open(.workspaceActivity)
        case .scheduledTasks:
            openScheduledTasks(filteredTo: nil)
        case .tasks, .artifacts:
            appState.open(.workspaceManagement(destination))
        case .logs:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(.logs))
        case .wiki:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(.wiki))
        case .skills:
            appState.open(.skillsAndTools)
        case .profiles:
            guard let owner = currentWorkspaceOwner,
                  let profile = agents.resolvedAgent(explicitID: nil),
                  currentWorkspaceCapabilities.supports(.profilesEdit, owner: owner, profileID: profile.id) else {
                actionErrorMessage = "Connect to this host before editing its agent profile."
                return
            }
            workspaceProfileEditor = .editing(profile, store: agents, processor: AvatarImageProcessor(),
                                               isCurrent: { currentWorkspaceOwner == owner })
        case .instances:
            appState.open(.workspaceConnections)
        case .security, .appearance, .tabBar, .caching, .contact, .watch:
            appState.open(.workspaceManagement(destination))
        case .voice, .permissions, .documentation:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(destination))
        default:
            managementStore?.retire()
            managementStore = nil
            let profileID = workspaceAgentID
            if usesWorkspaceFixtures, let owner = currentWorkspaceOwner {
                managementStore = WorkspaceManagementStore(
                    hostName: workspaceHostName, profileName: workspaceProfileName,
                    client: FixtureWorkspaceManagementClient(),
                    isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
                )
            } else if let owner = currentWorkspaceOwner, let performer = workspaceConnections?.workspace {
                managementStore = WorkspaceManagementStore(
                    hostName: workspaceHostName, profileName: workspaceProfileName,
                    client: NativeWorkspaceManagementClient(
                        owner: owner, profileID: profileID, performer: performer,
                        isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
                    ),
                    isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
                )
            }
            appState.open(.workspaceManagement(destination))
        }
    }

    /// Deleting from the Agents screen or the agent editor. Same lifecycle path
    /// as Profiles, with no navigation beyond leaving a chat that was retired.
    /// Lets other screens (the Chats rail) offer the Agents list's hold menu.
    var agentActionsConfig: AgentActionsConfig {
        AgentActionsConfig(
            store: agents, runtimeDefaultsClient: agentRuntimeDefaults, owner: currentWorkspaceOwner,
            capabilities: currentWorkspaceCapabilities, cloneClient: workspaceConnections?.cloneClient,
            shortcutsAvailable: usesWorkspaceFixtures || (nativeRuntime != nil && currentWorkspaceOwner != nil),
            onAction: handleAgentWorkspaceAction, agentDeletion: agentDeletionAction
        )
    }

    var agentDeletionAction: AgentDeletionAction? {
        guard nativeRuntime != nil, workspaceConnections != nil, currentWorkspaceOwner != nil else { return nil }
        return AgentDeletionAction { profileID in try await deleteAgentProfile(profileID) }
    }

    func deleteAgentProfile(_ profileID: String) async throws {
        guard let connections = workspaceConnections, let owner = currentWorkspaceOwner,
              connections.owner == owner, let runtime = nativeRuntime else {
            throw WorkspaceClientError.unavailable(.notConnected)
        }
        let coordinator = try NativeWorkspaceLifecycleCoordinator(
            owner: owner, connections: connections, catalog: sessionCatalog, agents: agents, bridge: runtime.bridge,
            adoptedSession: { _ in throw CancellationError() },
            retiredProfile: { _, retiredSessionIDs in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                if let active = appState.activeConversationID, retiredSessionIDs.contains(active) {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                    appState.resetForHostBoundary()
                }
            },
            reconciledProfile: { _ in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                guard await runtime.refreshLocalCache() else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
            },
            reconciledClosedRuntime: { visibleID, _ in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                if appState.activeConversationID == visibleID {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                    appState.openSessions()
                }
            })
        try await coordinator.deleteAgent(profileID: profileID)
    }

    func openLifecycleDestination(_ destination: WorkspaceDestination) {
        guard let connections = workspaceConnections, let owner = currentWorkspaceOwner,
              connections.owner == owner, let runtime = nativeRuntime else {
            actionErrorMessage = "Connect to a native Hermes host before managing sessions or profiles."
            return
        }
        let presentationID = UUID()
        do {
            let coordinator = try NativeWorkspaceLifecycleCoordinator(
                owner: owner, connections: connections, catalog: sessionCatalog, agents: agents, bridge: runtime.bridge,
                adoptedSession: { summary in
                    guard currentWorkspaceOwner == owner, lifecyclePresentationID == presentationID else {
                        throw CancellationError()
                    }
                    openSession(summary)
                },
                retiredProfile: { _, retiredSessionIDs in
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    if let active = appState.activeConversationID, retiredSessionIDs.contains(active) {
                        sessionRestoreTask?.cancel()
                        sessionRestoreTask = nil
                        sessionRestoreRequest = nil
                        appState.resetForHostBoundary()
                    }
                },
                reconciledProfile: { result in
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    guard await runtime.refreshLocalCache() else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    if lifecyclePresentationID == presentationID {
                        switch result.change {
                        case .renamed, .deleted: appState.openSessions()
                        default: break
                        }
                    }
                },
                reconciledClosedRuntime: { visibleID, _ in
                    guard currentWorkspaceOwner == owner, lifecyclePresentationID == presentationID else {
                        throw WorkspaceClientError.ownerChanged
                    }
                    if appState.activeConversationID == visibleID {
                        sessionRestoreTask?.cancel()
                        sessionRestoreTask = nil
                        sessionRestoreRequest = nil
                        appState.openSessions()
                    }
                })
            managementStore?.retire()
            managementStore = nil
            administrationPresentation?.retire()
            administrationPresentation = nil
            lifecycleCoordinator = coordinator
            lifecycleProfileID = workspaceAgentID
            lifecyclePresentationID = presentationID
            appState.open(.workspaceManagement(destination))
        } catch {
            actionErrorMessage = "The session and profile controls could not connect to this host."
        }
    }

    func handleAgentWorkspaceAction(_ request: AgentWorkspaceActionRequest) {
        guard currentWorkspaceOwner == request.owner else {
            actionErrorMessage = WorkspaceClientError.ownerChanged.localizedDescription
            return
        }
        switch request.action {
        case .openAgentSessions(let id):
            openSessions(filteredTo: id)
        case .openAgentGroups(let id):
            agentGroupFilterRequest = id
            appState.select(.agents)
        case .openAgentScheduledTasks(let id):
            openScheduledTasks(filteredTo: id)
        case .openHostStatus:
            isHostStatusPresented = true
        case .openAgentChat(let id):
            agents.select(id)
            startNewChat(explicitAgentID: id)
        case .openGroup(let id):
            openHostedGroup(id, owner: request.owner, settings: false)
        case .openGroupSettings(let id):
            openHostedGroup(id, owner: request.owner, settings: true)
        case .renameGroup(let id, let name):
            Task { @MainActor in
                guard currentWorkspaceOwner == request.owner else { return }
                do {
                    _ = try await botModeRooms.openNativeRoom(roomID: id)
                    guard currentWorkspaceOwner == request.owner else { return }
                    try await botModeRooms.renameNativeRoom(roomID: id, name: name)
                } catch {
                    guard currentWorkspaceOwner == request.owner else { return }
                    actionErrorMessage = "The group could not be renamed. Check the host and try again."
                }
            }
        case .deleteGroup(let id):
            Task { @MainActor in
                guard currentWorkspaceOwner == request.owner else { return }
                do {
                    try await botModeRooms.deleteNativeRoom(roomID: id)
                    guard currentWorkspaceOwner == request.owner else { return }
                    sessionCatalog.removeConfirmedHostedGroup(roomID: id)
                }
                catch {
                    guard currentWorkspaceOwner == request.owner else { return }
                    actionErrorMessage = "The group deletion was not confirmed. Refresh before trying again."
                }
            }
        case .createGroup(let seed):
            guard botModeRooms.canCreateNativeRoom else {
                actionErrorMessage = WorkspaceUnavailableReason.driverUnavailable.message
                return
            }
            groupCreationSeed = seed
            groupCreationOwner = request.owner
            isGroupCreationPresented = true
        }
    }

    func openHostedGroup(_ id: String, owner: WorkspaceOwner, settings: Bool) {
        Task { @MainActor in
            guard currentWorkspaceOwner == owner else { return }
            do {
                let room = try await botModeRooms.openNativeRoom(roomID: id)
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                let record = try sessionCatalog.installWorkspaceRecord(
                    SessionRecord(id: "hermes-room:\(room.id)", kind: .botMode, agentIDs: room.profileIDs,
                                  title: room.title, remoteSource: "hermes-room", botModeRoomID: room.id),
                    ownerIsCurrent: { currentWorkspaceOwner == owner }
                )
                let route = AppRoute.chat(conversationID: record.id)
                guard featureStore.prepare(route),
                      case .chat(let model)? = featureStore.preparedModel(for: route) else {
                    throw WorkspaceClientError.unavailable(.unsupportedOperation)
                }
                if settings { groupSettingsModel = model }
                else { appState.activateConversation(id: record.id, source: .sessions) }
            } catch {
                guard currentWorkspaceOwner == owner else { return }
                actionErrorMessage = "Hermes could not open this group. Check the host and try again."
            }
        }
    }

}
