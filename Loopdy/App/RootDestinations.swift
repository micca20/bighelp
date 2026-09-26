import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    @ViewBuilder
    func routeDestination(_ route: AppRoute) -> some View {
        if nativeWorkspaceStore != nil, nativeRuntime == nil, !isAccountDeviceRoute(route) {
            ContentUnavailableView("Not available on this host", systemImage: "server.rack",
                description: Text("This capability is not connected through the selected native host. No request was forwarded through Link."))
        } else {
        switch (route, featureStore.preparedModel(for: route)) {
        case (.workspaceActivity, _):
            routeWithWorkspaceMenu { workspaceActivity }
        case (.workspaceSettings, _):
            routeWithWorkspaceMenu { workspaceSettings() }
        case (.workspaceHub, _):
            routeWithWorkspaceMenu {
                WorkspaceHubView(
                    hostName: workspaceHostName,
                    profileName: workspaceProfileName,
                    onOpen: openWorkspaceDestination
                )
            }
        case (.workspaceConnections, _):
            routeWithWorkspaceMenu {
                if let hostRegistry {
                    Form { LoopdyConfiguredHostsSection(registry: hostRegistry) }
                        .navigationTitle("Instances")
                        .accessibilityIdentifier("workspace.connections")
                } else {
                    WorkspaceUnavailableView(destination: .instances, hostName: workspaceHostName,
                                             reason: "Host selection is unavailable in this presentation.")
                }
            }
        case (.workspaceManagement(let destination), _):
            routeWithWorkspaceMenu {
                if destination == .tasks {
                    let owner = currentWorkspaceOwner
                    WorkspaceSessionContentView(destination: destination, catalog: sessionCatalog,
                        profileID: workspaceAgentID, isCurrent: { currentWorkspaceOwner == owner }, onOpenChat: openSession)
                } else if destination == .artifacts {
                    if let owner = currentWorkspaceOwner, let performer = workspaceConnections?.workspace,
                       let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient {
                        ConfiguredWorkspaceArtifactsView(
                            hostName: workspaceHostName,
                            owner: owner,
                            http: direct,
                            performer: performer,
                            currentOwner: { workspaceConnections?.workspace === performer ? currentWorkspaceOwner : nil }
                        )
                        .id(owner)
                    } else {
                        WorkspaceUnavailableView(
                            destination: .artifacts,
                            hostName: workspaceHostName,
                            reason: "Artifacts require an available direct native Hermes connection."
                        )
                    }
                } else if destination == .logs {
                    if let connections = workspaceConnections, let owner = currentWorkspaceOwner,
                       connections.owner == owner, let workspace = connections.workspace,
                       workspace.owner == owner, let direct = connections.hosts.selectedWorkspace?.nativeClient {
                        HermesLogsDestinationView(hostName: workspaceHostName, owner: owner,
                            http: direct, workspace: workspace, currentOwner: {
                                guard connections.workspace === workspace else { return nil }
                                return currentWorkspaceOwner
                            })
                            .id(owner)
                    } else {
                        WorkspaceUnavailableView(destination: .logs, hostName: workspaceHostName,
                            reason: "Logs require an available direct authenticated Hermes connection.")
                    }
                } else if [.security, .appearance, .tabBar, .caching, .contact, .watch].contains(destination) {
                    workspaceSettings(destination: destination)
                } else if destination == .documentation {
                    WorkspaceDocumentationView()
                } else if destination == .voice {
                    VoiceSettingsView(settings: settings, agents: agents.profiles,
                                      selectedAgentID: workspaceAgentID,
                                      client: voiceSettingsClient, scope: voiceSettingsScope,
                                      isCurrent: voiceSettingsIsCurrent)
                } else if destination == .permissions {
                    PermissionsSettingsView(center: permissionCenter)
                } else if destination == .sessionMaintenance || destination == .profileLifecycle {
                    if let coordinator = lifecycleCoordinator,
                       coordinator.owner == currentWorkspaceOwner, let profileID = lifecycleProfileID,
                       profileID == workspaceAgentID {
                        if destination == .sessionMaintenance {
                            coordinator.sessionMaintenanceView(profileID: profileID)
                        } else {
                            coordinator.profileLifecycleView(selectedProfileID: profileID)
                        }
                    } else {
                        WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                            reason: "Reopen this feature for the selected host and profile.")
                    }
                } else if let kind = CapabilitiesManagementKind(destination: destination), !usesWorkspaceFixtures {
                    nativeCapabilitiesDestination(kind, destination: destination)
                } else if NativeAdministrationPresentation.supports(destination), !usesWorkspaceFixtures {
                    if let presentation = administrationPresentation,
                       presentation.destination == destination,
                       presentation.owner == currentWorkspaceOwner, presentation.profileID == workspaceAgentID {
                        NativeAdministrationDestination(presentation: presentation,
                            permissionCenter: permissionCenter,
                            onOpenProviderAccounts: { openWorkspaceDestination(.keys) },
                            onOpenAgentDefaults: { openWorkspaceDestination(.profiles) })
                    } else {
                        WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                            reason: "Reopen this feature after connecting to the selected host and profile.")
                    }
                } else if let managementStore {
                    WorkspaceManagementView(store: managementStore, destination: destination,
                                            onOpenExisting: openWorkspaceDestination)
                } else {
                    WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                                             reason: "This feature requires an available native host connection.")
                }
            }
        case (.chat(let conversationID), .chat(let model)?):
            ChatDestinationView(
                model: model,
                appState: appState,
                linkDevices: linkDevices,
                settings: settings,
                featureStore: featureStore,
                catalog: sessionCatalog,
                agents: agents,
                agentEditorPresentation: chatAgentEditorPresentation(for: model),
                botModeRooms: botModeRooms,
                skillsAndTools: skillsAndTools,
                hermesWorkspaces: hermesWorkspaces,
                projectGitClient: projectGitClient,
                userIdentity: userIdentity,
                permissionCenter: permissionCenter,
                selectedTab: appState.drawerSelectedTab,
                sessionOrganizationAccountID: sessionOrganizationAccountID,
                sessionOrganizationHostID: sessionOrganizationHostID,
                responseHapticsCoveredByRoot: isQuickWorkspacePresented
                    || isHostStatusPresented
                    || isHermesWorkspacePresented || isLinkAccountPresented
                    || pairingSheetRequest != nil || actionErrorMessage != nil,
                onNewChat: { startNewChat(explicitAgentID: nil) },
                onStartSession: {
                    startNewChat(explicitAgentID: model.memberIDs.first)
                },
                onOpenSessions: { openSessions(filteredTo: nil) },
                onOpenSession: openSession,
                onSelectTab: { appState.select($0) },
                onOpenScheduledTasks: {
                    openScheduledTasks(filteredTo: agents.resolvedAgent(explicitID: nil)?.id)
                },
                onSelectAgent: { agent in
                    agents.select(agent.id)
                    startNewChat(explicitAgentID: agent.id)
                },
                onOpenAgentSessions: { openSessions(filteredTo: $0) },
                onOpenApproval: {
                    openApproval(request: $0)
                },
                onForkMessage: { itemID in
                    forkSession(sourceID: conversationID, throughItemID: itemID)
                },
                appearanceAuthority: currentWorkspaceOwner?.authority
            )
            .environment(\.chatCardInteractions, cardInteractions(for: model))
            .environment(\.agentHomeChrome, homeChrome(for: route))
            .environment(connectionKeeper)
        case (.scheduledTasks, .scheduledTasks(let store)?):
            routeWithWorkspaceMenu {
                ScheduledTasksView(store: store, agents: agents, onOpen: openScheduledTask)
            }
        case (.scheduledTask(let id, let agentID), .scheduledTasks(let store)?):
            routeWithWorkspaceMenu {
                ScheduledTaskDetailView(store: store, taskID: id, agents: agents, agentID: agentID)
            }
        case (.skillsAndTools, _):
            routeWithWorkspaceMenu {
                SkillsAndToolsCatalogView(
                    store: skillsAndTools,
                    agentID: agents.resolvedAgent(explicitID: nil)?.id ?? "default"
                )
            }
        case (.approval, .approval(let model)?):
            routeWithWorkspaceMenu {
                ApprovalDestinationView(model: model)
            }
        case (.loopdyLinkDevices, _):
            routeWithWorkspaceMenu {
                LoopdyLinkDevicesView(
                    store: linkDevices,
                    onOpenDevice: { device in
                        appState.open(.loopdyLinkDevice(id: device.id))
                    },
                    onPairDevice: presentPairing
                )
            }
        case (.loopdyLinkDevice(let id), _):
            routeWithWorkspaceMenu {
                LoopdyLinkDeviceDetailView(
                    store: linkDevices,
                    deviceID: id,
                    onUnpaired: { closeLinkDevice(id: id) }
                )
            }
        default:
            ContentUnavailableView(
                "Route unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This route could not be prepared. Try again.")
            )
        }
        }
    }

}
