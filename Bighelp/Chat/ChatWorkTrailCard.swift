import SwiftUI

struct ChatWorkTrailCard: View {
    let turn: ChatActivityTurn
    let rendersExpandedEvents: Bool
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var inheritedDisclosures
    @State private var localDisclosures = ChatActivityDisclosureStore()
    private var disclosures: ChatActivityDisclosureStore { inheritedDisclosures ?? localDisclosures }
    private var isExpanded: Bool { disclosures.isExpanded(turn) }

    init(
        turn: ChatActivityTurn,
        rendersExpandedEvents: Bool = true,
        onDisclosureChange: @escaping () -> Void = {}
    ) {
        self.turn = turn
        self.rendersExpandedEvents = rendersExpandedEvents
        self.onDisclosureChange = onDisclosureChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Button {
                onDisclosureChange()
                disclosures.setExpanded(!isExpanded, for: turn)
            } label: {
                HStack(spacing: BighelpTokens.space8) {
                    statusIcon
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text("Work trail")
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text(summary.compactLabel)
                            .bighelpFont(.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Image(systemName: "chevron.right")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .accessibilityLabel("Work trail. \(summary.compactLabel)")
            .accessibilityValue(
                ChatWorkTrailDisclosureAccessibility.value(isExpanded: isExpanded)
            )
            .accessibilityHint(isExpanded ? "Collapses work details." : "Expands work details.")
            .accessibilityIdentifier("chat.work-trail.\(turn.id)")

            if !isExpanded, let collapsedDetail {
                Text(collapsedDetail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }

            if isExpanded, rendersExpandedEvents {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(turn.events) { event in
                        ChatActivityRow(
                            event: event,
                            onDisclosureChange: onDisclosureChange
                        )
                    }
                }
                .padding(.leading, BighelpTokens.space4)
            }
        }
        .padding(BighelpTokens.space12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        // Tool details deliberately retain V2 typography as well as its layout.
        .modifier(ChatToolDetailStyle())
        .environment(\.chatActivityDisclosureStore, disclosures)
    }

    private var summary: ChatWorkTrailSummary {
        ChatWorkTrailSummary(events: turn.events)
    }

    private var collapsedDetail: String? {
        turn.events.last(where: { $0.lifecycle == .running })?.collapsedPresentationSummary
    }

    @ViewBuilder
    private var statusIcon: some View {
        if summary.hasRunningWork {
            BighelpAnimatedMark(isActive: true, height: 18)
                .frame(width: 26)
        } else {
            Image(systemName: summary.leadingSystemImage)
                .bighelpFont(.body)
                .foregroundStyle(summaryStatusColor)
                .accessibilityHidden(true)
        }
    }

    private var summaryStatusColor: Color {
        theme.secondaryText
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

enum ChatActivityDisclosureAccessibility {
    static func value(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }
}

enum ChatWorkTrailDisclosureAccessibility {
    static func value(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }
}
