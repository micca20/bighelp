import SwiftUI
import UIKit

@MainActor
struct RootShellView: View {
    #if DEBUG
    @State var voiceSettingsPreview = VoiceSettingsPreviewClient()
    #endif

    @AppStorage("loopdy.onboarding.first-run-v1.completed")
    private var hasCompletedFirstRunOnboarding = false
    @State private var didCompleteForcedFirstRunOnboarding = false
    let appState: AppState
    let settings: SettingsStore
    let featureStore: ShellFeatureStore
    let sessionCatalog: SessionCatalogStore
    let agents: AgentDirectoryStore
    let agentRuntimeDefaults: any AgentRuntimeDefaultsClient
    let botModeRooms: BotModeRoomStore
    let linkAccount: BighelpLinkAccountStore
    let linkDevices: BighelpLinkDeviceStore
    let permissionCenter: PermissionCenter
    let permissionsOnboarding: PermissionsOnboardingModel
    let personalities: PersonalityStore
    let skillsAndTools: SkillsAndToolsStore
    let hermesWorkspaces: HermesWorkspaceStore
    let projectGitClient: any ProjectGitClient
    let userIdentity: UserIdentityStore
    let newChatCoordinator: NewChatCoordinator
    let requiresLinkAccount: Bool
    let clearLocalCache: @MainActor () async -> Bool
    var nativeRuntime: NativeWorkspaceRuntime? = nil
    var nativeWorkspaceError: String? = nil
    var agentIsland: AgentIslandModel? = nil

    @Environment(\.bighelpHostRegistry) var hostRegistry
    @Environment(\.managedNotificationService) private var managedNotifications
    @State var actionErrorMessage: String?
    @State var isHostStatusPresented = false
    @State private var actionErrorShowsHostStatus = false
    @State var hostRuntime: HostRuntimeStore?
    @State var pairingSheetRequest: BighelpLinkPairingSheetRequest?
    @State private var guidedPairingReference: BighelpLinkPairingReference?
    @State private var pendingIncomingChatSessionID: String?
    @State var isLinkAccountPresented = false
    @State var isHermesWorkspacePresented = false
    @State var sessionRestoreRequest: SessionRestoreRequest?
    @State var sessionRestoreTask: Task<Void, Never>?
    @State var managementStore: WorkspaceManagementStore?
    @State var capabilitiesPresentation: NativeCapabilitiesPresentation?
    @State var administrationPresentation: NativeAdministrationPresentation?
    @State var lifecycleCoordinator: NativeWorkspaceLifecycleCoordinator?
    @State var lifecycleProfileID: String?
    @State var lifecyclePresentationID: UUID?
    @State var workspaceProfileEditor: AgentEditorModel?
    @State var isGroupCreationPresented = false
    @State var groupCreationSeed: String?
    @State var groupCreationOwner: WorkspaceOwner?
    /// The chat header's New chat: one agent starts a 1:1 chat, several a group.
    @State var newChatPicker: NewChatPickerRequest?
    @State var groupSettingsModel: ChatModel?
    @State private var isStartingNewChat = false
    @State private var newChatStartID: UUID?
    @State private var fixtureCanonicalSessions: [String: String] = [:]
    @State var workspaceFixtureGeneration = UUID()
    @State private var cardInteractionStore = BighelpCardInteractionStore()
    @Environment(\.workspaceConnections) var workspaceConnections
    @Environment(\.scenePhase) var scenePhase
    @State var connectionKeeper = WorkspaceConnectionKeeper()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State var isUnifiedSettingsPresented = false
    @State private var isKeyboardVisible = false
    @State private var rootBottomSafeArea: CGFloat = 0
    @State private var afterSettingsDismiss: (() -> Void)?
    // Agent home (Muse-style): board data, the profile, the switcher and the ☰ drawer.
    @State var agentBoard = AgentBoardStore()
    @State var agentMedia = AgentMediaStore()
    @State var profileAgentID: String?
    @State var isAgentSwitcherPresented = false
    @State var isHomeDrawerPresented = false
    @State var didAutoOpenHomeChat = false
    /// Runs after a home sheet closes, so the next sheet can open.
    @State var afterHomeSheet: (@MainActor () -> Void)?

    var usesWorkspaceFixtures: Bool {
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures")
            || ProcessInfo.processInfo.arguments.contains("-disable-demo-delays")
    }

    func chatAgentEditorPresentation(for model: ChatModel) -> ChatAgentEditorPresentation? {
        guard !model.isBotMode, let owner = currentWorkspaceOwner,
              let profileID = model.memberIDs.first,
              agents.profiles.contains(where: { $0.id == profileID }) else { return nil }
        let capabilities = currentWorkspaceCapabilities
        guard capabilities.supports(.profilesEdit, owner: owner, profileID: profileID) else { return nil }
        let canReadDefaults = capabilities.supports(.modelsRead, owner: owner, profileID: profileID)
        let canEditDefaults = capabilities.supports(.agentDefaultsEdit, owner: owner, profileID: profileID)
        let unavailable: WorkspaceCapability? = canReadDefaults
            ? (canEditDefaults ? nil : .agentDefaultsEdit) : .modelsRead
        let readOnlyReason = unavailable.flatMap {
            AgentActionsPresentation.unavailableMessage(capabilities.availability(for: $0, owner: owner, profileID: profileID))
                ?? WorkspaceUnavailableReason.unsupportedOperation.message
        }
        return ChatAgentEditorPresentation(profileID: profileID, store: agents,
            runtimeDefaultsClient: canReadDefaults ? agentRuntimeDefaults : nil,
            runtimeDefaultsReadOnlyReason: readOnlyReason,
            isCurrent: {
                currentWorkspaceOwner == owner && model.memberIDs.first == profileID
                    && agents.profiles.contains(where: { $0.id == profileID })
                    && currentWorkspaceCapabilities.supports(.profilesEdit, owner: owner, profileID: profileID)
            })
    }

    func cardInteractions(for model: ChatModel) -> ChatCardInteractionHandler? {
        guard let owner = currentWorkspaceOwner, let profile = model.memberIDs.first else { return nil }
        let scope = ChatCardInteractionScope(authorityID: owner.cacheScopeID,
                                             profileID: profile, conversationID: model.conversationID)
        return ChatCardInteractionHandler(
            scope: scope, store: cardInteractionStore,
            currentDraft: { model.draft },
            stageComposer: { text, strategy in
                switch strategy {
                case .replace: model.draft = text
                case .append:
                    model.draft += model.draft.isEmpty || model.draft.hasSuffix("\n") ? text : "\n" + text
                }
            },
            scheduledTasks: model.isBotMode ? nil : featureStore.scheduledTasks.map { ChatCardScheduledTaskBackend(store: $0) },
            currentScope: {
                guard currentWorkspaceOwner == owner,
                      model.memberIDs.first == profile else { return nil }
                return scope
            }
        )
    }

    var body: some View {
        let readiness = readinessPresentation
        let readinessDriveTrigger = BighelpReadinessDriveTrigger(
            readiness: readiness.state,
            link: readiness.linkState
        )
        agentHomeSheets(rootContent)
        .bighelpThemePresentation(theme)
        .onChange(of: hostRegistry?.hosts.isEmpty, initial: true) { _, _ in
            reconcileRestoredHostOnboardingState()
        }
        .onChange(of: hostRegistry?.onboardingHostID) { _, _ in
            reconcileRestoredHostOnboardingState()
        }
        .onChange(of: currentWorkspaceOwner) { _, _ in
            managementStore?.retire()
            managementStore = nil
            capabilitiesPresentation = nil
            administrationPresentation?.retire()
            administrationPresentation = nil
            workspaceProfileEditor = nil
            lifecycleCoordinator = nil
            lifecycleProfileID = nil
            lifecyclePresentationID = nil
            isGroupCreationPresented = false
            groupSettingsModel = nil
            fixtureCanonicalSessions = [:]
        }
        .sheet(item: $workspaceProfileEditor) { editor in
            AgentEditorView(model: editor, runtimeDefaultsClient: agentRuntimeDefaults, onCompleted: { _ in })
        }
        .sheet(isPresented: $isGroupCreationPresented) {
            BotModeCreateRoomView(rooms: botModeRooms, agents: agents, seedProfileID: groupCreationSeed) { roomID in
                guard let owner = groupCreationOwner, owner == currentWorkspaceOwner else { return }
                openHostedGroup(roomID, owner: owner, settings: false)
            }
        }
        .sheet(isPresented: Binding(
            get: { groupSettingsModel != nil }, set: { if !$0 { groupSettingsModel = nil } }
        )) {
            if let model = groupSettingsModel { PeopleAndChatView(model: model, agents: agents) }
        }
        .sheet(isPresented: Binding(get: { hostRegistry?.isSetupPresented == true },
                                   set: { if !$0 { hostRegistry?.finishSetup() } })) {
            if let hostRegistry {
                NavigationStack {
                    HostSetupView(registry: hostRegistry, hostToAuthenticate: hostRegistry.hosts.first { $0.id == hostRegistry.setupHostID })
                }
            }
        }
        .onChange(of: hostRegistry?.selectedHostID) { _, _ in
            appState.resetForHostBoundary()
        }
        .task(id: hostRegistry?.selectedHostID) {
            connectionKeeper.bind { [hostRegistry] in
                hostRegistry?.isWorkspaceReady == true ? hostRegistry?.selectedWorkspace : nil
            }
            guard scenePhase == .active else { return }
            await nativeWorkspaceStore?.reconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            connectionKeeper.setActive(phase == .active)
            if phase == .background, BighelpShortcutService.holdsHostConnection == 0 {
                nativeWorkspaceStore?.suspendForPresentationExit()
            }
            if phase == .active {
                Task { @MainActor in
                    guard scenePhase == .active else { return }
                    await nativeWorkspaceStore?.reconnect()
                }
            }
        }
        .overlay {
            if let workspace = nativeWorkspaceStore {
                DirectHermesSecurePromptOverlay(workspace: workspace)
            }
        }
        .onChange(of: currentDeviceToolScope, initial: true) { _, scope in
            permissionCenter.deviceTools.bind(scope)
        }
        .onChange(of: nativeDeviceToolTrigger, initial: true) { _, signature in
            permissionCenter.nativeDeviceToolLifetime.update(signature) {
                await runNativeDeviceTools()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            permissionCenter.nativeDeviceToolLifetime.stop()
            permissionCenter.deviceTools.invalidateOperations()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            // Protected-data availability is not observable SwiftUI state.
            // Resume explicitly even when scenePhase stayed active.
            permissionCenter.nativeDeviceToolLifetime.update(nativeDeviceToolTrigger) {
                await runNativeDeviceTools()
            }
        }
        .onChange(of: currentDeviceToolScope) { _, _ in
            sessionRestoreTask?.cancel()
            sessionRestoreTask = nil
            sessionRestoreRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { permissionCenter.deviceTools.invalidateOperations() }
        }
        .task(id: readinessDriveTrigger) {
            await permissionsOnboarding.prepare(readiness: readiness.state)
        }
        .onChange(of: linkDevices.pairingState) { _, state in
            guard case .paired = state else { return }
            guidedPairingReference = nil
        }
        .onChange(of: readiness.state) { _, state in
            if state == .ready { openPendingIncomingChatIfNeeded() }
        }
        .onChange(of: linkAccount.state) { _, state in
            guard BighelpAccountWorkspaceBoundary.shouldClear(
                account: state,
                hasCredentials: linkAccount.credentials != nil,
                needsLocalCleanup: linkAccount.needsLocalCleanup
            ) else { return }
            isLinkAccountPresented = false
            pairingSheetRequest = nil
            guidedPairingReference = nil
        }
        .sheet(isPresented: Binding(
            get: {
                nativeWorkspaceStore == nil && !needsInitialHostSetup && permissionsOnboarding.isPrepared
                    && permissionsOnboarding.shouldPresent(readiness: readiness.state)
            },
            set: { if !$0 { permissionsOnboarding.notNow() } }
        )) {
            PermissionsOnboardingView(model: permissionsOnboarding)
        }
        .task(id: hostRuntimeScope) { await prepareHostRuntime() }
        .onChange(of: agents.errorMessage) { _, _ in
            Task { await currentHostRuntime?.refresh() }
        }
        .onOpenURL(perform: handleIncomingURL)
        .onChange(of: acceptsIncomingLinks) { _, ready in
            if ready { openPendingIncomingChatIfNeeded() }
        }
        .onChange(of: BighelpExternalSessionOpenCenter.shared.pending, initial: true) { _, open in
            if let open { openExternalSession(open) }
        }
    }

    var nativeWorkspaceStore: DirectHermesWorkspaceStore? {
        guard hostRegistry?.isWorkspaceReady == true else { return nil }
        return hostRegistry?.selectedWorkspace
    }

    var hasConfiguredLinkHost: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return false }
        #endif
        return linkDevices.selectedHostID != nil || linkDevices.primaryHostID != nil
            || linkDevices.devices.contains { $0.kind == .hermesHost }
    }

    @ViewBuilder private var rootContent: some View {
        Group {
            if let registry = hostRegistry, registry.isWorkspaceReady, !registry.storageIsReadable {
                ContentUnavailableView {
                    Label("Saved hosts unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(registry.errorMessage ?? "Saved hosts could not be loaded.")
                } actions: {
                    Button("Try Again") { registry.retryLoading() }
                }
            } else if let registry = hostRegistry, presentsFirstRunOnboarding {
                FirstRunOnboardingView(
                    registry: registry,
                    settings: settings,
                    onCompleted: completeFirstRunOnboarding
                )
            } else if let registry = hostRegistry, registry.isWorkspaceReady,
                      (needsInitialHostSetup || (registry.onboardingHostID != nil && !registry.isSetupPresented)) {
                HostSetupView(registry: registry, allowsDismiss: false)
            } else if nativeWorkspaceStore != nil {
                if nativeRuntime != nil { workspace }
                else { nativeWorkspace }
            } else if let registry = hostRegistry, registry.connectionMode == .independent, !usesWorkspaceFixtures {
                Form {
                    BighelpConfiguredHostsSection(registry: registry)
                }
                .navigationTitle("Instances")
            } else if usesWorkspaceFixtures {
                workspace
            } else {
                nativeWorkspace
            }
        }
    }

    private var presentsFirstRunOnboarding: Bool {
        guard let hostRegistry,
              hostRegistry.isWorkspaceReady,
              hostRegistry.storageIsReadable,
              hostRegistry.errorMessage == nil else { return false }
        #if DEBUG
        if isForcedFirstRunOnboarding { return !didCompleteForcedFirstRunOnboarding }
        if usesWorkspaceFixtures || ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return false }
        #endif
        guard !hasCompletedFirstRunOnboarding else { return false }
        return hostRegistry.hosts.isEmpty || hostRegistry.onboardingHostID != nil
    }

    #if DEBUG
    private var isForcedFirstRunOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-force-signed-out-onboarding")
    }
    #endif

    private func completeFirstRunOnboarding() {
        didCompleteForcedFirstRunOnboarding = true
        #if DEBUG
        guard !isForcedFirstRunOnboarding else { return }
        #endif
        hasCompletedFirstRunOnboarding = true
    }

    private func reconcileRestoredHostOnboardingState() {
        #if DEBUG
        guard !isForcedFirstRunOnboarding else { return }
        #endif
        guard let hostRegistry,
              hostRegistry.isWorkspaceReady,
              !hostRegistry.hosts.isEmpty,
              hostRegistry.onboardingHostID == nil else { return }
        hasCompletedFirstRunOnboarding = true
    }

    private var needsInitialHostSetup: Bool {
        guard let hostRegistry, hostRegistry.isWorkspaceReady, hostRegistry.errorMessage == nil else { return false }
        #if DEBUG
        if !requiresLinkAccount && !ProcessInfo.processInfo.arguments.contains("-test-no-configured-hosts") { return false }
        #endif
        return hostRegistry.hosts.isEmpty
            && (hostRegistry.connectionMode == .independent || !hasConfiguredLinkHost)
    }

    @ViewBuilder
    private var nativeWorkspace: some View {
        ContentUnavailableView {
            Label("Hermes workspace", systemImage: "network")
        } description: {
            Text(nativeWorkspaceError ?? nativeRuntime?.errorMessage
                 ?? nativeWorkspaceStore?.status ?? "Connecting to this host.")
        } actions: {
            if nativeRuntime?.isRefreshing == true || nativeWorkspaceStore?.isConnecting == true {
                ProgressView()
            } else {
                Button("Reconnect") {
                    Task {
                        await nativeWorkspaceStore?.reconnect()
                        await nativeRuntime?.refresh()
                    }
                }
                if let hostRegistry {
                    NavigationLink("Instances") {
                        Form { BighelpConfiguredHostsSection(registry: hostRegistry) }
                            .navigationTitle("Instances")
                    }
                }
            }
        }
        .accessibilityIdentifier("native-workspace.connecting")
    }

    var workspace: some View {
        homeAutoOpen(workspaceShell)
    }

    private var workspaceShell: some View {
        GeometryReader { geometry in
            shell
                .overlay(alignment: .leading) {
                    edgeGestureSurface(side: .left, containerWidth: geometry.size.width)
                }
                .overlay(alignment: .trailing) {
                    edgeGestureSurface(side: .right, containerWidth: geometry.size.width)
                }
                .allowsHitTesting(!isBlockingSessionRestore)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(isBlockingSessionRestore)
                .overlay {
                    if isBlockingSessionRestore, let request = sessionRestoreRequest {
                        sessionRestoreOverlay(request)
                    }
                }
        }
    }

    private var isBlockingSessionRestore: Bool {
        guard let request = sessionRestoreRequest else { return false }
        return appState.activeConversationID != request.sessionID
    }

    private func sessionRestoreOverlay(_: SessionRestoreRequest) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
            BighelpCard {
                VStack(spacing: BighelpTokens.space12) {
                    BighelpThinkingOrb(scenario: .shaping)
                    Text("Restoring session")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                    Text("Loading the transcript and rebuilding saved interface cards…")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 300)
                .padding(BighelpTokens.space12)
            }
            .padding(BighelpTokens.space24)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Restoring session")
        .accessibilityIdentifier("session.restore.loading")
    }

    @ViewBuilder
    private var hostAwareHomeTab: some View {
        workspaceActivity
    }

    @ViewBuilder
    private var hostAwareAgentsTab: some View {
            AgentsShellView(
                agents: agents,
                runtimeDefaultsClient: agentRuntimeDefaults,
                onSelect: { agent in
                    agents.select(agent.id)
                    startNewChat(explicitAgentID: agent.id)
                },
                onOpenSessions: { openSessions(filteredTo: $0.id) },
                onOpenHostStatus: { isHostStatusPresented = true },
                hostRuntime: currentHostRuntime,
                workspaceOwner: currentWorkspaceOwner,
                capabilities: currentWorkspaceCapabilities,
                botModeRooms: botModeRooms,
                cloneClient: workspaceConnections?.cloneClient,
                templateClient: workspaceConnections?.templateClient,
                shortcutsAvailable: usesWorkspaceFixtures
                    || (nativeRuntime != nil && currentWorkspaceOwner != nil)
,
                onAction: handleAgentWorkspaceAction
            )
    }

    /// Feed, Ideas, Goals and Apps draw their own header (the agent's avatar).
    private var showsAgentBoard: Bool {
        appState.path.isEmpty && appState.selectedTab.isAgentBoard
    }

    private var shell: some View {
        rootLayout
        .toolbar(.hidden, for: .tabBar)
        .toolbar(showsAgentBoard ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(showsAgentBoard ? "" : rootNavigationTitle)
        .navigationBarTitleDisplayMode(showsAgentBoard ? .inline : .large)
        .toolbar {
            if appState.path.isEmpty, !appState.selectedTab.isAgentBoard {
                if !usesPersistentSidebar {
                    // ☰ always opens chats, agents, tasks and settings.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isHomeDrawerPresented = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("Chats and menu")
                        .accessibilityIdentifier("home.drawer.open")
                    }
                }
                // Ember lives only in chrome: the brand bar on root screens.
                // Touch and hold it to switch hosts.
                EmberBrandToolbarItem(linkDevices: linkDevices)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // iPhone gets the familiar bottom tab bar; iPad keeps its sidebar.
            if showsBottomNavigation {
                FloatingTabBar(selection: tabSelection,
                               onNewChat: appState.selectedTab == .sessions ? {
                                   appState.chatOpenedFromList = true
                                   startNewChat(explicitAgentID: nil)
                               } : nil,
                               homeIndicatorSink: FloatingTabBar.homeIndicatorSink(forBottomInset: rootBottomSafeArea))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { rootBottomSafeArea = $0 }
        .overlay(alignment: .bottomTrailing) {
            if appState.path.isEmpty, appState.selectedTab == .sessions, usesPersistentSidebar {
                RootComposeButton(identifier: "root.new-chat.floating") { startNewChat(explicitAgentID: nil) }
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration), value: showsBottomNavigation)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            botModeLoadErrorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationDestination(for: AppRoute.self, destination: routeDestination)
        .alert("Unable to open", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            if actionErrorShowsHostStatus {
                Button("View Host Status") {
                    actionErrorMessage = nil
                    actionErrorShowsHostStatus = false
                    isHostStatusPresented = true
                }
            }
            Button("OK", role: .cancel) {
                actionErrorMessage = nil
                actionErrorShowsHostStatus = false
            }
        } message: {
            Text(actionErrorMessage ?? "Try again.")
        }
        .sheet(isPresented: $isHostStatusPresented) {
            NavigationStack {
                Form {
                    HostRuntimeSection(store: currentHostRuntime,
                                       connectionState: nil,
                                       agents: agents, theme: theme)
                }
                .scrollContentBackground(.hidden)
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle("Host Status")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isHostStatusPresented = false }
                    }
                }
            }
            .accessibilityIdentifier("host-runtime.screen")
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isUnifiedSettingsPresented, onDismiss: {
            let action = afterSettingsDismiss
            afterSettingsDismiss = nil
            action?()
        }) {
            NavigationStack {
                workspaceSettings()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isUnifiedSettingsPresented = false }
                                .accessibilityIdentifier("settings.done")
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pairingSheetRequest) { request in
            NavigationStack {
                BighelpLinkPairingView(
                    store: linkDevices,
                    permissionCenter: permissionCenter,
                    initialReference: request.reference
                )
                .id(request.id)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isLinkAccountPresented) {
            NavigationStack {
                BighelpLinkAccountView(
                    store: linkAccount,
                    onReady: { isLinkAccountPresented = false },
                    deviceStore: hostRegistry?.connectionMode == .independent ? nil : linkDevices,
                    onManageDevices: hostRegistry?.connectionMode == .independent ? nil : {
                        isLinkAccountPresented = false
                        appState.open(.bighelpLinkDevices)
                    },
                    onOpenDevice: hostRegistry?.connectionMode == .independent ? nil : { device in
                        isLinkAccountPresented = false
                        appState.open(.bighelpLinkDevice(id: device.id))
                    }
                )
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isHermesWorkspacePresented) {
            HermesWorkspacePickerView(
                store: hermesWorkspaces,
                agentID: workspaceAgentID
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: appState.path) { previousPath, path in
            let bindsPendingCanvas: Bool = {
                guard case .chat(let previousID)? = previousPath.last,
                      case .chat(let currentID)? = path.last else { return false }
                return previousID.hasPrefix("local-draft:") && !currentID.hasPrefix("local-draft:")
            }()
            if !bindsPendingCanvas { BighelpKeyboard.dismiss() }
            if let restoreRequest = sessionRestoreRequest {
                let route = AppRoute.chat(conversationID: restoreRequest.sessionID)
                // Leaving ends presentation observation, not native feature-
                // owned hydration, even when returning to the original root.
                let leftHydratingChat = SessionRestorePresentationPolicy.ownsHydration(
                    route: route, path: previousPath
                ) && !SessionRestorePresentationPolicy.ownsHydration(route: route, path: path)
                let leftRestore = !SessionRestorePresentationPolicy.ownsRestore(
                    route: route,
                    originTab: restoreRequest.originTab,
                    originPath: restoreRequest.originPath,
                    currentTab: appState.selectedTab,
                    currentPath: path
                )
                if leftHydratingChat || leftRestore {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                }
            }
        }
        .onChange(of: appState.selectedTab) { _, tab in
            guard let restoreRequest = sessionRestoreRequest,
                  tab != restoreRequest.originTab
            else { return }
            sessionRestoreTask?.cancel()
            sessionRestoreTask = nil
            sessionRestoreRequest = nil
        }
    }

    var usesPersistentSidebar: Bool {
        ConversationRootNavigationPresentation.usesPersistentSidebar(
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular
        )
    }

    private var showsBottomNavigation: Bool {
        appState.path.isEmpty && !usesPersistentSidebar && !isKeyboardVisible
    }

    @ViewBuilder
    private var rootLayout: some View {
        if ConversationRootNavigationPresentation.usesPersistentSidebar(
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular
        ) {
            HStack(spacing: 0) {
                ConversationRootSidebar(
                    theme: theme,
                    selectedTab: appState.selectedTab,
                    path: appState.path,
                    onOpen: openRootDestination,
                    onNewChat: { startNewChat(explicitAgentID: nil) },
                    showsAdvanced: settings.nerdModeEnabled
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)

                Divider()

                rootTabs
            }
        } else {
            rootTabs
        }
    }

    @ViewBuilder
    private var rootTabs: some View {
        // The conversation shell owns navigation. A hidden TabView creates a
        // UIKit containment boundary that drops feature search and toolbar actions.
        switch appState.selectedTab {
        case .agents:
            hostAwareAgentsTab
        case .scheduledTasks:
            scheduledTasksRootTab
        case .workspace:
            WorkspaceHubView(
                hostName: workspaceHostName,
                profileName: workspaceProfileName,
                onOpen: openWorkspaceDestination
            )
        case .home, .inbox:
            hostAwareHomeTab
        case .profile:
            workspaceSettings()
        case .sessions:
            sessionsRootTab
        case .feed, .ideas, .goals, .apps:
            agentBoardTab(appState.selectedTab)
        }
    }

    private var selectedRootDestination: ConversationRootDestination {
        switch appState.selectedTab {
        case .sessions: .chats
        case .agents: .agents
        case .scheduledTasks: .scheduledTasks
        case .home, .inbox: .activity
        case .workspace: .workspace
        case .profile: .settings
        case .feed: .feed
        case .ideas: .ideas
        case .goals: .goals
        case .apps: .apps
        }
    }

    private var rootNavigationTitle: String {
        selectedRootDestination.title
    }

    private func openRootDestination(_ destination: ConversationRootDestination) {
        switch destination {
        // Match the iPhone tab bar: root destinations show everything, not
        // the last agent filter.
        case .chats:
            openSessions(filteredTo: nil)
        case .agents:
            appState.select(.agents)
        case .scheduledTasks:
            openScheduledTasks(filteredTo: nil)
        case .activity:
            appState.select(.home)
        case .workspace:
            appState.select(.workspace)
        case .directLinks:
            openBighelpLinkDevices()
        case .diagnostics:
            openWorkspaceDestination(.logs)
        case .settings:
            appState.select(.profile)
        case .feed:
            appState.select(.feed)
        case .ideas:
            appState.select(.ideas)
        case .goals:
            appState.select(.goals)
        case .apps:
            appState.select(.apps)
        }
    }

    @ViewBuilder
    private var botModeLoadErrorBanner: some View {
        if nativeWorkspaceStore == nil,
           let banner = BotModeLoadBannerState(message: botModeRooms.loadErrorMessage) {
            HStack(spacing: BighelpTokens.space8) {
                Label(banner.message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BighelpTokens.space8)
                Button(banner.actionLabel) {
                    do { try botModeRooms.load() } catch { }
                }
                .bighelpFont(.label)
                .foregroundStyle(.white)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .background(.red)
            .accessibilityIdentifier("bot-mode-load-error")
        }
    }

    private enum EdgeSide {
        case left
        case right
    }

    @ViewBuilder
    private func edgeGestureSurface(side: EdgeSide, containerWidth: CGFloat) -> some View {
        let action = side == .left
            ? settings.leftEdgeSwipeAction
            : settings.rightEdgeSwipeAction
        Color.clear
            .frame(width: WorkspaceEdgeSwipeResolver.activationEdgeWidth)
            .contentShape(Rectangle())
            .allowsHitTesting(action != .none && !isHomeDrawerPresented)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        let startX = side == .left
                            ? value.startLocation.x
                            : containerWidth - WorkspaceEdgeSwipeResolver.activationEdgeWidth + value.startLocation.x
                        guard let resolved = WorkspaceEdgeSwipeResolver.resolve(
                            start: CGPoint(x: startX, y: value.startLocation.y),
                            translation: value.translation,
                            containerWidth: containerWidth,
                            leftAction: settings.leftEdgeSwipeAction,
                            rightAction: settings.rightEdgeSwipeAction
                        ) else { return }
                        performWorkspaceAction(resolved)
                    }
            )
            .accessibilityHidden(true)
    }

    /// Every way into the menu (☰, edge swipes, inner pages) opens the same ☰ sheet.
    private func presentQuickWorkspace() {
        BighelpKeyboard.dismiss()
        isHomeDrawerPresented = true
    }

    private func performWorkspaceAction(_ action: WorkspaceSwipeAction) {
        BighelpKeyboard.dismiss()
        switch action {
        case .quickWorkspace:
            presentQuickWorkspace()
        case .newChat:
            startNewChat(explicitAgentID: nil)
        case .sessions:
            openSessions(filteredTo: nil)
        case .agents:
            appState.select(.agents)
        case .home:
            appState.select(.home)
        case .inbox:
            appState.select(.home)
        case .profile:
            appState.select(.profile)
        case .none:
            break
        }
    }

    var tabSelection: Binding<AppTab> {
        Binding(
            get: { appState.selectedTab },
            set: { tab in
                if tab == .sessions, !usesPersistentSidebar, opensHomeChat {
                    // Chat is the agent's own chat; ☰ and swipe-back reach the full list.
                    openHomeChat()
                } else if tab == .sessions {
                    openSessions(filteredTo: nil)
                } else if tab == .scheduledTasks {
                    openScheduledTasks(filteredTo: nil)
                } else {
                    appState.select(tab)
                }
            }
        )
    }

    @ViewBuilder
    private var sessionsRootTab: some View {
        if case .sessions(let model)? = featureStore.preparedModel(for: .sessions) {
            SessionsView(
                model: model,
                agents: agents,
                settings: settings,
                organizeByProjects: settings.organizeChatsByProjects,
                sessionOrganizationAccountID: sessionOrganizationAccountID,
                sessionOrganizationHostID: sessionOrganizationHostID,
                onStartChat: { appState.chatOpenedFromList = true; startNewChat(explicitAgentID: $0) },
                onNewGroupChat: newGroupChatAction.map { action in { appState.chatOpenedFromList = true; action() } },
                onSelect: { appState.chatOpenedFromList = true; openSessionSelection($0) }
            )
        } else {
            ProgressView("Loading sessions")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    _ = featureStore.prepareSessions(filteredTo: nil)
                }
        }
    }

    /// Group chats use Hermes' hosted rooms, the same path as Agents › New group chat.
    var newGroupChatAction: (() -> Void)? {
        guard let owner = currentWorkspaceOwner, botModeRooms.canCreateNativeRoom,
              currentWorkspaceCapabilities.supports(.groupsCreate, owner: owner, profileID: nil)
        else { return nil }
        return {
            handleAgentWorkspaceAction(AgentWorkspaceActionRequest(owner: owner, action: .createGroup(seedProfileID: nil)))
        }
    }

    @ViewBuilder
    private var scheduledTasksRootTab: some View {
        if let store = featureStore.scheduledTasks {
            ScheduledTasksView(store: store, agents: agents, showsInlineHeading: true, onOpen: openScheduledTask)
        } else {
            ContentUnavailableView("Scheduled Tasks", systemImage: "calendar.badge.clock",
                                   description: Text("Scheduled work is unavailable for this connection."))
        }
    }

    private func leaveSettings(perform action: @escaping () -> Void) {
        if isUnifiedSettingsPresented {
            afterSettingsDismiss = action
            isUnifiedSettingsPresented = false
        } else {
            action()
        }
    }

    func workspaceSettings(destination: WorkspaceDestination? = nil) -> some View {
        SettingsView(
            settings: settings, focusedDestination: destination, userIdentity: userIdentity,
            linkAccount: requiresLinkAccount ? linkAccount : nil,
            linkConnectionState: .stopped, linkDevices: linkDevices,
            agents: agents.profiles, personalities: personalities,
            permissionCenter: permissionCenter,
            onOpenSessions: { leaveSettings { openSessions(filteredTo: nil) } },
            onOpenScheduledTasks: { leaveSettings { openScheduledTasks(filteredTo: nil) } },
            onOpenBighelpLinkDevices: { leaveSettings { openBighelpLinkDevices() } },
            onOpenBighelpLinkDevice: { id in leaveSettings { appState.open(.bighelpLinkDevice(id: id)) } },
            onPairBighelpLinkDevice: { leaveSettings { presentPairing() } },
            onOpenBighelpLinkAccount: { leaveSettings { isLinkAccountPresented = true } },
            onClearLocalCache: {
                if let nativeRuntime { return await nativeRuntime.refreshLocalCache() }
                return await clearLocalCache()
            },
            voiceSettingsScope: voiceSettingsScope, voiceSettingsClient: voiceSettingsClient,
            voiceSettingsIsCurrent: voiceSettingsIsCurrent,
            pluginUpdateScope: pluginUpdateScope, pluginUpdateClient: pluginUpdateClient,
            pluginUpdateIsCurrent: pluginUpdateIsCurrent,
            hostRuntime: currentHostRuntime, agentDirectory: agents,
            onOpenWorkspaceDestination: { destination in
                leaveSettings { openWorkspaceDestination(destination) }
            },
            onOpenRoute: { route in
                leaveSettings { openPrepared(route) }
            }
        )
    }

    var workspaceActivity: some View {
        DashboardView(
            model: featureStore.dashboardModel,
            connection: nativeRuntime != nil
                ? DashboardConnectionPresentation(isConnected: currentWorkspaceOwner != nil)
                : DashboardConnectionPresentation(linkState: linkReadinessState),
            permissionCenter: permissionCenter,
            onInboxItemTap: openDashboardInboxItem,
            onAttentionItemTap: openDashboardAttentionItem,
            onWorkItemTap: openDashboardWorkItem
        )
    }

    func isAccountDeviceRoute(_ route: AppRoute) -> Bool {
        switch route {
        case .bighelpLinkDevices, .bighelpLinkDevice: true
        default: false
        }
    }

    func routeWithWorkspaceMenu<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .toolbar {
                if settings.nerdModeEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        // The native toolbar supplies its own Liquid Glass surface.
                        Button {
                            presentQuickWorkspace()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("Menu")
                        .accessibilityIdentifier("workspace.menu")
                    }
                }
            }
    }

    func startNewChat(explicitAgentID: String?) {
        guard !isStartingNewChat else { return }
        let operationID = UUID()
        newChatStartID = operationID
        withAnimation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration)) {
            isStartingNewChat = true
        }
        Task { @MainActor in
            defer {
                finishNewChatOpening(operationID)
            }
            do {
                _ = try await newChatCoordinator.start(explicitAgentID: explicitAgentID)
            } catch is CancellationError {
                // A replaced account or host must not present the old request's error.
            } catch {
                actionErrorShowsHostStatus = agents.errorMessage != nil || AgentDirectoryStore.isHermesCapabilityMissing(error)
                actionErrorMessage = error is WorkspaceClientError ? error.localizedDescription
                    : AgentDirectoryStore.isHermesCapabilityMissing(error)
                    ? AgentDirectoryStore.hermesCompatibilityRecovery
                    : (agents.errorMessage ?? "New chat could not be opened. Try again.")
            }
        }
    }

    private func finishNewChatOpening(_ operationID: UUID) {
        guard newChatStartID == operationID else { return }
        newChatStartID = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration)) {
            isStartingNewChat = false
        }
    }

    var activeHermesWorkspaceName: String {
        hermesWorkspaces.catalog?.workspaces.first(where: \.isActive)?.name
            ?? "Workspace"
    }

    var workspaceAgentID: String {
        agents.resolvedAgent(explicitID: nil)?.id ?? "default"
    }

    func presentHermesWorkspaces() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            isHermesWorkspacePresented = true
        }
    }

    func openApproval(requestID: String) {
        Task {
            do {
                guard try await featureStore.prepareApproval(id: requestID) else {
                    actionErrorMessage = "This approval is no longer available."
                    return
                }
                appState.open(.approval(requestID: requestID))
            } catch {
                actionErrorMessage = "This approval could not be loaded from Hermes. Try again."
            }
        }
    }

    func openApproval(request: ApprovalRequest) {
        guard featureStore.prepareApproval(request: request) else { return }
        appState.open(.approval(requestID: request.id))
    }

    func openSessions(filteredTo agentID: String?) {
        guard featureStore.prepareSessions(filteredTo: agentID) else { return }
        appState.openSessions()
    }

    func openScheduledTasks(filteredTo agentID: String?) {
        guard featureStore.prepareScheduledTasks(filteredTo: agentID) else { return }
        appState.openScheduledTasks()
    }

    private func openBighelpLinkDevices() {
        appState.openBighelpLinkDevices()
    }

    func presentPairing() {
        if linkAccount.state == .ready {
            pairingSheetRequest = BighelpLinkPairingSheetRequest(reference: nil)
        } else {
            isLinkAccountPresented = true
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let route = BighelpIncomingURLRoute.parse(url) else { return }
        switch route {
        case .home:
            appState.select(.home)
        case .pairBighelpLink:
            // The old Link pairing flow is retired; hosts connect directly.
            return
        case .chat(let sessionID):
            guard acceptsIncomingLinks else {
                pendingIncomingChatSessionID = sessionID
                return
            }
            openIncomingChat(sessionID: sessionID)
        case .agent(let tab):
            guard acceptsIncomingLinks else { return }
            switch tab {
            case "feed": appState.select(.feed)
            case "ideas": appState.select(.ideas)
            case "goals": appState.select(.goals)
            case "apps": appState.select(.apps)
            default: openHomeChat()
            }
        case .newChat(let agentID):
            guard acceptsIncomingLinks else { return }
            // A widget names the default agent it rendered; if that profile was
            // removed since, fall back to whichever agent is default now.
            let known = agentID.flatMap { id in agents.profiles.contains(where: { $0.id == id }) ? id : nil }
            startNewChat(explicitAgentID: known)
        case .scheduledTasks:
            appState.select(.scheduledTasks)
        case .scheduledTask(let id):
            appState.select(.scheduledTasks)
            openPrepared(.scheduledTask(id: id, agentID: nil))
        case .sessions:
            appState.select(.sessions)
        }
    }

    private func openIncomingChat(sessionID: String) {
        if sessionID.hasPrefix("native-"), let managedNotifications {
            sessionRestoreTask?.cancel()
            sessionRestoreTask = Task { @MainActor in
                do { try await managedNotifications.openActivity(opaqueSessionID: sessionID) }
                catch { actionErrorMessage = "The original activity conversation is unavailable. No other host was opened." }
            }
            return
        }
        if nativeRuntime != nil {
            openNativeSession(id: sessionID)
            return
        }
        guard nativeWorkspaceStore == nil else {
            actionErrorMessage = "This legacy chat link cannot be opened. The native host was not changed."
            return
        }
        sessionRestoreTask?.cancel()
        let restoreRequest = SessionRestoreRequest(
            sessionID: sessionID,
            originTab: appState.selectedTab,
            originPath: appState.path
        )
        sessionRestoreRequest = restoreRequest
        sessionRestoreTask = Task { @MainActor in
            defer {
                if sessionRestoreRequest == restoreRequest {
                    sessionRestoreRequest = nil
                    sessionRestoreTask = nil
                }
            }
            do {
                let authoritative = try await sessionCatalog.prepareExistingSession(id: sessionID)
                try Task.checkCancellation()
                guard
                    sessionRestoreRequest == restoreRequest,
                    SessionRestorePresentationPolicy.canComplete(
                        originTab: restoreRequest.originTab,
                        originPath: restoreRequest.originPath,
                        currentTab: appState.selectedTab,
                        currentPath: appState.path
                    )
                else { return }
                SessionRestoreMetadataReconciler.reconcile(
                    authoritative,
                    workspaces: hermesWorkspaces
                )
                let route = AppRoute.chat(conversationID: sessionID)
                guard try featureStore.prepareForUserNavigation(route) else {
                    actionErrorMessage = "This session could not be prepared. Try again."
                    return
                }
                appState.activateConversation(id: sessionID, source: .quickSwitch)
            } catch is CancellationError {
                return
            } catch {
                guard sessionRestoreRequest == restoreRequest else { return }
                actionErrorMessage = "This session could not be loaded from Hermes. Try again."
            }
        }
    }

    /// Widget links carry the native catalog's own session ID. The catalog may
    /// not have loaded yet on a cold launch, so load once before giving up.
    private func openNativeSession(id sessionID: String) {
        if let record = sessionCatalog.session(id: sessionID) {
            openSessionSelection(record.summary)
            return
        }
        Task { @MainActor in
            try? await sessionCatalog.load()
            guard let record = sessionCatalog.session(id: sessionID) else {
                actionErrorMessage = "This chat is no longer available."
                return
            }
            openSessionSelection(record.summary)
        }
    }

    /// Managed notifications and Live Activities verify a durable Hermes
    /// coordinate; resolve it through the visible catalog and open that row.
    func openExternalSession(_ open: BighelpExternalSessionOpen) {
        switch open.target {
        case .catalog(let sessionID):
            guard BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
            handleIncomingURL(BighelpWidgetSnapshot.chatURL(sessionID))
            return
        case .stored:
            break
        }
        guard nativeRuntime != nil, case .stored(let profileID, let storedSessionID) = open.target,
              BighelpExternalSessionOpenCenter.shared.consume(open) else { return }
        Task { @MainActor in
            do {
                let record = try await sessionCatalog.resolveStoredSession(
                    profileID: profileID, storedSessionID: storedSessionID)
                openSession(record.summary)
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = "This conversation could not be opened. Try again from Chats."
            }
        }
    }

    /// Widgets, notifications and Shortcuts open once a Hermes host's workspace is ready.
    private var acceptsIncomingLinks: Bool {
        guard requiresLinkAccount else { return true }
        guard let hostRegistry else { return false }
        return hostRegistry.isWorkspaceReady && hostRegistry.selectedHostID != nil
    }

    private func openPendingIncomingChatIfNeeded() {
        guard let sessionID = pendingIncomingChatSessionID else { return }
        pendingIncomingChatSessionID = nil
        openIncomingChat(sessionID: sessionID)
    }

    func closeLinkDevice(id: String) {
        guard appState.path.last == .bighelpLinkDevice(id: id) else { return }
        appState.path.removeLast()
    }

    func openScheduledTask(_ task: ScheduledTask) {
        openPrepared(.scheduledTask(id: task.id, agentID: task.agentID))
    }

    func openSession(_ session: SessionSummary) {
        sessionRestoreTask?.cancel()
        sessionRestoreTask = nil
        sessionRestoreRequest = nil
        let restoreRequest = SessionRestoreRequest(
            sessionID: session.id,
            originTab: appState.selectedTab,
            originPath: appState.path
        )
        let route = AppRoute.chat(conversationID: session.id)
        // Mount the retained owner and its scoped cache before any await.
        do {
            guard try featureStore.prepareCachedForUserNavigation(route),
                  case .chat(let model)? = featureStore.preparedModel(for: route),
                  let cached = sessionCatalog.session(id: session.id) else { return }
            let featureOwnsHydration = featureStore.ownsNativeNavigationHydration && cached.kind == .direct
            if featureOwnsHydration, featureStore.canReturnToWarmSession(id: session.id) {
                featureStore.refreshWarmSessionState(id: session.id)
                appState.activateConversation(id: session.id, source: .sessions)
                return
            }
            let hydration: ShellFeatureStore.NavigationHydration?
            if featureOwnsHydration {
                // Admission must precede the cancellable presentation Task.
                hydration = try featureStore.startNavigationHydration(id: session.id)
            } else {
                hydration = nil
                var presentation = cached
                if model.isSending { presentation.isActive = true }
                model.beginHistoryHydration(from: presentation)
            }
            sessionRestoreRequest = restoreRequest
            appState.activateConversation(id: session.id, source: .sessions)
            sessionRestoreTask = Task { @MainActor in
                defer {
                    if !featureOwnsHydration,
                       sessionRestoreRequest == restoreRequest || sessionRestoreRequest?.sessionID != session.id {
                        model.finishHistoryHydration(hasPreviousHistory: sessionCatalog.hasPreviousHistory(id: session.id))
                    }
                    if sessionRestoreRequest == restoreRequest {
                        sessionRestoreRequest = nil
                        sessionRestoreTask = nil
                    }
                }
                do {
                    // Page preparation already resolves the native session and
                    // performs one ordered recovery. Do not repeat it as metadata.
                    let authoritative: SessionRecord
                    if let hydration { authoritative = try await hydration.value() }
                    else { authoritative = try await sessionCatalog.hydrateInitialPage(id: session.id) }
                    try Task.checkCancellation()
                    guard sessionRestoreRequest == restoreRequest,
                          SessionRestorePresentationPolicy.ownsHydration(route: route, path: appState.path) else { return }
                    SessionRestoreMetadataReconciler.reconcile(authoritative, workspaces: hermesWorkspaces)
                    if !featureOwnsHydration { _ = featureStore.prepare(route) }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, sessionRestoreRequest == restoreRequest else { return }
                    actionErrorMessage = "This chat could not be refreshed. Your saved conversation and draft are still available."
                }
            }
        } catch {
            // While the host is reconnecting, open the saved conversation; it
            // catches up once the connection returns instead of showing an error.
            if openCachedChatWhileReconnecting(route) { return }
            actionErrorMessage = "This session could not be prepared. Try again."
        }
    }

    /// Opens a retained chat from its saved history when the only problem is a
    /// missing host connection, and asks the host to reconnect.
    private func openCachedChatWhileReconnecting(_ route: AppRoute) -> Bool {
        guard case .chat(let id) = route, let store = nativeWorkspaceStore, !store.isConnected,
              featureStore.preparedModel(for: route) != nil else { return false }
        appState.activateConversation(id: id, source: .sessions)
        connectionKeeper.retry()
        return true
    }

    func openSessionSelection(_ session: SessionSummary) {
        switch SessionSelectionRouting.target(for: session) {
        case .session:
            openSession(session)
        case .hostedRoom(let roomID):
            guard let owner = currentWorkspaceOwner else {
                actionErrorMessage = "This group is no longer available on the selected host."
                return
            }
            openHostedGroup(roomID, owner: owner, settings: false)
        }
    }

    func forkSession(sourceID: String, throughItemID: String) {
        Task {
            do {
                let fork = try await sessionCatalog.forkSession(
                    id: sourceID,
                    throughItemID: throughItemID
                )
                let route = AppRoute.chat(conversationID: fork.id)
                guard try featureStore.prepareForUserNavigation(route) else {
                    actionErrorMessage = "The fork was created, but could not be opened. Find it in Sessions."
                    return
                }
                appState.activateConversation(id: fork.id, source: .fork)
            } catch {
                actionErrorMessage = "This checkpoint could not be forked. Refresh the session and try again."
            }
        }
    }

    func openPrepared(_ route: AppRoute) {
        do {
            guard try featureStore.prepareForUserNavigation(route) else { return }
            appState.open(route)
        } catch {
            if openCachedChatWhileReconnecting(route) { return }
            actionErrorMessage = "This session could not be prepared. Try again."
        }
    }

    private func openDashboardInboxItem(_ item: DashboardInboxItem) {
        guard let sessionID = item.sessionID,
              let session = sessionCatalog.session(id: sessionID) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    private func openDashboardAttentionItem(_ item: DashboardAttentionItem) {
        if let approvalID = item.approvalID {
            openApproval(requestID: approvalID)
            return
        }
        guard let session = featureStore.dashboardModel.session(for: item) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    private func openDashboardWorkItem(_ item: DashboardWorkItem) {
        guard let session = sessionCatalog.session(id: item.sessionID) else {
            actionErrorMessage = "This conversation is no longer available."
            return
        }
        openSession(session.summary)
    }

    private var readinessPresentation: BighelpAppReadinessPresentation {
        BighelpAppReadiness.resolve(
            account: linkAccount.state,
            devices: linkDevices.devices,
            link: linkReadinessState,
            deviceLoadState: linkDevices.loadState,
            workspaceWasPreviouslyAdmitted: false
        )
    }

    private var linkReadinessState: BighelpAppReadinessLinkState {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-use-demo-fixtures") && arguments.contains("-test-home-work") { return .verified }
        #endif
        return .unverified
    }

    @BighelpThemeReader private var theme

}
