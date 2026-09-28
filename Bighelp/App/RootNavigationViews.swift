import SwiftUI

@MainActor
struct AgentsShellView: View {
    let agents: AgentDirectoryStore
    let runtimeDefaultsClient: any AgentRuntimeDefaultsClient
    let onSelect: (AgentProfile) -> Void
    let onOpenSessions: (AgentProfile) -> Void
    let onOpenHostStatus: () -> Void
    let hostRuntime: HostRuntimeStore?
    let workspaceOwner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities
    let botModeRooms: BotModeRoomStore
    let cloneClient: (any AgentProfileCloneClient)?
    let shortcutsAvailable: Bool
    let onAction: @MainActor (AgentWorkspaceActionRequest) -> Void
    var groupFilterRequest: Binding<String?> = .constant(nil)

    var body: some View {
        AgentsView(
            store: agents,
            runtimeDefaultsClient: runtimeDefaultsClient,
            onSelect: onSelect,
            onOpenSessions: onOpenSessions,
            onOpenHostStatus: onOpenHostStatus,
            hostRuntime: hostRuntime,
            workspaceOwner: workspaceOwner,
            capabilities: capabilities,
            botModeRooms: botModeRooms,
            cloneClient: cloneClient,
            shortcutsAvailable: shortcutsAvailable,
            onAction: onAction,
            groupFilterRequest: groupFilterRequest
        )
    }
}

@MainActor
struct ApprovalDestinationView: View {
    @State private var model: ApprovalModel

    init(model: ApprovalModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            ApprovalCard(model: model)
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("approval.screen")
    }

    @BighelpThemeReader private var theme

}

enum ConversationRootDestination: String, CaseIterable, Identifiable, Sendable {
    case chats
    case feed
    case ideas
    case goals
    case apps
    case agents
    case scheduledTasks
    case activity
    case workspace
    case directLinks
    case diagnostics
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .apps: "Apps"
        case .agents: "Agents"
        case .scheduledTasks: "Scheduled Tasks"
        case .activity: "Activity"
        case .workspace: "Hermes Tools"
        case .directLinks: "Direct Links"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .feed: "newspaper"
        case .ideas: "lightbulb"
        case .goals: "checkmark.square"
        case .apps: "square.on.circle"
        case .agents: "person.2"
        case .scheduledTasks: "calendar.badge.clock"
        case .activity: "waveform.path"
        case .workspace: "square.grid.2x2"
        case .directLinks: "link"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        "root.destination.\(rawValue)"
    }

    func isSelected(tab: AppTab, path: [AppRoute]) -> Bool {
        switch self {
        case .chats:
            tab == .sessions
        case .feed: tab == .feed
        case .ideas: tab == .ideas
        case .goals: tab == .goals
        case .apps: tab == .apps
        case .agents:
            tab == .agents
        case .scheduledTasks:
            tab == .scheduledTasks
        case .activity:
            tab == .workspace && path == [.workspaceActivity]
        case .directLinks:
            tab == .workspace && path == [.bighelpLinkDevices]
        case .diagnostics:
            tab == .workspace && path == [.workspaceManagement(.logs)]
        case .settings:
            tab == .profile
        case .workspace:
            tab == .workspace
                && path != [.workspaceActivity]
                && path != [.bighelpLinkDevices]
                && path != [.workspaceManagement(.logs)]
                && path != [.workspaceSettings]
        }
    }
}

enum ConversationRootNavigationPresentation {
    static let settingsAccessibilityIdentifier = "root.settings"
    static let composeAccessibilityIdentifier = "root.new-chat"
    static let sidebarAccessibilityIdentifier = "root.sidebar"

    static func usesPersistentSidebar(horizontalSizeClassIsRegular: Bool) -> Bool {
        horizontalSizeClassIsRegular
    }
}

/// A persistent iPad destination list. The detail remains owned by the root
/// NavigationStack so opening a chat preserves the existing route lifecycle.
struct ConversationRootSidebar: View {
    let theme: BighelpTheme
    let selectedTab: AppTab
    let path: [AppRoute]
    let onOpen: (ConversationRootDestination) -> Void
    let onNewChat: () -> Void
    var showsAdvanced = false
    @Environment(\.bighelpHostRegistry) private var hostRegistry

    var body: some View {
        List {
            // Same hosts as the ☰ menu: tap one to switch.
            let hosts = BighelpMenuHosts.current(registry: hostRegistry, linkDevices: nil)
            if !hosts.hosts.isEmpty || hosts.add != nil {
                Section("Hosts") {
                    ForEach(hosts.hosts) { host in
                        Button { hosts.select(host.id) } label: {
                            Label(host.name, systemImage: host.isSelected ? "checkmark.circle.fill" : "desktopcomputer")
                                .foregroundStyle(host.isSelected ? theme.action : theme.primaryText)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(host.isSelected ? .isSelected : [])
                        .accessibilityIdentifier("menu.host.\(host.id)")
                    }
                    if let add = hosts.add {
                        Button(action: add) {
                            Label("Add host", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("menu.host.add")
                    }
                }
            }

            Section {
                Button(action: onNewChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier(ConversationRootNavigationPresentation.composeAccessibilityIdentifier)
            }

            Section("Home") {
                destinationButton(.chats)
                destinationButton(.feed)
                destinationButton(.ideas)
                destinationButton(.goals)
                destinationButton(.apps)
            }

            Section("Manage") {
                destinationButton(.agents)
                destinationButton(.scheduledTasks)
            }

            Section {
                destinationButton(.settings)
            }

            // Activity, logs and the rest of the host's tools are inside Hermes Tools.
            if showsAdvanced {
                Section("Advanced") {
                    destinationButton(.workspace)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .tint(theme.action)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(EmberBrand.appName) navigation")
        .accessibilityIdentifier(ConversationRootNavigationPresentation.sidebarAccessibilityIdentifier)
    }

    private func destinationButton(_ destination: ConversationRootDestination) -> some View {
        let selected = destination.isSelected(tab: selectedTab, path: path)
        return Button {
            onOpen(destination)
        } label: {
            Label(destination.title, systemImage: destination.systemImage)
                .foregroundStyle(selected ? theme.action : theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .listRowBackground(selected ? theme.action.opacity(0.12) : Color.clear)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(destination.accessibilityIdentifier)
    }
}


/// The Chats compose action: a large, tinted Liquid Glass circle that floats
/// over the list like the iMessage compose affordance, instead of a small
/// toolbar glyph.
struct RootComposeButton: View {
    static let diameter: CGFloat = 60
    /// iPad's sidebar already owns the shared compose identifier.
    var identifier = ConversationRootNavigationPresentation.composeAccessibilityIdentifier
    let action: () -> Void

    @BighelpThemeReader private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title2) private var glyph: CGFloat = 24
    @State private var taps = 0

    var body: some View {
        Button {
            BighelpKeyboard.dismiss()
            taps += 1
            action()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(.circle)
                .modifier(ComposeSurface(tint: theme.action, reduceTransparency: reduceTransparency))
        }
        .buttonStyle(BighelpPressFeedbackStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier(identifier)
    }

    private struct ComposeSurface: ViewModifier {
        let tint: Color
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            #else
            content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            #endif
        }
    }
}
