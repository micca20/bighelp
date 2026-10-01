import Foundation

/// Hermes has nine statuses; the five lanes (`KanbanLane`, shared with the
/// widget) fold them into what matters: what's waiting, what an agent can pick
/// up, what's being worked on, what needs you, and what's finished.
extension KanbanLane {
    var statuses: Set<HermesKanbanTaskStatus> {
        switch self {
        case .later: [.triage, .todo, .scheduled]
        case .ready: [.ready]
        case .working: [.running]
        case .needsYou: [.blocked, .review]
        case .done: [.done]
        }
    }

    init?(status: HermesKanbanTaskStatus) {
        guard let lane = Self.allCases.first(where: { $0.statuses.contains(status) }) else { return nil }
        self = lane
    }

    /// The status a card gets when it's dropped here. Only Hermes' dispatcher
    /// starts work, so nothing can be dropped into Working.
    var dropStatus: HermesKanbanTaskStatus? {
        switch self {
        case .later: .todo
        case .ready: .ready
        case .working: nil
        case .needsYou: .blocked
        case .done: .done
        }
    }

    func accepts(_ task: HermesKanbanTask) -> Bool {
        guard let status = dropStatus else { return false }
        return !statuses.contains(task.status) && task.status != status
    }
}

extension HermesKanbanTask {
    var lane: KanbanLane? { KanbanLane(status: status) }

    /// The small status note on a card, when the lane alone doesn't say enough.
    var statusNote: String? {
        switch status {
        case .triage: "Planning"
        case .scheduled: "Scheduled"
        case .blocked:
            switch blockKind {
            case "needs_input": "Has a question"
            case "gave_up", "crashed", "timed_out": "Got stuck"
            case "dependency": "Waiting on another task"
            default: "On hold"
            }
        case .review: "Ready for review"
        default: nil
        }
    }

    var urgency: KanbanPriority { KanbanPriority(priority) }

    /// Stuck work: a retry makes sense, not a reply.
    var gotStuck: Bool { status == .blocked && ["gave_up", "crashed", "timed_out"].contains(blockKind ?? "") }
}

/// Hermes priorities are open-ended integers; higher runs first. People pick
/// from four, and anything above or below reads as the nearest end.
enum KanbanPriority: Int, CaseIterable, Identifiable, Sendable {
    case low = -1, normal = 0, high = 1, urgent = 2

    var id: Int { rawValue }

    init(_ value: Int) {
        self = value <= -1 ? .low : value >= 2 ? .urgent : value == 1 ? .high : .normal
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }
}
