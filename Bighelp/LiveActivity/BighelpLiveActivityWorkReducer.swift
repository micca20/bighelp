import Foundation

/// A roster coordinate, never a display title. Keep the ORIGINAL parent turn.
struct BighelpLiveActivityChild: Hashable, Sendable {
    enum Identity: Hashable, Sendable {
        case subagent(String)
        case botHandoff(runID: String, memberID: String)
    }
    let turnID: String
    let identity: Identity
}

/// Private-to-module owner state. It is deliberately NOT part of rich v1 JSON.
/// Capacity exhaustion fails closed: no eviction of live ownership/tombstones.
struct BighelpLiveActivityWorkReducer {
    private enum Unit: Hashable {
        case tool(String)
        case child(BighelpLiveActivityChild.Identity)
        case reasoning(String)
    }
    private struct Turn {
        var units: [Unit: ChatActivityLifecycle] = [:]
        var completedUnits: Set<Unit> = []
        var outcome: BighelpLiveActivityOutcome?
    }
    private var turns: [String: Turn] = [:]
    private(set) var currentTurnID: String?
    private var newestTurnTimestamp = 0
    private var latestObservationTimestamp = 0
    private var unresolvedChildCount: Int
    private var completedSteps = 0
    private var unitCount = 0
    private var capacityExceeded = false
    private var hasReplacedTurn = false
    private static let maximumTurns = 64
    private static let maximumUnits = 2_048

    init(restoredChildCount: Int = 0) {
        unresolvedChildCount = min(max(restoredChildCount, 0), 99)
    }

    var turnIDs: Set<String> { Set(turns.keys) }
    var isCurrentParentActive: Bool {
        guard let currentTurnID, let turn = turns[currentTurnID] else { return false }
        return turn.outcome == nil
    }
    /// A legacy session-only final is accepted only before any turn replacement.
    /// Missing correlation is never retroactively claimed to be exact.
    var legacyFinishTurnID: String? { hasReplacedTurn ? nil : currentTurnID }

    private var activeChildCount: Int {
        let known = turns.values.reduce(0) { count, turn in
            count + turn.units.filter { unit, lifecycle in
                if case .child = unit { return lifecycle == .running }
                return false
            }.count
        }
        // Restored v1 carries a count, not identities. It may overlap newly
        // observed children; retain it as a floor until authoritative readback
        // rather than inventing a disjoint cohort by adding the two counts.
        return min(99, max(known, unresolvedChildCount))
    }

    mutating func accept(_ event: ChatActivityEvent) -> Bool {
        guard event.lifecycle != .recorded,
              Self.isBoundedID(event.turnID), Self.isBoundedID(event.eventID) else { return false }
        let unit: Unit?
        switch event.kind {
        case .reasoning: unit = .reasoning(event.eventID)
        case .tool: unit = event.toolCallID.flatMap { $0.isEmpty ? nil : .tool($0) }
        case .subagent:
            unit = event.subagentID.flatMap { $0.isEmpty ? nil : .child(.subagent($0)) }
        case .botHandoff:
            if let run = event.botRunID, !run.isEmpty, let member = event.memberID, !member.isEmpty {
                unit = .child(.botHandoff(runID: run, memberID: member))
            } else {
                unit = nil
            }
        }
        guard let unit, Self.isValid(unit) else { return false }
        if turns[event.turnID] == nil {
            guard !event.lifecycle.isTerminal,
                  event.occurredAt >= latestObservationTimestamp else { return false }
            guard turns.count < Self.maximumTurns else {
                capacityExceeded = true
                return false
            }
            if currentTurnID != nil { hasReplacedTurn = true }
            currentTurnID = event.turnID
            newestTurnTimestamp = max(newestTurnTimestamp, event.occurredAt)
            turns[event.turnID] = Turn()
        }
        guard var turn = turns[event.turnID] else { return false }
        let prior = turn.units[unit]
        // Unknown stops do not change any count. Completed units cannot restart
        // from repeated start rows, even if their replay timestamp is newer.
        if prior?.isTerminal == true || prior == event.lifecycle { return false }
        if prior == nil {
            guard !event.lifecycle.isTerminal, turn.outcome == nil else { return false }
            guard unitCount < Self.maximumUnits else {
                capacityExceeded = true
                return false
            }
            unitCount += 1
        }
        if prior == .running && event.lifecycle == .succeeded {
            switch unit {
            case .tool, .child:
                if turn.completedUnits.insert(unit).inserted {
                    completedSteps = min(999, completedSteps + 1)
                }
            case .reasoning: break
            }
        }
        turn.units[unit] = event.lifecycle
        turns[event.turnID] = turn
        latestObservationTimestamp = max(latestObservationTimestamp, event.occurredAt)
        return true
    }

    mutating func finish(turnID: String, outcome: BighelpLiveActivityOutcome) -> Bool {
        guard var turn = turns[turnID], turn.outcome == nil else { return false }
        turn.outcome = outcome
        turns[turnID] = turn
        return true
    }

    /// Atomic CURRENT roster readback, not a delta or a persisted start list.
    /// Unknown restored counts are replaced only by this authoritative input.
    /// Returns false without changing anything if input exceeds the owner budget.
    mutating func reconcile(
        turnID: String,
        children: Set<BighelpLiveActivityChild>,
        timestamp: Int
    ) -> Bool {
        guard Self.isBoundedID(turnID), children.count <= 99,
              timestamp >= latestObservationTimestamp,
              children.allSatisfy({ Self.isBoundedID($0.turnID) && Self.isValid($0.identity) }) else { return false }
        let allTurns = Set(children.map(\.turnID)).union([turnID]).union(turns.keys)
        guard allTurns.count <= Self.maximumTurns else { return false }
        // A current snapshot may recover a restored activity but must not roll
        // an already known newer turn back to an older cohort.
        if let currentTurnID, currentTurnID != turnID {
            guard turns[turnID] == nil, timestamp >= newestTurnTimestamp else { return false }
        }
        var candidate = self
        if candidate.currentTurnID != nil && candidate.currentTurnID != turnID {
            candidate.hasReplacedTurn = true
        }
        candidate.currentTurnID = turnID
        candidate.newestTurnTimestamp = max(newestTurnTimestamp, timestamp)
        candidate.latestObservationTimestamp = max(latestObservationTimestamp, timestamp)
        for id in allTurns where candidate.turns[id] == nil { candidate.turns[id] = Turn() }
        for id in Array(candidate.turns.keys) {
            guard var turn = candidate.turns[id] else { continue }
            for (unit, lifecycle) in turn.units where lifecycle == .running {
                if case let .child(identity) = unit,
                   !children.contains(BighelpLiveActivityChild(turnID: id, identity: identity)) {
                    // Removal establishes only 'not running', not successful work.
                    turn.units[unit] = .cancelled
                }
            }
            candidate.turns[id] = turn
        }
        for child in children {
            let unit = Unit.child(child.identity)
            if candidate.turns[child.turnID]?.units[unit] == nil { candidate.unitCount += 1 }
            candidate.turns[child.turnID]?.units[unit] = .running
        }
        guard candidate.unitCount <= Self.maximumUnits else { return false }
        candidate.unresolvedChildCount = 0
        self = candidate
        return true
    }

    func project(
        previous: LoopdySessionActivityAttributes.ContentState,
        event: ChatActivityEvent? = nil,
        agentName: String,
        timestamp: Int
    ) -> LoopdySessionActivityAttributes.ContentState {
        let state: LoopdySessionActivityAttributes.ContentState
        if let event, event.turnID == currentTurnID, event.occurredAt >= previous.timestamp,
           !(previous.phase == .waiting && (event.kind == .subagent || event.kind == .botHandoff)) {
            state = BighelpLiveActivityProjection.apply(event, to: previous, agentName: agentName)
        } else {
            state = previous
        }
        // An uncorrelated restored count is not fresh roster evidence. Keep
        // ActivityKit's stale clock until reconcile installs exact membership.
        let observationTimestamp = unresolvedChildCount > 0 || capacityExceeded ? previous.timestamp : timestamp
        let counted = LoopdySessionActivityAttributes.ContentState(
            phase: state.phase.isTerminal ? .thinking : state.phase,
            currentAction: state.currentAction,
            progress: 0,
            completedSteps: completedSteps,
            activeSubagentCount: activeChildCount,
            latestTool: nil,
            timestamp: max(previous.timestamp, max(1, observationTimestamp))
        )
        if let currentTurnID, let outcome = turns[currentTurnID]?.outcome,
           !capacityExceeded {
            return BighelpLiveActivityProjection.final(previous: counted, outcome: outcome, timestamp: observationTimestamp)
        }
        return counted
    }

    private static func isValid(_ identity: BighelpLiveActivityChild.Identity) -> Bool {
        switch identity {
        case let .subagent(id): isBoundedID(id)
        case let .botHandoff(run, member): isBoundedID(run) && isBoundedID(member)
        }
    }

    private static func isValid(_ unit: Unit) -> Bool {
        switch unit {
        case let .tool(id), let .reasoning(id): isBoundedID(id)
        case let .child(identity): isValid(identity)
        }
    }

    private static func isBoundedID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512
    }
}
