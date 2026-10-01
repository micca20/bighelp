import SwiftUI

/// One task on the board: what it is, who has it, and what's happening,
/// all from Hermes. Running work shows its real heartbeat, never a guess.
struct KanbanCardView: View {
    let task: HermesKanbanTask
    let agent: KanbanAgent?
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if task.statusNote != nil || task.urgency.rawValue > 0 {
                HStack(spacing: BighelpTokens.space8) {
                    if let note = task.statusNote {
                        Text(note)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(lane.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(lane.tint.opacity(0.13), in: .capsule)
                    }
                    Spacer(minLength: 0)
                    if task.urgency.rawValue > 0 {
                        Label(task.urgency.title, systemImage: "flag.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(task.urgency == .urgent ? KanbanLane.needsYou.tint : theme.warning)
                            .accessibilityLabel("\(task.urgency.title) priority")
                    }
                }
            }
            Text(task.title)
                .bighelpFont(.body, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary = task.latestSummary, !summary.isEmpty, task.status != .done || summary.count < 120 {
                Text(summary)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            footer
        }
        .padding(BighelpTokens.space12)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .strokeBorder(task.status == .running ? lane.tint.opacity(0.45) : theme.border.opacity(0.6),
                              lineWidth: task.status == .running ? 1.2 : BighelpTokens.hairline)
        }
        .shadow(color: theme.elevationShadow.opacity(theme.isDarkPalette ? 0 : 0.05), radius: 6, y: 2)
        .opacity(isBusy ? 0.6 : 1)
        .overlay(alignment: .topTrailing) {
            if isBusy { ProgressView().controlSize(.small).padding(BighelpTokens.space8) }
        }
        .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kanban.card.\(task.id)")
    }

    private var lane: KanbanLane { task.lane ?? .later }

    private var footer: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let agent {
                AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 22)
                    .overlay {
                        if task.status == .running { KanbanPulseRing(color: lane.tint) }
                    }
                Text(agent.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.tertiaryText)
                Text("Anyone")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.tertiaryText)
            }
            Spacer(minLength: 0)
            if task.commentCount > 0 {
                Label("\(task.commentCount)", systemImage: "bubble.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityLabel("\(task.commentCount) comment\(task.commentCount == 1 ? "" : "s")")
            }
            if task.childCount > 0 {
                Label("\(task.childCount)", systemImage: "square.stack.3d.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityLabel("\(task.childCount) smaller task\(task.childCount == 1 ? "" : "s")")
            }
            KanbanWhen(task: task)
        }
    }

    @BighelpThemeReader private var theme
}

/// How long ago something happened on a card, updating as time passes.
struct KanbanWhen: View {
    let task: HermesKanbanTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(text(now: context.date))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isQuiet(now: context.date) ? theme.warning : theme.tertiaryText)
        }
    }

    /// Running work is "active" while Hermes hears its heartbeat.
    private func isQuiet(now: Date) -> Bool {
        guard task.status == .running, let beat = task.lastHeartbeatAt else { return false }
        return now.timeIntervalSince(beat) > 300
    }

    private func text(now: Date) -> String {
        if task.status == .running, let beat = task.lastHeartbeatAt {
            let age = Self.short(now.timeIntervalSince(beat))
            return isQuiet(now: now) ? "Quiet \(age)" : "Active \(age) ago"
        }
        let date = task.completedAt ?? task.startedAt ?? task.createdAt
        return Self.short(now.timeIntervalSince(date))
    }

    static func short(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    @BighelpThemeReader private var theme
}

/// A soft ring around a working agent. Still under Reduce Motion.
struct KanbanPulseRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .scaleEffect(expanded ? 1.45 : 1)
            .opacity(expanded ? 0 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
            }
            .accessibilityHidden(true)
    }
}
