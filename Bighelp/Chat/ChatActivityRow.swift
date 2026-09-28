import SwiftUI
import UIKit

struct ChatActivityRow: View {
    let event: ChatActivityEvent
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @State private var localExpanded: Bool?
    private var isExpanded: Bool {
        disclosures?.isExpanded(event) ?? localExpanded ?? (event.kind == .reasoning && event.lifecycle == .running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if event.kind == .tool || event.kind == .reasoning {
                Button {
                    onDisclosureChange()
                    let expanded = !isExpanded
                    if let disclosures { disclosures.setExpanded(expanded, for: event) }
                    else { localExpanded = expanded }
                } label: {
                    rowHeader
                        .frame(minHeight: event.kind == .reasoning ? BighelpTokens.hitTarget : nil)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
                .accessibilityValue(
                    ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded)
                )
                .accessibilityHint(accessibilityHint)
                .accessibilityIdentifier("chat.activity.\(event.eventID)")
            } else {
                rowHeader
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityIdentifier("chat.activity.\(event.eventID)")
            }

            if event.kind == .tool, isExpanded {
                toolDetails
                    .padding(.leading, 28)
            } else if event.kind == .reasoning, isExpanded, let text = event.reasoningText {
                Text(text)
                    .bighelpFont(.label, weight: .regular)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(ChatInterimReplyStyle(theme: theme))
                    .accessibilityIdentifier("chat.reasoning-content.\(event.eventID)")
            }
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space8) {
            activityMark

            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    if event.kind == .reasoning {
                        Text(reasoningTitle)
                            .bighelpFont(.label)
                            .foregroundStyle(theme.secondaryText)
                            .bighelpActiveCallShimmer(isActive: event.lifecycle == .running, color: .white)
                    } else {
                        Text(event.presentationTitle)
                            .bighelpFont(.body)
                            .foregroundStyle(statusColor)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if event.kind != .reasoning || [.failed, .cancelled].contains(event.lifecycle) {
                        Text(statusLabel)
                            .bighelpFont(.metadata, weight: .semibold)
                            .foregroundStyle(statusColor)
                    }
                    if event.kind == .tool || event.kind == .reasoning {
                        Image(systemName: "chevron.right")
                            .bighelpFont(.metadata, weight: .semibold)
                            .foregroundStyle(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                if event.kind != .reasoning, let summary = event.collapsedPresentationSummary {
                    Text(summary)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space8)
        .padding(.vertical, BighelpTokens.space4)
        .bighelpActiveCallShimmer(
            isActive: event.kind == .tool && toolVisualState.shimmers,
            color: .white
        )
    }

    @ViewBuilder
    private var activityMark: some View {
        if event.kind == .reasoning {
            BighelpAnimatedMark(isActive: event.lifecycle == .running, height: 16)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: systemImage)
                .bighelpFont(.metadata)
                .foregroundStyle(statusColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var toolDetails: some View {
        let sections = detailSections
        if let reference = event.contentReference {
            Text("Preview — complete content is stored on Hermes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            BighelpSessionContentDisclosure(sessionID: reference.sessionID, rowID: reference.rowID)
        }
        if sections.isEmpty {
            Text("Hermes did not provide additional details for this call.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(sections, id: \.label) { section in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        HStack {
                            Text(section.label)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                            Spacer(minLength: BighelpTokens.space8)
                            if event.contentReference == nil {
                                Button {
                                    UIPasteboard.general.string = section.value
                                    BighelpHaptics.success()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .bighelpFont(.metadata)
                                        .foregroundStyle(theme.tertiaryText)
                                        .frame(
                                            minWidth: BighelpTokens.hitTarget,
                                            minHeight: BighelpTokens.hitTarget
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Copy \(section.label.lowercased())")
                            }
                        }
                        ChatToolDetailText(label: section.label, value: section.value,
                                           identifier: "chat.activity.\(event.eventID).\(section.label.lowercased())",
                                           isCanonicalPreview: event.contentReference != nil)
                            .foregroundStyle(theme.secondaryText)
                            .padding(BighelpTokens.space12)
                            .background(
                                theme.raisedSurface,
                                in: .rect(cornerRadius: BighelpTokens.radius12)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                            }
                            .accessibilityIdentifier(
                                "chat.activity.\(event.eventID).\(section.label.lowercased())"
                            )
                    }
                }
            }
        }
    }

    private var detailSections: [(label: String, value: String)] {
        var sections: [(String, String)] = []
        if let summary = nonempty(event.summary) {
            sections.append(("Summary", summary))
        }
        if let arguments = nonempty(event.arguments) {
            sections.append(("Arguments", arguments))
        }
        if let result = nonempty(event.result) {
            sections.append(("Result", result))
        }
        if let detail = nonempty(event.detail), detail != event.summary, detail != event.result {
            sections.append(("Details", detail))
        }
        return sections
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private var systemImage: String {
        switch event.kind {
        case .reasoning: "sparkles"
        case .tool: "terminal"
        case .subagent: "person.badge.plus"
        case .botHandoff: "arrow.trianglehead.swap"
        }
    }

    /// "Thinking…" while it runs, then how long it took, like Claude.
    private var reasoningTitle: String {
        guard event.lifecycle != .running else { return "Thinking…" }
        guard let milliseconds = event.durationMilliseconds, (1_000..<86_400_000).contains(milliseconds) else {
            return "Thought process"
        }
        let seconds = milliseconds / 1_000
        return seconds < 60 ? "Thought for \(seconds)s" : "Thought for \(seconds / 60)m \(seconds % 60)s"
    }

    private var statusLabel: String {
        switch event.lifecycle {
        case .running: "Working"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .recorded: "Recorded"
        }
    }

    private var statusColor: Color {
        if event.kind == .tool {
            return color(for: toolVisualState.tone)
        }
        return color(for: visualState.tone)
    }

    private func color(for tone: ChatActivityVisualTone) -> Color {
        switch tone {
        case .neutral: theme.secondaryText
        case .success: theme.success
        case .failure: theme.danger
        case .secondary: theme.secondaryText
        }
    }

    private var visualState: ChatActivityVisualState {
        ChatActivityVisualState(lifecycle: event.lifecycle)
    }

    private var toolVisualState: ChatToolActivityVisualState {
        ChatToolActivityVisualState(lifecycle: event.lifecycle)
    }

    private var accessibilityText: String {
        if event.kind == .tool {
            event.collapsedAccessibilityLabel(status: statusLabel)
        } else if event.kind == .reasoning {
            "Thinking. \(statusLabel)"
        } else {
            [event.presentationTitle, event.collapsedPresentationSummary, statusLabel]
                .compactMap { $0 }
                .joined(separator: ". ")
        }
    }

    private var accessibilityHint: String {
        if event.kind == .reasoning {
            return isExpanded ? "Collapses reasoning text." : "Expands reasoning text."
        }
        guard event.kind == .tool else { return "" }
        return isExpanded ? "Collapses full tool details." : "Expands full tool details."
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

/// Back-to-back reasoning as one Thinking / Thought process row, with each
/// entry on its own line inside.
struct ChatReasoningGroupRow: View {
    let events: [ChatActivityEvent]
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @State private var localExpanded: Bool?

    private var isRunning: Bool { events.contains { $0.lifecycle == .running } }
    private var isExpanded: Bool {
        disclosures?.isExpanded(reasoning: events) ?? localExpanded ?? isRunning
    }
    private var identifier: String { events.first?.eventID ?? "reasoning" }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Button {
                onDisclosureChange()
                let expanded = !isExpanded
                if let disclosures { disclosures.setExpanded(expanded, reasoning: events) }
                else { localExpanded = expanded }
            } label: {
                header
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRunning ? "Thinking. Working" : "Thinking. Done")
            .accessibilityValue(ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded))
            .accessibilityHint(isExpanded ? "Collapses reasoning text." : "Expands reasoning text.")
            .accessibilityIdentifier("chat.activity.\(identifier)")

            if isExpanded, !lines.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(lines, id: \.id) { line in
                        Text(line.text)
                            .bighelpFont(.label, weight: .regular)
                            .foregroundStyle(theme.secondaryText)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chat.reasoning-content.\(line.id)")
                    }
                }
                .modifier(ChatInterimReplyStyle(theme: theme))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            BighelpAnimatedMark(isActive: isRunning, height: 16)
                .frame(width: 20, height: 20)
            Text(ChatReasoningGroupRow.title(for: events))
                .bighelpFont(.label)
                .foregroundStyle(theme.secondaryText)
                .bighelpActiveCallShimmer(isActive: isRunning, color: .white)
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "chevron.right")
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, BighelpTokens.space8)
        .padding(.vertical, BighelpTokens.space4)
    }

    private var lines: [(id: String, text: String)] {
        events.compactMap { event in event.reasoningText.map { (event.eventID, $0) } }
    }

    /// "Thinking…" while any entry runs, then the total time when every entry
    /// has one, like a single reasoning row.
    static func title(for events: [ChatActivityEvent]) -> String {
        if events.contains(where: { $0.lifecycle == .running }) { return "Thinking…" }
        let durations = events.compactMap(\.durationMilliseconds).filter { (0..<86_400_000).contains($0) }
        let total = durations.reduce(0, +)
        guard durations.count == events.count, (1_000..<86_400_000).contains(total) else { return "Thought process" }
        let seconds = total / 1_000
        return seconds < 60 ? "Thought for \(seconds)s" : "Thought for \(seconds / 60)m \(seconds % 60)s"
    }

    @BighelpThemeReader private var theme: BighelpTheme
}
