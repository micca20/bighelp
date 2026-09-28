import SwiftUI

/// A display-only fold of one turn's reasoning and tool calls. The canonical
/// transcript and message identities stay intact.
struct ChatCompletedTurn: Identifiable {
    let id: String
    /// The folded activity entries, in order.
    let entries: [ChatTranscriptEntry]
    let elapsedSeconds: TimeInterval?

    /// All folded work as one activity turn, so reasoning on either side of an
    /// interim message still reads as one run inside the fold.
    @MainActor var mergedActivity: ChatTranscriptEntry? {
        let turns = entries.compactMap { entry -> ChatActivityTurn? in
            guard case .activity(let turn) = entry else { return nil }
            return turn
        }
        guard let first = turns.first else { return nil }
        return .activity(ChatActivityTurn(id: first.id, events: turns.flatMap(\.events)))
    }

    var label: String {
        guard let elapsedSeconds, elapsedSeconds.isFinite,
              elapsedSeconds >= 0, elapsedSeconds < 31_536_000 else {
            return "Completed turn · duration unavailable"
        }
        let seconds = Int(elapsedSeconds.rounded())
        if seconds < 1 { return "Worked for less than a second" }
        if seconds < 60 { return "Worked for \(seconds)s" }
        if seconds < 3_600 { return "Worked for \(seconds / 60)m \(seconds % 60)s" }
        return "Worked for \(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}

enum ChatTurnDisplayRow: Identifiable {
    case entry(ChatTranscriptEntry)
    case completed(ChatCompletedTurn)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .completed(let turn): turn.id
        }
    }
}

@MainActor
enum ChatCompletedTurnProjection {
    static func rows(
        from entries: [ChatTranscriptEntry],
        isSending: Bool,
        enabled: Bool,
        activityEvents: [ChatActivityEvent] = []
    ) -> [ChatTurnDisplayRow] {
        // Incremental activity updates can leave a terminal reasoning marker
        // in the cached transcript after its content has been settled away.
        // Reapply the canonical presentation predicate here so that marker
        // cannot become a trailing continuation fold.
        let presentableEntries = entries.compactMap { entry -> ChatTranscriptEntry? in
            switch entry {
            case .message:
                return entry
            case .activity(let turn):
                let events = turn.events.filter(\.isPresentable)
                guard !events.isEmpty else { return nil }
                return .activity(ChatActivityTurn(id: turn.id, events: events))
            }
        }
        guard enabled else { return presentableEntries.map(ChatTurnDisplayRow.entry) }
        var rows: [ChatTurnDisplayRow] = []
        var work: [ChatTranscriptEntry] = []
        var startedAt: Date?
        var startOrder: Int?

        func flush(isActive: Bool, endOrder: Int? = nil) {
            defer { work.removeAll(keepingCapacity: true) }
            let hasUnsettledContent = work.contains { entry in
                switch entry {
                case .message(let item): item.metadata.delivery == "Streaming"
                case .activity(let turn): turn.events.contains { $0.lifecycle == .running }
                }
            }
            guard !isActive, !hasUnsettledContent, !work.isEmpty else {
                rows.append(contentsOf: work.map(ChatTurnDisplayRow.entry))
                return
            }
            // Assistant text has no trustworthy "disposable progress" marker.
            // A reply before clarify or verification can be the useful answer,
            // so every message stays visible, in order. All of the turn's
            // reasoning and tool calls go into one fold, in order, placed where
            // the work began.
            var folded: [ChatTranscriptEntry] = []
            var turnRows: [ChatTurnDisplayRow] = []
            var foldPosition: Int?
            for entry in work {
                switch entry {
                case .activity(let turn):
                    // Generated output is conversation content. Folding its
                    // completed tool would hide the image exactly when the
                    // animation is replaced, including after a reopen.
                    if turn.events.contains(where: { GeneratedMediaProjection.kind(for: $0) != nil }) {
                        turnRows.append(.entry(entry))
                    } else {
                        if foldPosition == nil { foldPosition = turnRows.count }
                        folded.append(entry)
                    }
                case .message:
                    turnRows.append(.entry(entry))
                }
            }
            if let foldPosition, let first = folded.first {
                turnRows.insert(.completed(ChatCompletedTurn(
                    id: "completed-turn:\(first.id)",
                    entries: folded,
                    elapsedSeconds: elapsed(work, startedAt: startedAt, startOrder: startOrder,
                                            endOrder: endOrder, activityEvents: activityEvents)
                )), at: foldPosition)
            }
            rows.append(contentsOf: turnRows)
        }

        for entry in presentableEntries {
            if case .message(let item) = entry, item.role == .human {
                flush(isActive: false, endOrder: item.metadata.sourceOrder)
                rows.append(.entry(entry))
                startedAt = item.metadata.timestamp
                startOrder = item.metadata.sourceOrder
            } else {
                work.append(entry)
            }
        }
        // Never fold the turn being delivered, including gaps between batches.
        flush(isActive: isSending)
        return rows
    }

    private static func elapsed(
        _ entries: [ChatTranscriptEntry], startedAt: Date?, startOrder: Int?,
        endOrder: Int?, activityEvents: [ChatActivityEvent]
    ) -> TimeInterval? {
        let messages = entries.compactMap { entry -> TimelineItem? in
            guard case .message(let item) = entry else { return nil }
            return item
        }
        // A recorded completion always wins over transport or restored row time.
        if let duration = messages.compactMap(\.metadata.turnDurationMilliseconds)
            .filter({ (0...86_400_000).contains($0) }).max() {
            return TimeInterval(duration) / 1_000
        }
        let turnIDs = Set(entries.flatMap { entry -> [String] in
            guard case .activity(let turn) = entry else { return [] }
            return turn.events.map(\.turnID)
        })
        let durations = activityEvents.compactMap { event -> Int? in
            guard event.kind == .reasoning, event.lifecycle != .running,
                  let duration = event.durationMilliseconds,
                  (0...86_400_000).contains(duration) else { return nil }
            let inTurn = turnIDs.contains(event.turnID)
            let inOrder: Bool
            if let startOrder, let order = event.sourceOrder {
                inOrder = order >= startOrder && endOrder.map { order < $0 } != false
            } else {
                inOrder = false
            }
            return inTurn || inOrder ? duration : nil
        }
        if let duration = durations.max() { return TimeInterval(duration) / 1_000 }
        // Older hosts have no measured duration. Use only persisted human/final
        // message timestamps, never synthetic activity order or the render clock.
        guard let start = startedAt,
              let final = messages.last(where: { $0.role == .assistant && $0.metadata.delivery != "Streaming" }),
              let end = final.metadata.timestamp, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}

@MainActor
struct ChatCompletedTurnView<Content: View>: View {
    let turn: ChatCompletedTurn
    let disclosures: ChatActivityDisclosureStore
    let onDisclosureChange: () -> Void
    @ViewBuilder let content: (ChatTranscriptEntry) -> Content

    private var isExpanded: Bool { disclosures.isCompletedTurnExpanded(turn.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button {
                onDisclosureChange()
                disclosures.setCompletedTurnExpanded(!isExpanded, id: turn.id)
            } label: {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(turn.label)
                    Spacer(minLength: 0)
                }
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(turn.label)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the completed work." : "Shows thinking and tool calls. Assistant messages stay visible.")
            .accessibilityIdentifier("chat.\(turn.id)")

            if isExpanded, let activity = turn.mergedActivity {
                content(activity)
            }
        }
    }
}
