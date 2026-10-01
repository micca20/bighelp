import SwiftUI

/// Which host a row belongs to, shown only when there's more than one.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.12), in: .capsule)
            .accessibilityLabel("on \(name)")
    }

    @BighelpThemeReader private var theme
}

extension FleetActivity {
    var liveState: AgentLiveState {
        switch self {
        case .working: .thinking
        case .waiting: .nudge
        }
    }
}

/// Filter chips: all hosts, or one. A host that couldn't be read says so.
struct FleetHostFilter: View {
    let fleet: FleetStore
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                chip("All hosts", isOn: selection == nil, id: "fleet.filter.all") { selection = nil }
                ForEach(fleet.hosts) { host in
                    chip(host.name, isOn: selection == host.id, status: fleet.statuses[host.id],
                         id: "fleet.filter.\(host.name)") { selection = host.id }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
    }

    private func chip(_ title: String, isOn: Bool, status: FleetHostStatus? = nil, id: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if status == .loading {
                    ProgressView().controlSize(.mini)
                } else if case .unreachable = status {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: 34)
            .background(isOn ? theme.action : theme.surface, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @BighelpThemeReader private var theme
}

/// One agent: its picture (with what it's doing), name, host, and its latest chat.
struct FleetAgentRow: View {
    let agent: FleetAgent
    let fleet: FleetStore

    var body: some View {
        let latest = fleet.latestChat(for: agent)
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: agent.profileID, displayName: agent.name,
                       imageURL: fleet.avatars.url(for: agent.avatarFile), size: SessionRow.avatarSize,
                       state: agent.activity?.liveState)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(agent.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(agent.hostID)) }
                    Spacer(minLength: BighelpTokens.space4)
                    if let latest {
                        Text(SessionRow.compactTimestamp(latest.updatedAt))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                if !agent.role.isEmpty {
                    Text(agent.role)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Text(subtitle(latest))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ latest: FleetChat?) -> String {
        if let activity = agent.activity { return activity.liveState.label }
        if let latest {
            let preview = SessionPreviewText.plain(latest.preview)
            return preview.isEmpty ? latest.title : preview
        }
        return "Start a chat"
    }

    @BighelpThemeReader private var theme
}

/// All agents on all hosts: pick one and start working with it.
struct FleetHomeView: View {
    let fleet: FleetStore
    let onOpen: (FleetAgent) -> Void
    /// None while the selected host is still connecting.
    var onNewChat: (() -> Void)? = nil
    /// Pins or unpins an agent on its own host.
    var onSetPinned: ((FleetAgent, Bool) -> Void)? = nil
    @State private var hostFilter: UUID?
    /// A pinned agent held and let go: its actions.
    @State private var managing: FleetAgent?
    @State private var search = ""
    @State private var isArrangingPinned = false

    var body: some View {
        let pinned = pinnedAgents
        let listed = listedAgents(excluding: Set(pinned.map(\.id)))
        List {
            if !pinned.isEmpty {
                Section {
                    pinnedRow(pinned)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if fleet.showsHostNames {
                Section {
                    FleetHostFilter(fleet: fleet, selection: $hostFilter)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(listed) { agent in
                    Button { onOpen(agent) } label: { FleetAgentRow(agent: agent, fleet: fleet) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            if let onSetPinned {
                                Button(agent.isPinned ? "Unpin" : "Pin",
                                       systemImage: agent.isPinned ? "pin.slash" : "pin") {
                                    onSetPinned(agent, !agent.isPinned)
                                }
                                .accessibilityIdentifier("fleet.agent.\(agent.isPinned ? "unpin" : "pin")")
                            }
                        }
                        .accessibilityIdentifier("fleet.agent.\(agent.name)")
                }
                FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(isArrangingPinned)
        // The one main action, where a thumb rests: above the search bar, on the right.
        .overlay(alignment: .bottomTrailing) {
            if let onNewChat {
                RootComposeButton(identifier: "fleet.new-chat", size: 72, action: onNewChat)
                    .padding(.trailing, BighelpTokens.space20)
                    .padding(.bottom, BighelpTokens.space12)
            }
        }
        .searchable(text: $search, prompt: "Search agents")
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if fleet.agents().isEmpty, !fleet.hosts.contains(where: { fleet.isReading($0.id) }) {
                ContentUnavailableView("No agents yet", systemImage: "person.2",
                                       description: Text("The agents on your hosts show up here."))
            }
        }
        .task { fleet.refresh() }
        .confirmationDialog(managing?.name ?? "", isPresented: Binding(
            get: { managing != nil }, set: { if !$0 { managing = nil } }), titleVisibility: .visible) {
            if let agent = managing {
                Button("Open chat") { onOpen(agent) }
                if let onSetPinned {
                    Button("Unpin") { onSetPinned(agent, false) }
                        .accessibilityIdentifier("fleet.pinned.unpin")
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.home")
    }

    /// Pinned agents up top, like favorites, when nothing is filtered.
    private var pinnedAgents: [FleetAgent] {
        guard search.isEmpty, hostFilter == nil else { return [] }
        return fleet.pinnedAgents()
    }

    private func listedAgents(excluding pinned: Set<String>) -> [FleetAgent] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return fleet.agents(on: hostFilter).filter { agent in
            guard !pinned.contains(agent.id) else { return false }
            guard !query.isEmpty else { return true }
            return agent.name.localizedCaseInsensitiveContains(query)
                || agent.role.localizedCaseInsensitiveContains(query)
                || fleet.hostName(agent.hostID).localizedCaseInsensitiveContains(query)
        }
    }

    /// Big pictures with the name and role, simple like a contact grid. Touch
    /// and hold one to drag it into a new place.
    private func pinnedRow(_ agents: [FleetAgent]) -> some View {
        PinnedArrangeGrid(
            items: agents,
            columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: BighelpTokens.space8, alignment: .top)],
            canReorder: true, space: "fleet.pinned", open: onOpen, manage: { managing = $0 },
            reorder: { fleet.reorderPinned($0) }, isArranging: $isArrangingPinned,
            identifier: { "fleet.pinned.\($0.name)" },
            tile: { agent, lifted in pinnedTile(agent, lifted: lifted) },
            trailing: { EmptyView() }
        )
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
    }

    private func pinnedTile(_ agent: FleetAgent, lifted: Bool) -> some View {
        VStack(spacing: 6) {
            AvatarView(stableID: agent.profileID, displayName: agent.name,
                       imageURL: fleet.avatars.url(for: agent.avatarFile), size: 88,
                       state: agent.activity?.liveState)
                .scaleEffect(lifted ? 1.08 : 1)
                .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: 12, y: 6)
            Text(agent.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            if !agent.role.isEmpty {
                Text(agent.role)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// The list stays up while a tapped agent's host connects, with a note.
struct FleetConnectingView: View {
    let fleet: FleetStore
    let onOpen: (FleetAgent) -> Void
    /// False once connecting stopped without a connection.
    let isConnecting: Bool
    let retry: () -> Void
    /// Failure shows only after an attempt; a switch starts connecting a moment later.
    @State private var hasTried = false

    var body: some View {
        let host = fleet.selectedHostID.map(fleet.hostName) ?? "your host"
        FleetHomeView(fleet: fleet, onOpen: onOpen)
            .onChange(of: isConnecting, initial: true) { _, connecting in if connecting { hasTried = true } }
            .onChange(of: fleet.selectedHostID) { _, _ in hasTried = isConnecting }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: BighelpTokens.space8) {
                    if isConnecting || !hasTried {
                        ProgressView()
                        Text("Connecting to \(host)…")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Couldn't connect to \(host).")
                        Button("Try again", action: retry)
                            .buttonStyle(.borderless)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(theme.surface)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fleet.connecting")
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
    }

    @BighelpThemeReader private var theme
}

/// Hosts still loading or out of reach, at the bottom of a list.
struct FleetHostNotes: View {
    let fleet: FleetStore
    let hostFilter: UUID?

    var body: some View {
        ForEach(fleet.hosts.filter { hostFilter == nil || $0.id == hostFilter }) { host in
            switch fleet.statuses[host.id] {
            case .unreachable(let message):
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                        Text(fleet.snapshots[host.id] == nil ? message : "\(message) Showing what it had last time.")
                            .font(.footnote).foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Button("Try again") { fleet.refresh(force: true) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fleet.host-note.\(host.name)")
            case .loading where fleet.snapshots[host.id] == nil:
                HStack(spacing: BighelpTokens.space8) {
                    ProgressView()
                    Text("Loading \(host.name)…").font(.subheadline).foregroundStyle(theme.secondaryText)
                }
                .listRowBackground(Color.clear)
            default:
                EmptyView()
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Every chat on every host, newest first, each tagged with its host.
struct FleetChatsView: View {
    let fleet: FleetStore
    let onOpen: (FleetChat) -> Void
    @State private var hostFilter: UUID?

    var body: some View {
        List {
            if fleet.showsHostNames {
                FleetHostFilter(fleet: fleet, selection: $hostFilter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(fleet.chats(on: hostFilter)) { chat in
                Button { onOpen(chat) } label: { FleetChatRow(chat: chat, fleet: fleet) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            }
            FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if fleet.chats(on: hostFilter).isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .task { fleet.refresh() }
        .navigationTitle("All chats")
        .accessibilityIdentifier("fleet.chats")
    }

    @BighelpThemeReader private var theme
}

/// A chat in the all-hosts lists: who it's with, its host, title and when.
struct FleetChatRow: View {
    let chat: FleetChat
    let fleet: FleetStore
    var compact = false

    var body: some View {
        let agent = fleet.agent(hostID: chat.hostID, profileID: chat.profileID)
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: chat.profileID, displayName: agent?.name ?? "Agent",
                       imageURL: fleet.avatars.url(for: agent?.avatarFile), size: compact ? 30 : SessionRow.avatarSize,
                       state: chat.isActive ? .thinking : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(chat.title.isEmpty ? "New chat" : chat.title)
                        .font(compact ? .body : .callout.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: BighelpTokens.space4)
                    Text(SessionRow.compactTimestamp(chat.updatedAt))
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 6) {
                    Text(agent?.name ?? "Agent")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(chat.hostID)) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Scheduled tasks on every host, each tagged with its host.
struct FleetTasksView: View {
    let fleet: FleetStore
    let onOpen: (FleetTask) -> Void
    @State private var hostFilter: UUID?

    var body: some View {
        List {
            if fleet.showsHostNames {
                FleetHostFilter(fleet: fleet, selection: $hostFilter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(fleet.tasks(on: hostFilter)) { task in
                Button { onOpen(task) } label: { row(task) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("fleet.task.\(task.name)")
            }
            FleetHostNotes(fleet: fleet, hostFilter: hostFilter)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            fleet.refresh(force: true)
            await fleet.waitForReads()
        }
        .overlay {
            if fleet.tasks(on: hostFilter).isEmpty {
                ContentUnavailableView("No scheduled tasks", systemImage: "calendar.badge.clock",
                                       description: Text("Ask an agent to check in or remind you, and it shows up here."))
            }
        }
        .task { fleet.refresh() }
        .accessibilityIdentifier("fleet.tasks")
    }

    private func row(_ task: FleetTask) -> some View {
        let agent = fleet.agent(hostID: task.hostID, profileID: task.profileID)
        return HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: task.profileID, displayName: agent?.name ?? "Agent",
                       imageURL: fleet.avatars.url(for: agent?.avatarFile), size: 44,
                       state: task.status == .failed ? .nudge : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(task.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(task.hostID)) }
                }
                Text([agent?.name, task.schedule].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                Text(ScheduledTaskCopy.shortNextRun(status: task.status, nextRun: task.nextRun))
                    .font(.footnote)
                    .foregroundStyle(task.status == .failed ? theme.danger : theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space4)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Asks which host a host-only screen (Settings, Projects…) should open for.
struct FleetHostPicker: View {
    let fleet: FleetStore
    let destination: FleetDestination
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(fleet.hosts) { host in
                        Button { onPick(host.id) } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                BighelpIconTile(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                    Text(detail(host))
                                        .font(.footnote)
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer(minLength: BighelpTokens.space8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fleet.gate.host.\(host.name)")
                    }
                } footer: {
                    Text("\(destination.title) belongs to one host. Pick which one.")
                }
            }
            .navigationTitle(destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("fleet.gate.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("fleet.gate")
    }

    private func detail(_ host: FleetHost) -> String {
        let agents = fleet.snapshots[host.id]?.agents.count
        let count = agents.map { $0 == 1 ? "1 agent" : "\($0) agents" }
        var unreachable: String?
        if case .unreachable = fleet.statuses[host.id] { unreachable = "Couldn't reach it just now" }
        return [host.isSelected ? "Open now" : nil, count, unreachable].compactMap { $0 }.joined(separator: " · ")
    }

    @BighelpThemeReader private var theme
}

/// New chat in the all-hosts view: pick any agent on any host.
struct FleetAgentPicker: View {
    let fleet: FleetStore
    let onPick: (FleetAgent) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(agents) { agent in
                Button { onPick(agent) } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        AvatarView(stableID: agent.profileID, displayName: agent.name,
                                   imageURL: fleet.avatars.url(for: agent.avatarFile), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: BighelpTokens.space8) {
                                Text(agent.name).font(.body.weight(.semibold)).foregroundStyle(theme.primaryText)
                                if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(agent.hostID)) }
                            }
                            if !agent.role.isEmpty {
                                Text(agent.role).font(.footnote).foregroundStyle(theme.secondaryText).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.new-chat.\(agent.name)")
            }
            .searchable(text: $search, prompt: "Search agents")
            .navigationTitle("New chat with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var agents: [FleetAgent] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return fleet.agents().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    @BighelpThemeReader private var theme
}
