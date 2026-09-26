import SwiftUI

/// iMessage-like presentation metrics kept separate from model and transport state.
/// Rich cards receive a wider lane while ordinary prose remains conversational on iPad.
enum LoopdyV3MessagePresentation {
    // Replies use nearly the full lane on a phone; iPad stays capped by
    // ChatBubbleLayoutMetrics.maximumAbsoluteWidth for readable lines.
    static let outgoingMaximumWidthFraction: CGFloat = 0.84
    static let incomingMaximumWidthFraction: CGFloat = 0.92
    static let richContentMaximumWidthFraction: CGFloat = 0.94
    static let horizontalContentPadding: CGFloat = 14
    static let bubbleRadius: CGFloat = 20
    static let tailRadius: CGFloat = 6

    static func maximumWidthFraction(role: TimelineRole, hasRichContent: Bool) -> CGFloat {
        if hasRichContent { return richContentMaximumWidthFraction }
        return role == .human ? outgoingMaximumWidthFraction : incomingMaximumWidthFraction
    }
}

/// Message-local styling: incoming bubbles use the theme's warm neutral and
/// outgoing bubbles the accent, so the theme reads on both sides of a chat.
/// True when the next visible transcript row is another message from the same
/// sender. Like iMessage, only the last bubble in a run keeps its tail.
private struct ChatMessageContinuesGroupKey: EnvironmentKey {
    static let defaultValue = false
}

/// True when the previous visible transcript row is a message from the same
/// sender, so group chats print the sender's name once per run.
private struct ChatMessageContinuesPreviousKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatMessageContinuesGroup: Bool {
        get { self[ChatMessageContinuesGroupKey.self] }
        set { self[ChatMessageContinuesGroupKey.self] = newValue }
    }

    var chatMessageContinuesPrevious: Bool {
        get { self[ChatMessageContinuesPreviousKey.self] }
        set { self[ChatMessageContinuesPreviousKey.self] = newValue }
    }
}

enum ChatMessageGrouping {
    /// Spacing below a bubble followed by the same sender vs. a sender change.
    static let groupedSpacing: CGFloat = 2
    static let senderChangeSpacing: CGFloat = 12
    /// Group chats perch the sender's avatar beside the last bubble of a run.
    static let perchedAvatarSize: CGFloat = 30

    static func continuesGroup(_ current: ChatTranscriptEntry, next: ChatTranscriptEntry?) -> Bool {
        guard case .message(let item) = current, let next, case .message(let following) = next else { return false }
        // Two different agents in a group chat are separate runs.
        return item.role == following.role && item.sender.id == following.sender.id
    }
}

struct LoopdyV3MessageSurface: ViewModifier {
    @Environment(\.chatMessageContinuesGroup) private var continuesGroup
    let role: TimelineRole
    let theme: LoopdyTheme
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, LoopdyV3MessagePresentation.horizontalContentPadding)
            .padding(.vertical, 10)
            .background(shape.fill(fillColor))
            .overlay {
                if increasedContrast {
                    shape.strokeBorder(theme.primaryText, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    var fillColor: Color {
        if role == .human { return theme.outgoingMessageBackground }
        return theme.incomingMessageBackground
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: LoopdyV3MessagePresentation.bubbleRadius,
            bottomLeadingRadius: role == .assistant && !continuesGroup
                ? LoopdyV3MessagePresentation.tailRadius
                : LoopdyV3MessagePresentation.bubbleRadius,
            bottomTrailingRadius: role == .human && !continuesGroup
                ? LoopdyV3MessagePresentation.tailRadius
                : LoopdyV3MessagePresentation.bubbleRadius,
            topTrailingRadius: LoopdyV3MessagePresentation.bubbleRadius,
            style: .continuous
        )
    }
}

/// Chat follows the chosen typeface, with native system type as the default.
private struct LoopdyMessageFontModifier: ViewModifier {
    let role: LoopdyFontRole
    let weight: Font.Weight?
    let italic: Bool

    func body(content: Content) -> some View {
        content.loopdyFont(role, weight: weight, italic: italic)
    }
}

extension View {
    func loopdyMessageFont(
        _ role: LoopdyFontRole,
        weight: Font.Weight? = nil,
        italic: Bool = false
    ) -> some View {
        modifier(LoopdyMessageFontModifier(role: role, weight: weight, italic: italic))
    }
}

/// A compact audio presentation using the existing attachment-preview route.
/// Playback and saving remain owned by that preview, not a second audio player.
struct LoopdyV3MessageAudioView: View {
    let attachment: ChatAttachment
    let theme: LoopdyTheme
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            HStack(spacing: LoopdyTokens.space12) {
                Image(systemName: "play.fill")
                    .loopdyFont(.body, weight: .semibold)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .background(theme.action.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(attachment.fileName)
                        .loopdyFont(.label, weight: .medium)
                        .lineLimit(1)
                    Text("Audio preview")
                        .loopdyFont(.metadata)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .padding(LoopdyTokens.space8)
            .frame(width: 280)
            .background(theme.incomingMessageBackground, in: .rect(cornerRadius: LoopdyTokens.radius20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(attachment.fileName)")
        .accessibilityHint("Opens the existing audio preview with playback and save options")
    }
}
