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
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            Button {
                onDisclosureChange()
                disclosures.setExpanded(!isExpanded, for: turn)
            } label: {
                HStack(spacing: LoopdyTokens.space8) {
                    statusIcon
                    VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                        Text("Work trail")
                            .loopdyFont(.body, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text(summary.compactLabel)
                            .loopdyFont(.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: LoopdyTokens.space8)
                    Image(systemName: "chevron.right")
                        .loopdyFont(.metadata, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
            .accessibilityLabel("Work trail. \(summary.compactLabel)")
            .accessibilityValue(
                ChatWorkTrailDisclosureAccessibility.value(isExpanded: isExpanded)
            )
            .accessibilityHint(isExpanded ? "Collapses work details." : "Expands work details.")
            .accessibilityIdentifier("chat.work-trail.\(turn.id)")

            if !isExpanded, let collapsedDetail {
                Text(collapsedDetail)
                    .loopdyFont(.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }

            if isExpanded, rendersExpandedEvents {
                VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                    ForEach(turn.events) { event in
                        ChatActivityRow(
                            event: event,
                            onDisclosureChange: onDisclosureChange
                        )
                    }
                }
                .padding(.leading, LoopdyTokens.space4)
            }
        }
        .padding(LoopdyTokens.space12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: LoopdyTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: LoopdyTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: LoopdyTokens.hairline)
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
            LoopdyAnimatedMark(isActive: true, height: 18)
                .frame(width: 26)
        } else {
            Image(systemName: summary.leadingSystemImage)
                .loopdyFont(.body)
                .foregroundStyle(summaryStatusColor)
                .accessibilityHidden(true)
        }
    }

    private var summaryStatusColor: Color {
        theme.secondaryText
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

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
