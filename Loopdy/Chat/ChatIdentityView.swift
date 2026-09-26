import SwiftUI

/// Display-only identity data for the conversation header. The owner supplies
/// real profile URLs when they exist; AvatarView keeps the persona fallback.
struct ChatIdentityParticipant: Identifiable, Equatable {
    let stableID: String
    let displayName: String
    let imageURL: URL?

    var id: String { stableID }
}

/// The identity mark for a direct or group conversation. A direct chat shows
/// the agent's avatar, which doubles as its live status; a group overlaps up
/// to three member avatars.
struct ChatIdentityAvatarView: View {
    let participants: [ChatIdentityParticipant]
    let theme: LoopdyTheme
    var size: CGFloat = 40
    var state: AgentLiveState?

    var body: some View {
        Group {
            if let participant = participants.first, participants.count == 1 {
                AvatarView(
                    stableID: participant.stableID,
                    displayName: participant.displayName,
                    imageURL: participant.imageURL,
                    size: size,
                    state: state
                )
            } else if participants.isEmpty {
                AvatarView(
                    stableID: "conversation",
                    displayName: "Conversation",
                    size: size,
                    state: state
                )
            } else {
                AvatarStack(
                    avatars: participants.prefix(3).map {
                        AvatarStack.Avatar(stableID: $0.stableID, displayName: $0.displayName, imageURL: $0.imageURL)
                    },
                    size: size * 0.8,
                    outlineColor: theme.canvas
                )
            }
        }
        .frame(minWidth: size, minHeight: size)
        .accessibilityHidden(true)
    }
}

/// The shared centered identity used by direct and group chat headers:
/// avatar above the name, with the agent's live state (or the group's member
/// count) underneath.
struct ChatConversationIdentityLabel: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String?
    let participants: [ChatIdentityParticipant]
    let theme: LoopdyTheme
    var disclosureSymbol = "chevron.right"
    var subtitleShimmers = false
    var showsCaption = true
    /// Real run state for a direct chat; nil when the owner has none to show.
    var liveState: AgentLiveState?
    /// Everyone in a group chat, including the user.
    var memberCount: Int?

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: LoopdyTokens.space8) {
                    identityAvatar(size: 40)
                    caption
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else {
                VStack(spacing: 4) {
                    identityAvatar(size: verticalSizeClass == .compact ? 32 : 40)
                    caption
                }
            }
        }
        .frame(minWidth: 104, maxWidth: 240, minHeight: LoopdyTokens.hitTarget)
        .contentShape(.rect)
    }

    private func identityAvatar(size: CGFloat) -> some View {
        ChatIdentityAvatarView(participants: participants, theme: theme, size: size, state: liveState)
    }

    @ViewBuilder
    private var caption: some View {
        if showsCaption {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text(title)
                        .loopdyFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Image(systemName: disclosureSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .loopdyNavigationGlass(in: Capsule())

                statusLine
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 240)
            }
        }
    }

    /// Prefer the host's own activity phrase while it is live, then the
    /// agent's derived state, then the group's size.
    @ViewBuilder
    private var statusLine: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .loopdyFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .loopdyActiveCallShimmer(isActive: subtitleShimmers, color: .white)
        } else if let liveState {
            AgentLiveStateLabel(state: liveState, font: .caption)
                .foregroundStyle(theme.secondaryText)
        } else if let memberCount, memberCount > 0 {
            Text(memberCount == 1 ? "1 member" : "\(memberCount) members")
                .loopdyFont(.metadata)
                .foregroundStyle(theme.secondaryText)
        }
    }
}
