import Foundation
import WidgetKit

/// Keeps the Kanban widget's snapshot current. The board on screen replaces
/// its own cards; the other boards keep what was last seen, and a refresh
/// reads every board when the app connects.
@MainActor
enum KanbanWidgetPublisher {
    private static var pending: Task<Void, Never>?
    private static var lastRefreshAll: Date?

    static func record(_ model: KanbanBoardModel) {
        guard let board = model.snapshot else { return }
        var snapshot = BighelpKanbanSnapshot.load()
        snapshot = merged(snapshot, boards: model.boards, board: board, agents: model.assignableAgents)
        write(snapshot)
    }

    /// Reads every board (at most eight) so a widget set to another board isn't
    /// stale. At most once every ten minutes, and never in demo mode.
    static func refreshAll(service: KanbanService, agents: [KanbanAgent], force: Bool = false) async {
        if !force, let last = lastRefreshAll, Date.now.timeIntervalSince(last) < 600 { return }
        lastRefreshAll = .now
        guard (try? await service.isAvailable()) == true, let boards = try? await service.boards() else { return }
        var snapshot = BighelpKanbanSnapshot.load()
        for board in boards.prefix(8) {
            guard let value = try? await service.board(board.slug) else { continue }
            snapshot = merged(snapshot, boards: boards, board: value, agents: agents)
        }
        write(snapshot)
    }

    /// A signed-out or switched host must not leave its tasks on the Home Screen.
    static func clear() {
        write(.empty)
    }

    static func merged(_ current: BighelpKanbanSnapshot, boards: [HermesKanbanBoard],
                       board: HermesKanbanBoardSnapshot, agents: [KanbanAgent]) -> BighelpKanbanSnapshot {
        var snapshot = current
        let known = Set(boards.map(\.slug))
        snapshot.boards = boards.filter { !$0.isArchived }.map {
            .init(id: $0.slug, name: $0.name, colorHex: $0.color)
        }
        var agentsByID = Dictionary(snapshot.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for agent in agents { agentsByID[agent.id] = .init(id: agent.id, name: agent.name) }
        snapshot.agents = agentsByID.values.sorted { $0.name < $1.name }
        let slug = board.board.slug
        let recentDone = board.tasks.filter { $0.status == .done }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }.prefix(12)
        let cards = board.tasks.filter { $0.status != .done && $0.lane != nil } + recentDone
        snapshot.cards = snapshot.cards.filter { $0.board != slug && known.contains($0.board) }
            + cards.compactMap { task in
                guard let lane = task.lane else { return nil }
                return .init(id: task.id, board: slug, title: String(task.title.prefix(160)), lane: lane,
                             note: task.statusNote, assignee: task.assignee, priority: task.priority,
                             updatedAt: task.completedAt ?? task.lastHeartbeatAt ?? task.startedAt ?? task.createdAt)
            }
        snapshot.cards = Array(snapshot.cards.prefix(BighelpKanbanSnapshot.maximumCards))
        snapshot.generatedAt = .now
        return snapshot
    }

    private static func write(_ snapshot: BighelpKanbanSnapshot) {
        var previous = BighelpKanbanSnapshot.load()
        previous.generatedAt = snapshot.generatedAt
        guard previous != snapshot else { return }
        try? snapshot.save()
        // Coalesce bursts of live updates into one widget reload.
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: BighelpKanbanSnapshot.kind)
        }
    }
}
