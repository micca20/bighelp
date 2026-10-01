import SwiftUI

@MainActor
struct ScheduledTaskRunsView: View {
    @State private var store: ScheduledTasksStore
    let task: ScheduledTask
    let onOpenSession: ((String) -> Void)?

    init(
        store: ScheduledTasksStore,
        task: ScheduledTask,
        onOpenSession: ((String) -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.task = task
        self.onOpenSession = onOpenSession
    }

    var body: some View {
        nativeSection
        .task(id: task.identity) {
            await store.loadRuns(id: task.id, agentID: task.agentID)
        }
    }

    private var nativeSection: some View {
        Section {
            switch store.runsLoadState(for: task) {
            case .idle, .loading where runs.isEmpty:
                ProgressView("Loading recent runs")
                    .accessibilityIdentifier("scheduled-task.runs.loading")
            case .failed(let message) where runs.isEmpty:
                error(message)
            default:
                if runs.isEmpty {
                    HStack(spacing: BighelpTokens.space12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(theme.tertiaryText)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No runs yet")
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Text("Each time this task runs, it shows up here.")
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("scheduled-task.runs.empty")
                } else {
                    ForEach(runs) { run in
                        runRow(run)
                    }
                    if case .failed(let message) = store.runsLoadState(for: task) {
                        error(message)
                    }
                }
            }
        } header: {
            ScheduledTaskSectionCaption(title: "Recent runs", count: runs.isEmpty ? nil : runs.count)
        }
        .listRowBackground(theme.surface)
        .accessibilityIdentifier("scheduled-task.runs.list")
    }

    private var runs: [ScheduledTaskRun] { store.runs(for: task) }

    @ViewBuilder
    private func runRow(_ run: ScheduledTaskRun) -> some View {
        if let onOpenSession {
            Button { onOpenSession(run.id) } label: { rowLabel(run) }
                .buttonStyle(.plain)
                .accessibilityHint("Open this run's saved conversation")
        } else {
            rowLabel(run)
        }
    }

    private func rowLabel(_ run: ScheduledTaskRun) -> some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            Image(systemName: statusSymbol(run))
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(statusColor(run))
                .frame(width: 28, height: 28)
                .background(statusColor(run).opacity(0.12), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.displayTitle)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                Text("\(statusTitle(run)) · \(ScheduledTaskCopy.shortDate(run.lastActiveAt))")
                    .bighelpFont(.metadata)
                    .foregroundStyle(run.isActive ? theme.action : theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onOpenSession != nil {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.displayTitle), \(run.isActive ? "running" : "completed"), \(run.lastActiveAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityIdentifier("scheduled-task.run.\(run.id)")
    }

    private func statusTitle(_ run: ScheduledTaskRun) -> String {
        run.isActive ? "Running" : run.endedAt == nil ? "Stopped" : "Completed"
    }

    private func statusSymbol(_ run: ScheduledTaskRun) -> String {
        run.isActive ? "bolt.fill" : run.endedAt == nil ? "stop.fill" : "checkmark"
    }

    private func statusColor(_ run: ScheduledTaskRun) -> Color {
        run.isActive ? theme.action : run.endedAt == nil ? theme.secondaryText : theme.success
    }

    private func error(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry run history") {
                Task { await store.loadRuns(id: task.id, agentID: task.agentID) }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
        }
        .accessibilityIdentifier("scheduled-task.runs.error")
    }

    @BighelpThemeReader private var theme
}
