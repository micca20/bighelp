import SwiftUI

/// Uppercase, letterspaced section caption ("PINNED", "GROUP CHATS").
struct AgentsSectionCaption: View {
    let title: String

    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.08)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @LoopdyThemeReader private var theme
}

/// A grid tile for a pinned or featured agent: large live avatar, name, and
/// the live-state line underneath.
struct AgentFeaturedTile: View {
    let agent: AgentProfile
    let imageURL: URL?
    let liveState: AgentLiveState
    let isPrimary: Bool
    let onTap: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var nameSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var stateSize: CGFloat = 11

    static let avatarSize: CGFloat = 64

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                AvatarView(
                    stableID: agent.id, displayName: agent.name,
                    imageURL: imageURL, size: Self.avatarSize, state: liveState
                )
                .accessibilityHidden(true)
                Text(agent.name)
                    .font(.system(size: nameSize, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                AgentLiveStateLabel(state: liveState, font: .system(size: stateSize))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
            .padding(.vertical, LoopdyTokens.space4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityValue([liveState.label, isPrimary ? "Primary agent" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens this agent's chat. Long press for more actions.")
    }

    @LoopdyThemeReader private var theme
}

/// Dashed "New" slot that trails the featured grid when creation is allowed.
struct AgentNewTile: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var labelSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                AgentDashedPlusCircle(size: AgentFeaturedTile.avatarSize)
                Text("New agent")
                    .font(.system(size: labelSize, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
            .padding(.vertical, LoopdyTokens.space4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create agent")
    }

    @LoopdyThemeReader private var theme
}

/// The "start a group chat" row at the top of the group chats section.
struct AgentNewGroupRow: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var detailSize: CGFloat = 14

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoopdyTokens.space12) {
                AgentDashedPlusCircle(size: AgentRowView.avatarSize, tint: theme.action)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New group chat")
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(theme.action)
                    Text("Bring a few agents into one conversation")
                        .font(.system(size: detailSize))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .padding(.vertical, 10)
            .frame(minHeight: LoopdyTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New group")
        .accessibilityHint("Starts a group chat with several agents.")
    }

    @LoopdyThemeReader private var theme
}

struct AgentDashedPlusCircle: View {
    let size: CGFloat
    var tint: Color? = nil

    var body: some View {
        Circle()
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(tint ?? theme.tertiaryText)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(tint ?? theme.secondaryText)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @LoopdyThemeReader private var theme
}

/// Friendly first-run state for a host with no agents yet.
struct AgentsEmptyStateView: View {
    let canCreate: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: LoopdyTokens.space12) {
            EmberMark(size: 72)
            Text("No agents yet")
                .loopdyFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(canCreate
                 ? "Create a personal assistant and it will show up here, ready to chat."
                 : "Agents on this host appear here.")
                .loopdyFont(.body)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if canCreate {
                Button(action: onCreate) {
                    Label("Create an agent", systemImage: "plus")
                        .loopdyFont(.label)
                        .frame(maxWidth: 280, minHeight: LoopdyTokens.hitTarget)
                }
                .loopdyProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .tint(theme.action)
                .foregroundStyle(theme.actionForeground)
                .padding(.top, LoopdyTokens.space8)
                .accessibilityIdentifier("agents.empty.create")
            }
        }
        .padding(.horizontal, LoopdyTokens.space32)
        .padding(.vertical, LoopdyTokens.space40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @LoopdyThemeReader private var theme
}
