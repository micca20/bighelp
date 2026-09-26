import PhotosUI
import SwiftUI
import UIKit
import WatchConnectivity

@MainActor
struct SettingsView: View {
    let focusedDestination: WorkspaceDestination?
    @Bindable var settings: SettingsStore
    @Bindable var userIdentity: UserIdentityStore
    let linkAccount: LoopdyLinkAccountStore?
    let linkConnectionState: LoopdyLinkLiveSocketState?
    let linkDevices: LoopdyLinkDeviceStore
    let agents: [AgentProfile]
    let personalities: PersonalityStore
    let permissionCenter: PermissionCenter
    let onOpenSessions: () -> Void
    let onOpenScheduledTasks: () -> Void
    let onOpenLoopdyLinkDevices: () -> Void
    let onOpenLoopdyLinkDevice: (String) -> Void
    let onPairLoopdyLinkDevice: () -> Void
    let onOpenLoopdyLinkAccount: () -> Void
    let onClearLocalCache: @MainActor () async -> Bool
    let hostRuntime: HostRuntimeStore?
    let agentDirectory: AgentDirectoryStore?
    let voiceSettingsScope: String?
    let voiceSettingsClient: (any VoiceSettingsClient)?
    let voiceSettingsIsCurrent: @MainActor () -> Bool
    let pluginUpdateScope: String?
    let pluginUpdateClient: (any PluginUpdateClient)?
    let pluginUpdateIsCurrent: @MainActor () -> Bool
    let notificationScope: String?
    let notificationPreferencesClient: LoopdyBuzzKitPreferencesClient
    let notificationRuntimeSource: @MainActor () -> LoopdyNotificationRuntimeSnapshot
    let refreshNotificationRuntime: (@MainActor () async throws -> LoopdyNotificationRuntimeSnapshot)?
    let notificationIsCurrent: @MainActor () -> Bool
    /// Opens a native Hermes administration page (models, providers, files, ...).
    var onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)?
    /// Opens another app route (Hermes tools hub, activity, direct links, ...).
    var onOpenRoute: ((AppRoute) -> Void)?
    @Environment(\.loopdyNotificationContext) private var notificationContext
    @State private var pluginUpdates: PluginUpdateStore?
    @State var photoSelection: PhotosPickerItem?
    @State var avatarError: String?
    @FocusState var isDisplayNameFocused: Bool
    @State var displayNameDraft: String
    @State var displayNameBaseline: String
    @State var isSavingName = false
    @State var isImportingAvatar = false
    @State var nameSaveError: String?
    @State var nameSaveStatus: String?
    @State var isPersonalitiesPresented = false
    @State var isAccountControlsPresented = false
    @Environment(\.loopdyHostRegistry) var hostRegistry
    @State var isClearCacheConfirmationPresented = false
    @State var isClearingLocalCache = false
    @State var localCacheStatusMessage: String?
    @Environment(\.reflectiveVisionCamera) var reflectiveVisionCamera
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope

    init(
        settings: SettingsStore,
        focusedDestination: WorkspaceDestination? = nil,
        userIdentity: UserIdentityStore = UserIdentityStore(),
        linkAccount: LoopdyLinkAccountStore? = nil,
        linkConnectionState: LoopdyLinkLiveSocketState? = nil,
        linkDevices: LoopdyLinkDeviceStore = LoopdyLinkDeviceStore(
            client: LoopdyLinkFixtureClient()
        ),
        agents: [AgentProfile] = [],
        personalities: PersonalityStore = PersonalityStore(client: FixturePersonalityClient()),
        permissionCenter: PermissionCenter = PermissionCenter(),
        onOpenSessions: @escaping () -> Void = {},
        onOpenScheduledTasks: @escaping () -> Void = {},
        onOpenLoopdyLinkDevices: @escaping () -> Void = {},
        onOpenLoopdyLinkDevice: @escaping (String) -> Void = { _ in },
        onPairLoopdyLinkDevice: @escaping () -> Void = {},
        onOpenLoopdyLinkAccount: @escaping () -> Void = {},
        onClearLocalCache: @escaping @MainActor () async -> Bool = { true },
        voiceSettingsScope: String? = nil,
        voiceSettingsClient: (any VoiceSettingsClient)? = nil,
        voiceSettingsIsCurrent: @escaping @MainActor () -> Bool = { false },
        pluginUpdateScope: String? = nil,
        pluginUpdateClient: (any PluginUpdateClient)? = nil,
        pluginUpdateIsCurrent: @escaping @MainActor () -> Bool = { false },
        notificationScope: String? = nil,
        notificationPreferencesClient: LoopdyBuzzKitPreferencesClient = LoopdyBuzzKitPreferencesClient(),
        notificationRuntimeSource: @escaping @MainActor () -> LoopdyNotificationRuntimeSnapshot = {
            .current
        },
        refreshNotificationRuntime: (@MainActor () async throws -> LoopdyNotificationRuntimeSnapshot)? = nil,
        registerNotificationDevice _: (@MainActor () async throws -> LoopdyNotificationRuntimeSnapshot)? = nil,
        notificationIsCurrent: @escaping @MainActor () -> Bool = { false },
        hostRuntime: HostRuntimeStore? = nil,
        agentDirectory: AgentDirectoryStore? = nil,
        onOpenWorkspaceDestination: ((WorkspaceDestination) -> Void)? = nil,
        onOpenRoute: ((AppRoute) -> Void)? = nil
    ) {
        self.onOpenWorkspaceDestination = onOpenWorkspaceDestination
        self.onOpenRoute = onOpenRoute
        self.focusedDestination = focusedDestination
        _settings = Bindable(wrappedValue: settings)
        _userIdentity = Bindable(wrappedValue: userIdentity)
        _displayNameDraft = State(initialValue: userIdentity.identity.name)
        _displayNameBaseline = State(initialValue: userIdentity.identity.name)
        self.linkAccount = linkAccount
        self.linkConnectionState = linkConnectionState
        self.linkDevices = linkDevices
        self.agents = agents
        self.personalities = personalities
        self.permissionCenter = permissionCenter
        self.onOpenSessions = onOpenSessions
        self.onOpenScheduledTasks = onOpenScheduledTasks
        self.onOpenLoopdyLinkDevices = onOpenLoopdyLinkDevices
        self.onOpenLoopdyLinkDevice = onOpenLoopdyLinkDevice
        self.onPairLoopdyLinkDevice = onPairLoopdyLinkDevice
        self.onOpenLoopdyLinkAccount = onOpenLoopdyLinkAccount
        self.onClearLocalCache = onClearLocalCache
        self.hostRuntime = hostRuntime
        self.agentDirectory = agentDirectory
        self.voiceSettingsScope = voiceSettingsScope
        self.voiceSettingsClient = voiceSettingsClient
        self.voiceSettingsIsCurrent = voiceSettingsIsCurrent
        self.pluginUpdateScope = pluginUpdateScope
        self.pluginUpdateClient = pluginUpdateClient
        self.pluginUpdateIsCurrent = pluginUpdateIsCurrent
        self.notificationScope = notificationScope
        self.notificationPreferencesClient = notificationPreferencesClient
        self.notificationRuntimeSource = notificationRuntimeSource
        self.refreshNotificationRuntime = refreshNotificationRuntime
        self.notificationIsCurrent = notificationIsCurrent
    }

    var body: some View {
        Group {
            if let focusedDestination { focusedPage(focusedDestination) }
            else { menuPage }
        }
    }

    private var menuPage: some View {
        // Each section is deferred and type-erased: inlined together they overflow
        // the device's main-thread stack in Release builds (see LoopdyDeferredSection).
        Form {
            LoopdyDeferredSection { localIdentity }
            LoopdyDeferredSection { assistantBasics }
            LoopdyDeferredSection { appearance }
            LoopdyDeferredSection { chatExperience }
            LoopdyDeferredSection {
                settingsMenuGroup("Notifications & Access", sections: [.notifications, .permissions])
            }
            LoopdyDeferredSection { settingsMenuGroup("Connection", sections: [.connectivityAndNotifications]) }
            if let companionStore {
                LoopdyDeferredSection { companionExtras(companionStore) }
            }
            LoopdyDeferredSection { nerdModeToggle }
            if settings.nerdModeEnabled {
                LoopdyDeferredSection { nerdModeSections }
            }
        }
        .animation(.snappy(duration: LoopdyTokens.transitionDuration), value: settings.nerdModeEnabled)
        .loopdyFormSurface()
        .listSectionSpacing(20)
        .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .sheet(isPresented: $isPersonalitiesPresented) {
            NavigationStack {
                PersonalitiesView(store: personalities)
            }
            .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("settings.screen")
        .task(id: pluginUpdateScope) {
            pluginUpdates?.invalidate()
            guard let scope = pluginUpdateScope, let client = pluginUpdateClient else {
                pluginUpdates = nil
                return
            }
            let store = PluginUpdateStore(scope: scope, client: client, isCurrent: pluginUpdateIsCurrent)
            pluginUpdates = store
            await store.refreshStatus()
        }
        .task {
            if hostRegistry?.connectionMode != .independent,
               (linkAccount?.state == .ready || linkAccount == nil),
               linkDevices.loadState == .idle {
                await linkDevices.load()
            }
            await loadAccountProfileIfAvailable()
        }
    }

    private func companionExtras(_ companionStore: CompanionStore) -> some View {
        Section("Extras") {
            NavigationLink {
                CompanionSettingsView(
                    store: companionStore,
                    agents: agents,
                    agentScope: companionAgentScope
                )
            } label: {
                HStack(spacing: LoopdyTokens.space12) {
                    LoopdyIconTile(systemName: "pawprint.fill")
                    VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                        Text("Companion Pet")
                            .loopdyFont(.body)
                            .foregroundStyle(theme.primaryText)
                        Text("Character, motion, and agent")
                            .loopdyFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(minHeight: 52)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .accessibilityIdentifier("companion-settings-entry")
                }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private func focusedPage(_ destination: WorkspaceDestination) -> some View {
        settingsPage(title: destination.title) {
            switch destination {
            case .appearance:
                appearance
                advancedAppearance
            case .tabBar:
                Section("Bottom menu") {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    Label("Agents", systemImage: "person.2")
                    Label("Tasks", systemImage: "calendar.badge.clock")
                    Label("Workspace", systemImage: "square.grid.2x2")
                    Text("On iPhone, the bottom menu shows on these four screens and hides while you chat or type.").font(.footnote).foregroundStyle(.secondary)
                }
                edgeGestures
            case .caching:
                localCache
                Section { Text("Agents, groups and chat history stay on this device between connections. Hermes remains the source for changes.").foregroundStyle(.secondary) }
            case .security:
                Section("Current connection") {
                    if let hostRegistry, let saved = hostRegistry.selectedWorkspace?.savedConnection {
                        LabeledContent("Computer", value: saved.endpoint.identity)
                        LabeledContent("Sign-in", value: authenticationTitle(saved.authentication))
                    } else { Text("No host is connected.").foregroundStyle(.secondary) }
                    Text("Connection credentials are kept in the iOS Keychain. The host controls which sign-in methods it accepts.").font(.footnote).foregroundStyle(.secondary)
                }
            case .contact:
                Section("Help & feedback") {
                    Link("Report a problem", destination: URL(string: "https://github.com/promptclickrun/bighelp/issues")!)
                    Link("Hermes documentation", destination: URL(string: "https://hermes-agent.nousresearch.com/docs")!)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                }
            case .watch:
                Section("Apple Watch") {
                    if WCSession.isSupported() {
                        LabeledContent("Paired", value: WCSession.default.isPaired ? "Yes" : "No")
                        LabeledContent("App installed", value: WCSession.default.isWatchAppInstalled ? "Yes" : "No")
                        LabeledContent("Connection", value: WCSession.default.isReachable ? "Reachable" : "Not currently reachable")
                    } else { Text("Apple Watch connectivity is unavailable on this device.") }
                }
            default: EmptyView()
            }
        }
        .accessibilityIdentifier("settings.detail.\(destination.rawValue)")
    }

    private func authenticationTitle(_ authentication: DirectHermesStoredAuthentication) -> String {
        switch authentication {
        case .dashboardSession(_, let automatic): automatic ? "No sign-in" : "Session token"
        case .bearer: "Host account"
        case .legacyLoopbackToken: "Session token"
        }
    }

    private func settingsMenuGroup(_ title: String, sections: [SettingsMenuSection]) -> some View {
        Section(title) {
            ForEach(sections) { section in
                NavigationLink {
                    destination(for: section)
                } label: {
                    settingsMenuRow(section)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .accessibilityIdentifier("settings.menu.\(section.rawValue)")
            }
        }
        .listRowBackground(theme.surface)
    }

    private func settingsMenuRow(_ section: SettingsMenuSection) -> some View {
        HStack(spacing: LoopdyTokens.space12) {
            LoopdyIconTile(systemName: section.systemImage)
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text(section.title)
                    .loopdyFont(.body)
                    .foregroundStyle(theme.primaryText)
                Text(section.detail)
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: LoopdyTokens.space8)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func destination(for section: SettingsMenuSection) -> some View {
        switch section {
        case .accountAndDevices:
            accountAndDevicesPage
        case .workspace:
            settingsPage(title: section.title) {
                workspace
                edgeGestures
            }
        case .agentsAndPersonalities:
            settingsPage(title: section.title) {
                agentBehavior
            }
        case .chat:
            settingsPage(title: section.title) {
                chatExperience
                advancedChat
            }
        case .appearance:
            settingsPage(title: section.title) {
                appearance
                advancedAppearance
            }
        case .notifications:
            LoopdyNotificationSettingsView(
                permissionCenter: permissionCenter,
                hostRegistry: hostRegistry,
                scope: notificationContext?.scope ?? notificationScope,
                preferencesClient: notificationPreferencesClient,
                runtimeSource: notificationRuntimeSource,
                refreshRuntime: notificationContext?.refresh ?? refreshNotificationRuntime,
                sendTest: notificationContext?.test,
                isCurrent: notificationContext?.isCurrent ?? notificationIsCurrent
            )
        case .permissions:
            PermissionsSettingsView(center: permissionCenter)
        case .connectivityAndNotifications:
            settingsPage(title: section.title) {
                if let hostRegistry, hostRegistry.selectedHostID != nil {
                    LoopdyConfiguredHostsSection(registry: hostRegistry)
                    Section { Text(hostRegistry.selectedWorkspace?.status ?? "Not connected") }
                } else {
                    HostRuntimeSection(store: hostRuntime, connectionState: linkConnectionState,
                                       agents: agentDirectory, theme: theme)
                    PluginUpdateSection(store: pluginUpdates, theme: theme)
                    connectivity
                }
                LoopdyPluginCapabilitiesSection(
                    connections: workspaceConnections,
                    permissionCenter: permissionCenter
                )
            }
        }
    }

    func settingsPage<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .loopdyFormSurface()
        .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ClearCacheConfirmation(isPresented: $isClearCacheConfirmationPresented, onConfirm: clearLocalCache))
    }

    func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
            Text(title)
                .loopdyFont(.body)
                .foregroundStyle(theme.primaryText)
            Text(detail)
                .loopdyFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LoopdyTokens.space4)
    }

    @LoopdyThemeReader var theme

    @Environment(\.workspaceConnections) private var workspaceConnections
}

#Preview("Settings") {
    NavigationStack {
        SettingsView(settings: SettingsStore())
    }
}

#Preview("Settings - Accessibility Extra Large") {
    NavigationStack {
        SettingsView(settings: SettingsStore())
    }
    .dynamicTypeSize(.accessibility3)
}

/// Every page that shows "Clear Local Cache" confirms it the same way.
struct ClearCacheConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert("Clear local cache?", isPresented: $isPresented) {
            Button("Clear Cache and Refresh", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("bighelp will keep your account and preferences, clear cached data for the selected host, then pull fresh agents, sessions, and account data.")
        }
    }
}
