import SwiftUI

/// Hosts the menu can switch between: independently connected hosts, or hosts
/// paired through bighelp Link.
struct BighelpMenuHosts {
    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let isSelected: Bool
    }

    var hosts: [Host] = []
    var select: (String) -> Void = { _ in }
    var add: (() -> Void)?

    @MainActor
    static func current(registry: BighelpHostRegistry?, linkDevices: BighelpLinkDeviceStore?) -> BighelpMenuHosts {
        let add: (() -> Void)? = registry.flatMap { registry in
            registry.canConfigureHosts ? { registry.beginSetup() } : nil
        }
        if let registry, !registry.hosts.isEmpty {
            return BighelpMenuHosts(
                hosts: registry.hosts.map {
                    Host(id: $0.id.uuidString, name: $0.name, isSelected: $0.id == registry.selectedHostID)
                },
                select: { id in registry.select(UUID(uuidString: id)) },
                add: add
            )
        }
        if let linkDevices {
            let paired = BighelpLinkDeviceSections(devices: linkDevices.devices).hosts
            if !paired.isEmpty {
                return BighelpMenuHosts(
                    hosts: paired.map { Host(id: $0.id, name: $0.name, isSelected: $0.id == linkDevices.selectedHostID) },
                    select: { id in _ = linkDevices.selectHost(id) },
                    add: add
                )
            }
        }
        return BighelpMenuHosts(add: add)
    }
}

/// Where the menu can go.
struct BighelpMenuDestinations {
    var newChatTitle = "New chat"
    var onNewChat: () -> Void
    var onNewGroup: (() -> Void)?
    var onAllChats: () -> Void
    var onAgents: () -> Void
    var onScheduledTasks: () -> Void
    /// Nerd Mode: the host's tools.
    var onHermesTools: (() -> Void)?
    /// Nerd Mode: the Hermes project folder chats run in.
    var folder: (name: String, open: () -> Void)?
    var onSettings: () -> Void
}

/// bighelp's one menu (☰): switch hosts, start or find a chat, and go anywhere
/// else. Settings holds everything you configure; Hermes Tools (Nerd Mode) holds
/// the host's own tools.
struct BighelpMenu<Recent: View>: View {

    let hosts: BighelpMenuHosts
    let destinations: BighelpMenuDestinations
    /// Runs before every choice: closes a sheet or drawer; nothing for a sidebar.
    let close: () -> Void
    var hasRecent = true
    @ViewBuilder let recent: () -> Recent

    var body: some View {
        List {
            if !hosts.hosts.isEmpty || hosts.add != nil || destinations.folder != nil {
                hostsSection
            }
            chatsSection
            goToSection
            if hasRecent {
                Section("Recent") { recent() }
                    .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .tint(theme.action)
        .accessibilityIdentifier("navigation.menu")
    }

    private var hostsSection: some View {
        Section("Hosts") {
            ForEach(hosts.hosts) { host in
                Button { choose { hosts.select(host.id) } } label: {
                    BighelpMenuRowLabel(title: host.name, symbol: "desktopcomputer",
                                        trailing: host.isSelected ? .selected : .none)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(host.isSelected ? .isSelected : [])
                .accessibilityIdentifier("menu.host.\(host.id)")
            }
            if let add = hosts.add {
                row("Add host", symbol: "plus", id: "menu.host.add", trailing: .none, action: add)
            }
            if let folder = destinations.folder {
                row("Folder", detail: folder.name, symbol: "folder", id: "menu.folder", action: folder.open)
            }
        }
        .listRowBackground(theme.surface)
    }

    private var chatsSection: some View {
        Section("Chats") {
            row(destinations.newChatTitle, symbol: "square.and.pencil", id: "menu.new-chat", trailing: .none,
                action: destinations.onNewChat)
            if let onNewGroup = destinations.onNewGroup {
                row("New group chat", symbol: "person.3", id: "menu.new-group", trailing: .none, action: onNewGroup)
            }
            row("All chats", symbol: "bubble.left.and.bubble.right", id: "menu.chats", action: destinations.onAllChats)
        }
        .listRowBackground(theme.surface)
    }

    private var goToSection: some View {
        Section("Go to") {
            row("Agents", detail: "Create, edit and pin your agents", symbol: "person.2", id: "menu.agents",
                action: destinations.onAgents)
            row("Scheduled tasks", detail: "Work that runs on its own", symbol: "calendar.badge.clock",
                id: "menu.scheduled-tasks", action: destinations.onScheduledTasks)
            if let onHermesTools = destinations.onHermesTools {
                row("Hermes Tools", detail: "Activity, files, skills, models and more", symbol: "square.grid.2x2",
                    id: "menu.hermes-tools", action: onHermesTools)
            }
            row("Settings", detail: "Profile, look, notifications and hosts", symbol: "gearshape",
                id: "menu.settings", action: destinations.onSettings)
        }
        .listRowBackground(theme.surface)
    }

    private func row(_ title: String, detail: String? = nil, symbol: String, id: String,
                     trailing: BighelpMenuRowLabel.Trailing = .chevron, action: @escaping () -> Void) -> some View {
        Button { choose(action) } label: {
            BighelpMenuRowLabel(title: title, detail: detail, symbol: symbol, trailing: trailing)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func choose(_ action: () -> Void) {
        close()
        action()
    }

    @BighelpThemeReader private var theme
}

/// A branded menu row: icon tile, title, optional detail, and a trailing mark.
struct BighelpMenuRowLabel: View {
    enum Trailing { case chevron, selected, none }

    let title: String
    var detail: String?
    let symbol: String
    var trailing: Trailing = .chevron

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            case .selected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
            case .none:
                EmptyView()
            }
        }
        .frame(minHeight: 48)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// A recent chat in the menu: who it's with, its title and when it last moved.
struct BighelpMenuChatRow: View {
    let chat: SessionSummary
    let agent: (String) -> (name: String, imageURL: URL?)?

    var body: some View {
        let lead = chat.kind == .direct ? chat.agentIDs.first.flatMap(agent) : nil
        HStack(spacing: BighelpTokens.space12) {
            if let lead, let id = chat.agentIDs.first {
                AvatarView(stableID: id, displayName: lead.name, imageURL: lead.imageURL, size: 30)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.caption)
                    .foregroundStyle(theme.action)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.action.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "New chat" : chat.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(lead?.name ?? "Group chat")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: BighelpTokens.space8)
            if chat.isActive {
                Circle().fill(theme.action).frame(width: 8, height: 8)
                    .accessibilityLabel("Working")
            }
            Text(chat.updatedAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// The bighelp lockup in the top bar. Touch and hold it to switch hosts.
struct EmberHostSwitcherLockup: View {
    var linkDevices: BighelpLinkDeviceStore?
    @Environment(\.bighelpHostRegistry) private var registry

    var body: some View {
        let hosts = BighelpMenuHosts.current(registry: registry, linkDevices: linkDevices)
        if hosts.hosts.count + (hosts.add == nil ? 0 : 1) > 0 {
            Menu {
                Section("Switch host") {
                    ForEach(hosts.hosts) { host in
                        Button { hosts.select(host.id) } label: {
                            if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                        }
                        .accessibilityIdentifier("brand.host.\(host.id)")
                    }
                }
                if let add = hosts.add {
                    Button(action: add) { Label("Add host", systemImage: "plus") }
                        .accessibilityIdentifier("brand.host.add")
                }
            } label: {
                EmberLockup(markSize: 28)
            } primaryAction: {}
            .accessibilityLabel(EmberBrand.appName)
            .accessibilityHint("Touch and hold to switch hosts.")
            .accessibilityIdentifier("brand.host-switcher")
        } else {
            EmberLockup(markSize: 28)
        }
    }
}
