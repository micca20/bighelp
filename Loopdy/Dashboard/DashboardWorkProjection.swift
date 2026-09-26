import Foundation

struct DashboardWorkItem: Identifiable, Equatable, Sendable {
    let sessionID: String
    let title: String
    let subtitle: String
    var id: String { sessionID }
}

/// A presentation of authenticated stores, never another execution lifecycle.
enum DashboardWorkProjection {
    static func session(
        resolving sessionID: String?, agentID: String?, in sessions: [SessionRecord]
    ) -> SessionRecord? {
        guard let sessionID else { return nil }
        let matches = sessions.filter {
            ($0.id == sessionID || $0.remoteStoredID == sessionID)
                && (agentID.map($0.agentIDs.contains) ?? true)
        }
        // Legacy events without a profile may resolve only an unambiguous ID.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func isActionable(_ item: DashboardAttentionItem, at now: Date) -> Bool {
        switch item.interaction {
        case .clarification(let request): !request.isExpired(at: now)
        case .approval(let request): !request.isExpired(at: now)
        case .none: true
        }
    }

    static func workInFlightItems(
        sessions: [SessionRecord], attentionItems: [DashboardAttentionItem], now: Date,
        activeSubagentSessionIDs: Set<String> = []
    ) -> [DashboardWorkItem] {
        let blocked = blockedSessionIDs(sessions: sessions, attentionItems: attentionItems, now: now)
        // Creation coordinates are stable while activity and updatedAt change.
        return sessions.filter { $0.hasActiveWork && !blocked.contains($0.id) }
            .sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
            .map {
                DashboardWorkItem(
                    sessionID: $0.id,
                    title: meaningfulTitle($0.title) ?? ($0.isSubagentSession ? "Subagent task" : "Conversation"),
                    subtitle: subtitle(for: $0, hasActiveSubagents: activeSubagentSessionIDs.contains($0.id))
                )
            }
    }

    static func subtitle(for session: SessionRecord, hasActiveSubagents: Bool = false) -> String {
        let delegated = session.sessionSubagents.map { !$0.subagents.isEmpty } ?? hasActiveSubagents
        if !session.isActive && delegated { return "Calling subagents" }
        let boundary = session.items.last(where: {
            $0.role == .human || ($0.role == .assistant && $0.metadata.delivery != "Streaming")
        })?.metadata.timestamp
        let events = session.activityEvents.filter { event in
            (event.sessionID == session.id || event.sessionID == session.remoteStoredID)
                && (boundary.map { boundary in
                    activityDate(for: event).timeIntervalSince1970 >= boundary.timeIntervalSince1970.rounded(.down)
                } ?? true)
        }
        let newest = events.max(by: activityOrder)
        let running = events.filter { $0.turnID == newest?.turnID && $0.lifecycle == .running }
            .max(by: activityOrder)
        let streamingIsNewest = running.map { event in
            session.items.last?.metadata.timestamp.map {
                $0 >= activityDate(for: event)
            } ?? false
        } ?? true
        if let tail = session.items.last, tail.role == .assistant,
           tail.metadata.delivery == "Streaming", streamingIsNewest {
            return "Drafting a reply"
        }
        guard let running else { return delegated ? "Calling subagents" : "Working" }
        // A newer terminal activity must not reveal an older running reasoning
        // placeholder from the same turn.
        if running.kind == .reasoning, let newest, activityOrder(running, newest) {
            return "Working"
        }
        return switch running.kind {
        case .reasoning: "Reasoning"
        case .tool: "Making tool calls"
        case .subagent, .botHandoff: "Calling subagents"
        }
    }

    static func presentedCompletedItems(
        _ items: [DashboardCompletion], sessions: [SessionRecord],
        attentionItems: [DashboardAttentionItem], scheduledTasks: [ScheduledTask] = [], now: Date
    ) -> [DashboardCompletion] {
        let blocked = blockedSessionIDs(sessions: sessions, attentionItems: attentionItems, now: now)
        var seen = Set<CompletionIdentity>()
        return items.sorted {
            $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt > $1.completedAt
        }.compactMap { item in
            guard DashboardEventIntentPolicy.isCompletedLifecycle(item.status) || item.status == "completed" else {
                return nil
            }
            let targetID = item.childSessionID ?? item.sessionID
            let owner = session(resolving: targetID, agentID: item.agentID, in: sessions)
            // Home places a conversation in its current section. Host turn IDs
            // and activity wire IDs are different coordinates, not comparable.
            if let owner, owner.hasActiveWork || blocked.contains(owner.id) { return nil }
            let identity = CompletionIdentity(
                agentID: item.agentID, sessionID: owner?.id ?? targetID,
                kind: targetID == nil ? item.status : "session",
                runID: item.turnID ?? item.delegationID,
                jobID: item.jobID, taskID: item.taskID,
                // Older hosts lack run coordinates: retain separate executions
                // by their exact completion time, not merely the reusable job ID.
                legacyDate: item.turnID == nil && item.delegationID == nil ? item.completedAt : nil,
                fallbackID: targetID == nil && item.jobID == nil && item.taskID == nil ? item.id : nil
            )
            guard seen.insert(identity).inserted else { return nil }
            let title: String
            if item.status == "job.completed" {
                let tasks = scheduledTasks.filter {
                    ($0.id == item.taskID || $0.id == item.jobID)
                        && (item.agentID == nil || $0.agentID == item.agentID)
                }
                title = (tasks.count == 1 ? meaningfulTitle(tasks[0].name) : nil)
                    ?? meaningfulTitle(item.title) ?? "Scheduled task"
            } else {
                title = owner.flatMap { meaningfulTitle($0.title) }
                    ?? meaningfulTitle(item.title)
                    ?? (item.status == "delegation.completed" ? "Subagent task" : "Conversation")
            }
            return item.presented(title: title, sessionID: owner?.id ?? targetID)
        }
    }

    static func meaningfulTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let generic = ["leaf", "worker", "subagent", "subagent task", "conversation", "agent", "session completed", "delegation completed", "job completed", "scheduled task completed"]
        guard !text.isEmpty, !text.lowercased().hasPrefix("sub_"),
              !generic.contains(text.lowercased()) else { return nil }
        return String(text.prefix(160))
    }

    static func activityDate(for event: ChatActivityEvent) -> Date {
        // Hermes activity hooks use Unix seconds. Local Bot Mode handoffs use
        // milliseconds; retain that existing producer contract at presentation.
        let seconds = event.occurredAt >= 100_000_000_000
            ? Double(event.occurredAt) / 1_000 : Double(event.occurredAt)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func activityOrder(_ lhs: ChatActivityEvent, _ rhs: ChatActivityEvent) -> Bool {
        let leftDate = activityDate(for: lhs)
        let rightDate = activityDate(for: rhs)
        if leftDate != rightDate { return leftDate < rightDate }
        if lhs.sourceOrder != rhs.sourceOrder { return (lhs.sourceOrder ?? 0) < (rhs.sourceOrder ?? 0) }
        return lhs.id < rhs.id
    }

    private static func blockedSessionIDs(
        sessions: [SessionRecord], attentionItems: [DashboardAttentionItem], now: Date
    ) -> Set<String> {
        Set(attentionItems.filter { isActionable($0, at: now) }.compactMap {
            session(resolving: $0.owningSessionID, agentID: $0.agentID, in: sessions)?.id
        })
    }

    private struct CompletionIdentity: Hashable {
        let agentID: String?
        let sessionID: String?
        let kind: String
        let runID: String?
        let jobID: String?
        let taskID: String?
        let legacyDate: Date?
        let fallbackID: String?
    }
}
