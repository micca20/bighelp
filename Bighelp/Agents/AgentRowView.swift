import SwiftUI

/// iMessage-style directory row: the avatar carries the live state, the name
/// and summary sit beside it, and every other action lives behind the
/// trailing ellipsis.
struct AgentRowView: View {
    let agent: AgentProfile
    let imageURL: URL?
    let isPrimary: Bool
    let isPinned: Bool
    let canOpenChat: Bool
    let onOpenChat: () -> Void
    let onManage: () -> Void
    var identifierPrefix = "agent"
    var liveState: AgentLiveState = .idle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var nameSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var summarySize: CGFloat = 14

    static let avatarSize: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space4) {
            Button(action: onOpenChat) {
                HStack(alignment: .center, spacing: BighelpTokens.space12) {
                    AvatarView(
                        stableID: agent.id, displayName: agent.name,
                        imageURL: imageURL, size: Self.avatarSize, state: liveState
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        nameLine
                        summaryLine
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canOpenChat)
            .accessibilityLabel("\(agent.name), \(agent.role)")
            .accessibilityValue(statusValue)
            .accessibilityHint(canOpenChat ? "Opens this agent's chat." : "Chat is currently unavailable. More actions explains why.")
            .accessibilityIdentifier("\(identifierPrefix).\(agent.id)")

            Button("More actions for \(agent.name)", systemImage: "ellipsis", action: onManage)
                .labelStyle(.iconOnly)
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
                // A little over the 44pt minimum so pixel rounding never undercuts it.
                .frame(width: 48, height: 48)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifierPrefix).\(agent.id).more")
        }
        .accessibilityElement(children: .contain)
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space4) {
            Text(agent.name)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(isAccessibilitySize ? nil : 1)
            if isPrimary {
                Image(systemName: "star.fill")
                    .font(.system(size: summarySize * 0.8, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityLabel("Primary")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: summarySize * 0.8, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityLabel("Pinned")
                    .accessibilityIdentifier("\(identifierPrefix).\(agent.id).pinned-badge")
            }
        }
    }

    private var summaryLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if liveState != .idle {
                Circle().fill(liveState.dotColor)
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    .accessibilityHidden(true)
            }
            Text(summaryText)
                .font(.system(size: summarySize))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(isAccessibilitySize ? nil : AgentRowPresentation.summaryLineLimit)
        }
    }

    private var summaryText: String {
        if liveState != .idle { return liveState.label }
        return agent.summary.isEmpty ? agent.role : agent.summary
    }

    private var statusValue: String {
        [
            liveState != .idle ? liveState.label : nil,
            isPrimary ? "Primary agent" : nil,
            isPinned ? "Pinned" : nil
        ]
        .compactMap { $0 }.joined(separator: ", ")
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    @BighelpThemeReader private var theme
}
