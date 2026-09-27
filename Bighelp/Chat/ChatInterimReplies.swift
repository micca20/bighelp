import SwiftUI

/// Marks agent messages written on the way to the answer ("Let me check your
/// files…") so they read quieter than the answer itself, like thinking.
///
/// Every message stays in place and fully readable; only its look changes.
/// A message is interim when the agent kept working after it (tools or
/// thinking). In a finished turn the last message is always the answer.
@MainActor
enum ChatInterimReplies {
    static func marking(_ entries: [ChatTranscriptEntry], isSending: Bool, isBotMode: Bool) -> [ChatTranscriptEntry] {
        // In a room several agents answer at once; each reply is someone's answer.
        guard !isBotMode else { return entries }
        let turnStarts = entries.indices.filter {
            if case .message(let item) = entries[$0], item.role == .human { return true }
            return false
        }
        var result = entries
        var start = 0
        for (index, end) in (turnStarts + [entries.count]).enumerated() {
            let isLastTurn = index == turnStarts.count
            markTurn(&result, range: start..<end, inFlight: isLastTurn && isSending)
            start = end + 1
        }
        return result
    }

    private static func markTurn(_ entries: inout [ChatTranscriptEntry], range: Range<Int>, inFlight: Bool) {
        guard !range.isEmpty else { return }
        let replies = range.filter { isReply(entries[$0]) }
        guard let lastReply = replies.last else { return }
        let lastWork = range.last { index in
            if case .activity = entries[index] { return true }
            return false
        }
        for index in replies {
            let workFollows = lastWork.map { index < $0 } ?? false
            let interim = workFollows && (inFlight || index < lastReply)
            guard interim, case .message(let item) = entries[index] else { continue }
            entries[index] = .message(item.markedInterim())
        }
    }

    /// Plain agent prose only; cards, approvals and media keep their own look.
    private static func isReply(_ entry: ChatTranscriptEntry) -> Bool {
        guard case .message(let item) = entry, item.role == .assistant,
              case .message(let text) = item.content else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Interim messages and thinking share one look: no bubble, smaller muted text,
/// and a thin line down the left, so the answer stands out.
struct ChatInterimReplyStyle: ViewModifier {
    static let textScale: CGFloat = 0.88
    static let ruleWidth: CGFloat = 2
    let theme: BighelpTheme

    func body(content: Content) -> some View {
        content
            .padding(.leading, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.secondaryText.opacity(0.28))
                    .frame(width: Self.ruleWidth)
                    .padding(.vertical, BighelpTokens.space4)
                    .accessibilityHidden(true)
            }
            .padding(.leading, BighelpTokens.space8)
    }
}
