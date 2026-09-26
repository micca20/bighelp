import Foundation
import Observation
import WidgetKit

/// Mirrors the live native workspace into the App Group snapshot the Home
/// Screen and Lock Screen widgets read. Observation-driven and coalesced so a
/// streaming turn does not reload widget timelines on every token.
@MainActor
final class LoopdyWidgetSnapshotPublisher {
    private weak var sessions: SessionCatalogStore?
    private weak var scheduledTasks: ScheduledTasksStore?
    private weak var agents: AgentDirectoryStore?
    private var pending: Task<Void, Never>?
    private var lastPublished: LoopdyWidgetSnapshot?
    private var retired = false
    private let interval: Duration
    private let write: (LoopdyWidgetSnapshot) -> Void

    init(sessions: SessionCatalogStore, scheduledTasks: ScheduledTasksStore, agents: AgentDirectoryStore,
         interval: Duration = .seconds(2),
         write: @escaping (LoopdyWidgetSnapshot) -> Void = LoopdyWidgetSnapshotPublisher.persist) {
        self.sessions = sessions; self.scheduledTasks = scheduledTasks; self.agents = agents
        self.interval = interval; self.write = write
        observe()
    }

    func retire() {
        retired = true
        pending?.cancel(); pending = nil
        // A signed-out or switched host must not leave its chats on the Home Screen.
        write(.empty)
    }

    private func observe() {
        guard !retired else { return }
        withObservationTracking { _ = makeSnapshot() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    private func changed() {
        guard !retired else { return }
        observe()
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled, !self.retired else { return }
            self.pending = nil
            self.publishNow()
        }
    }

    func publishNow() {
        guard !retired else { return }
        var snapshot = makeSnapshot()
        if var previous = lastPublished {
            previous.generatedAt = snapshot.generatedAt
            guard previous != snapshot else { return }
        }
        snapshot.generatedAt = .now
        lastPublished = snapshot
        write(snapshot)
    }

    func makeSnapshot() -> LoopdyWidgetSnapshot {
        let profiles = agents?.profiles ?? []
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let defaultAgent = agents?.resolvedAgent(explicitID: nil) ?? profiles.first
        let records = (sessions?.presentedRecords ?? [])
            .filter { $0.parentSessionID == nil && ($0.hasAcceptedMessage || $0.hasActiveWork) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12)
        let sessionRows = records.map { record -> LoopdyWidgetSnapshot.Session in
            let agentName = record.agentIDs.first.flatMap { names[$0] } ?? defaultAgent?.name ?? "Agent"
            let running = record.hasActiveWork
            return .init(id: record.id, title: Self.clip(record.title, 60) ?? "Chat", agentName: agentName,
                         status: running ? Self.status(for: record) : "Replied",
                         preview: Self.clip(Self.preview(for: record), 140),
                         isRunning: running, updatedAt: record.updatedAt,
                         agentID: record.agentIDs.first,
                         activity: running ? Self.activity(for: record) : nil)
        }
        let taskRows = (scheduledTasks?.tasks ?? [])
            .filter { $0.status == .active }
            .prefix(12)
            .map { task in
                LoopdyWidgetSnapshot.Task(id: task.id, name: Self.clip(task.name, 60) ?? "Task",
                    agentName: names[task.agentID] ?? "Agent", schedule: Self.clip(task.scheduleDescription, 60) ?? "",
                    nextRun: task.nextRun, lastResult: Self.clip(task.lastResult, 100))
            }
        let extras = LoopdyWidgetExtras.shared
        return LoopdyWidgetSnapshot(defaultAgentID: defaultAgent?.id, defaultAgentName: defaultAgent?.name,
                                    sessions: Array(sessionRows), tasks: Array(taskRows), generatedAt: .now,
                                    feed: extras.feed, goals: extras.goals,
                                    lightPalette: extras.lightPalette, darkPalette: extras.darkPalette)
    }

    private static func status(for record: SessionRecord) -> String {
        if let count = record.sessionSubagents?.subagents.count, count > 0 {
            return count == 1 ? "1 subagent working" : "\(count) subagents working"
        }
        if let last = record.activityEvents.last, !last.lifecycle.isTerminal {
            let title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return clip(title, 60) ?? "Working" }
        }
        return "Working"
    }

    /// A fixed category for the widget's activity icon, never the tool's text.
    private static func activity(for record: SessionRecord) -> String {
        guard let last = record.activityEvents.last, !last.lifecycle.isTerminal else {
            return LoopdyActivityPose.thinking.rawValue
        }
        if last.kind == .subagent { return LoopdyActivityPose.delegating.rawValue }
        return LoopdyActivityPose(tool: last.toolName ?? last.title).rawValue
    }

    private static func preview(for record: SessionRecord) -> String? {
        for item in record.items.reversed() where item.role == .assistant {
            if case .message(let text) = item.content {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            }
        }
        return record.catalogPreview
    }

    private static func clip(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }

    nonisolated static func persist(_ snapshot: LoopdyWidgetSnapshot) {
        do { try snapshot.save() } catch { return }
        for kind in LoopdyWidgetSnapshot.widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
