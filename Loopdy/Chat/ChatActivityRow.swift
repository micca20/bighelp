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
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            if event.kind == .tool || event.kind == .reasoning {
                Button {
                    onDisclosureChange()
                    let expanded = !isExpanded
                    if let disclosures { disclosures.setExpanded(expanded, for: event) }
                    else { localExpanded = expanded }
                } label: {
                    rowHeader
                        .frame(minHeight: event.kind == .reasoning ? LoopdyTokens.hitTarget : nil)
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
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.reasoning-content.\(event.eventID)")
            }
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space8) {
            activityMark

            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
                    Text(event.presentationTitle)
                        .loopdyFont(.body)
                        .foregroundStyle(statusColor)
                    Spacer(minLength: LoopdyTokens.space8)
                    Text(statusLabel)
                        .loopdyFont(.metadata, weight: .semibold)
                        .foregroundStyle(statusColor)
                    if event.kind == .tool || event.kind == .reasoning {
                        Image(systemName: "chevron.right")
                            .loopdyFont(.metadata, weight: .semibold)
                            .foregroundStyle(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                if event.kind != .reasoning, let summary = event.collapsedPresentationSummary {
                    Text(summary)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, LoopdyTokens.space8)
        .padding(.vertical, LoopdyTokens.space4)
        .loopdyActiveCallShimmer(
            isActive: event.kind == .tool && toolVisualState.shimmers,
            color: .white
        )
    }

    @ViewBuilder
    private var activityMark: some View {
        if event.kind == .reasoning {
            LoopdyAnimatedMark(isActive: event.lifecycle == .running, height: 16)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: systemImage)
                .loopdyFont(.metadata)
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
            LoopdySessionContentDisclosure(sessionID: reference.sessionID, rowID: reference.rowID)
        }
        if sections.isEmpty {
            Text("Hermes did not provide additional details for this call.")
                .loopdyFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                ForEach(sections, id: \.label) { section in
                    VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                        HStack {
                            Text(section.label)
                                .loopdyFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                            Spacer(minLength: LoopdyTokens.space8)
                            if event.contentReference == nil {
                                Button {
                                    UIPasteboard.general.string = section.value
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .loopdyFont(.metadata)
                                        .foregroundStyle(theme.tertiaryText)
                                        .frame(
                                            minWidth: LoopdyTokens.hitTarget,
                                            minHeight: LoopdyTokens.hitTarget
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
                            .padding(LoopdyTokens.space12)
                            .background(
                                theme.raisedSurface,
                                in: .rect(cornerRadius: LoopdyTokens.radius12)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: LoopdyTokens.radius12)
                                    .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
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

    @LoopdyThemeReader private var theme: LoopdyTheme

}
