import SwiftUI

@MainActor
struct ScheduledTasksView: View {
    @State private var store: ScheduledTasksStore
    @State private var createAgent: AgentProfile?
    @State private var isAgentPickerPresented = false
    @State private var isBlueprintsPresented = false
    @State private var opensBlueprintsAfterEditor = false
    @State private var searchQuery = ""
    @State private var toggleErrorMessage: String?
    let agents: AgentDirectoryStore
    let showsInlineHeading: Bool
    let onOpen: (ScheduledTask) -> Void

    init(
        store: ScheduledTasksStore,
        agents: AgentDirectoryStore,
        showsInlineHeading: Bool = false,
        onOpen: @escaping (ScheduledTask) -> Void
    ) {
        _store = State(initialValue: store)
        self.agents = agents
        self.showsInlineHeading = showsInlineHeading
        self.onOpen = onOpen
    }

    var body: some View {
        taskList
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchQuery, prompt: "Search tasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    moreMenu
                    createButton
                }
            }
            .accessibilityIdentifier("scheduled-tasks.screen")
            .task {
                if store.loadState == .idle { await store.load() }
            }
            .refreshable { await store.load() }
            .sheet(item: $createAgent, onDismiss: presentQueuedBlueprints) { agent in
                NavigationStack {
                    ScheduledTaskEditorView(
                        store: store,
                        agent: agent,
                        directory: agents,
                        onBrowseIdeas: {
                            opensBlueprintsAfterEditor = true
                            createAgent = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $isAgentPickerPresented) {
                NavigationStack {
                    AgentSelectionView(
                        title: "Choose an agent",
                        detail: "Who should take care of this task?",
                        agents: agents.profiles,
                        avatarURL: agents.avatarURL(for:)
                    ) { agent in
                        isAgentPickerPresented = false
                        createAgent = agent
                    }
                }
            }
            .sheet(isPresented: $isBlueprintsPresented) {
                NavigationStack {
                    ScheduledTaskBlueprintsView(store: store, agents: agents)
                }
            }
    }

    // MARK: - List

    private var taskList: some View {
        List {
            statusRows
            if let toggleErrorMessage {
                errorRow(toggleErrorMessage) { self.toggleErrorMessage = nil }
            }
            loadedContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
    }

    @ViewBuilder
    private var statusRows: some View {
        switch store.loadState {
        case .loading:
            ProgressView(store.tasks.isEmpty ? "Loading tasks" : "Refreshing tasks")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, LoopdyTokens.space12)
                .listRowBackground(theme.canvas)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(store.tasks.isEmpty ? "scheduled-tasks.loading" : "scheduled-tasks.refreshing")
        case .failed(let message):
            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await store.load() } }
                    .loopdyFont(.label)
                    .foregroundStyle(theme.action)
                    .frame(minHeight: LoopdyTokens.hitTarget)
            }
            .padding(.vertical, LoopdyTokens.space8)
            .listRowBackground(theme.canvas)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("scheduled-tasks.error")
        case .idle, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        let tasks = displayedTasks
        if tasks.isEmpty {
            if store.loadState != .loading || !store.tasks.isEmpty {
                emptyState
            }
        } else {
            let upNext = tasks
                .filter { $0.status == .active || $0.status == .failed }
                .sorted(by: Self.upNextOrder)
            let paused = tasks.filter(\.isPaused)
            let finished = tasks.filter { $0.status == .completed }
            taskSection("Up next", tasks: upNext)
            taskSection("Paused", tasks: paused)
            taskSection("Finished", tasks: finished)
        }
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [ScheduledTask]) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks, id: \.identity) { task in
                    taskRow(task)
                }
            } header: {
                ScheduledTaskSectionCaption(title: title, count: tasks.count)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, LoopdyTokens.space8)
            }
            .listSectionSeparator(.hidden)
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        let profile = agent(id: task.agentID)
        return HStack(spacing: LoopdyTokens.space12) {
            Button { onOpen(task) } label: {
                ScheduledTaskRow(
                    task: task,
                    agent: profile,
                    avatarURL: profile.flatMap(agents.avatarURL(for:)),
                    isRunning: isRunning(task)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens task details")
            trailingControl(task)
        }
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + 44 + LoopdyTokens.space12
        }
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: LoopdyTokens.space16,
            bottom: 0,
            trailing: LoopdyTokens.space16
        ))
        .listRowBackground(theme.canvas)
        .listRowSeparatorTint(theme.separator)
    }

    @ViewBuilder
    private func trailingControl(_ task: ScheduledTask) -> some View {
        let availability = presentation(task).action(.pauseOrResume)
        if store.isPending(task.id, agentID: task.agentID) {
            ProgressView()
                .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
                .accessibilityLabel("Updating \(task.name)")
        } else if task.status == .active || task.status == .paused {
            Toggle(isOn: enabledBinding(task)) {
                Text("Run \(task.name) on schedule")
            }
            .labelsHidden()
            .tint(theme.action)
            .disabled(!availability.isEnabled)
            .frame(minHeight: LoopdyTokens.hitTarget)
            .accessibilityHint(availability.reason ?? (task.isPaused ? "Resumes this task" : "Pauses this task"))
            .accessibilityIdentifier("scheduled-task.row.toggle.\(task.identity.accessibilitySuffix)")
        } else {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
        }
    }

    private func enabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { !task.isPaused },
            set: { enabled in
                toggleErrorMessage = nil
                Task {
                    do {
                        try await store.setPaused(!enabled, id: task.id, agentID: task.agentID)
                    } catch {
                        toggleErrorMessage = store.errorMessage
                            ?? "Couldn’t update \(task.name). Try again."
                    }
                }
            }
        )
    }

    private func errorRow(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .loopdyFont(.metadata)
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.secondaryText)
                .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
        }
        .listRowBackground(theme.canvas)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("scheduled-tasks.toggle-error")
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if searchQuery.isEmpty && store.visibleTasks.isEmpty && store.statusFilter == .all && store.agentFilterID == nil {
            VStack(spacing: LoopdyTokens.space16) {
                emptyAvatar
                VStack(spacing: LoopdyTokens.space8) {
                    Text("Nothing scheduled yet")
                        .loopdyFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                    Text("Ask an agent to check in, summarize, or remind you on a schedule that suits you.")
                        .loopdyFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: startCreate) {
                    Label("New task", systemImage: "plus")
                        .loopdyFont(.label, weight: .semibold)
                        .frame(maxWidth: 280, minHeight: LoopdyTokens.hitTarget)
                }
                .loopdyProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .tint(theme.action)
                .foregroundStyle(theme.actionForeground)
                .accessibilityIdentifier("scheduled-tasks.empty.create")
                Button { isBlueprintsPresented = true } label: {
                    Label("Start from an idea", systemImage: "lightbulb")
                        .loopdyFont(.label)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.action)
                .accessibilityHint("Browse ready-made task ideas")
                .accessibilityIdentifier("scheduled-tasks.empty.ideas")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LoopdyTokens.space40)
            .listRowBackground(theme.canvas)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scheduled-tasks.empty")
        } else {
            ContentUnavailableView(
                "No matching tasks",
                systemImage: "magnifyingglass",
                description: Text(searchQuery.isEmpty
                    ? "No tasks match these filters."
                    : "Try another task, instruction, schedule, or agent name.")
            )
            .listRowBackground(theme.canvas)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("scheduled-tasks.empty")
        }
    }

    @ViewBuilder
    private var emptyAvatar: some View {
        if let agent = agents.resolvedAgent(explicitID: nil) {
            AvatarView(
                stableID: agent.id,
                displayName: agent.name,
                imageURL: agents.avatarURL(for: agent),
                size: 88,
                state: .idle
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(theme.action)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Toolbar

    private var createButton: some View {
        Button(action: startCreate) {
            Image(systemName: "plus").frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
        }
        .accessibilityLabel("New task")
        .accessibilityIdentifier("scheduled-tasks.create")
    }

    /// Ideas and the status/agent filters live here, out of the way.
    private var moreMenu: some View {
        Menu {
            Button("Start from an idea", systemImage: "lightbulb") {
                isBlueprintsPresented = true
            }
            .accessibilityLabel("Browse task ideas")
            .accessibilityIdentifier("scheduled-tasks.blueprints")
            Section("Show") {
                Picker("Status", selection: Bindable(store).statusFilter) {
                    ForEach(ScheduledTaskFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .accessibilityIdentifier("scheduled-tasks.filter.status")
                Picker(selection: Bindable(store).agentFilterID) {
                    Text("All agents").tag(String?.none)
                    ForEach(agents.profiles) { agent in
                        Text(agent.name).tag(String?.some(agent.id))
                    }
                } label: {
                    Label(agentFilterTitle(store.agentFilterID), systemImage: "person.2")
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Agent filter")
                .accessibilityValue(agentFilterTitle(store.agentFilterID))
                .accessibilityIdentifier("scheduled-tasks.filter.agent")
            }
        } label: {
            Image(systemName: isFiltered
                ? "line.3.horizontal.decrease.circle.fill"
                : "ellipsis.circle")
                .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
        }
        .accessibilityLabel("Ideas and filters")
        .accessibilityValue(isFiltered ? "Filtered" : "")
        .accessibilityIdentifier("scheduled-tasks.more")
    }

    private var isFiltered: Bool {
        store.statusFilter != .all || store.agentFilterID != nil
    }

    // MARK: - Helpers

    private func startCreate() {
        if let agent = agents.resolvedAgent(explicitID: nil) {
            createAgent = agent
        } else {
            isAgentPickerPresented = true
        }
    }

    private func presentQueuedBlueprints() {
        guard opensBlueprintsAfterEditor else { return }
        opensBlueprintsAfterEditor = false
        isBlueprintsPresented = true
    }

    private func agent(id: String) -> AgentProfile? {
        agents.profiles.first(where: { $0.id == id })
    }

    private func presentation(_ task: ScheduledTask) -> ScheduledTaskPresentation {
        ScheduledTaskPresentation(task: task, agentName: agent(id: task.agentID)?.name)
    }

    /// Only true when loaded run history reports an active run.
    private func isRunning(_ task: ScheduledTask) -> Bool {
        store.runs(for: task).contains(where: \.isActive)
    }

    private var displayedTasks: [ScheduledTask] {
        let terms = searchQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return store.visibleTasks }
        return store.visibleTasks.filter { task in
            let fields = [
                task.name,
                task.instructions,
                task.scheduleDescription,
                task.deliveryTarget,
                agent(id: task.agentID)?.name ?? ""
            ]
            return terms.allSatisfy { term in
                fields.contains { $0.localizedStandardContains(term) }
            }
        }
    }

    private static func upNextOrder(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        switch (lhs.nextRun, rhs.nextRun) {
        case let (left?, right?): left < right
        case (.some, .none): true
        case (.none, .some): false
        case (.none, .none): lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func agentFilterTitle(_ id: String?) -> String {
        guard let id else { return "All agents" }
        return agent(id: id)?.name ?? "Unavailable agent"
    }

    @LoopdyThemeReader private var theme
}
