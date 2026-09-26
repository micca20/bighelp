import Foundation

/// What the agent is told when the person reacts to one of its messages.
enum ChatReactionNote {
    static func text(emoji: String, message: String) -> String {
        var snippet = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if snippet.count > 160 { snippet = String(snippet.prefix(160)) + "…" }
        let quoted = snippet.isEmpty ? "your earlier message" : "your message: \"\(snippet)\""
        return "[The user reacted \(emoji) to \(quoted)] "
            + "Reply only if it feels natural, like a quick thanks, an answer, or doing what the reaction asks. "
            + "Otherwise respond with exactly [SILENT]."
    }
}

/// Hermes' "no reply" markers. An agent answering a reaction with one shows nothing.
enum ChatSilentReply {
    static let markers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"]

    static func hides(_ item: TimelineItem) -> Bool {
        guard item.role == .assistant, case .message(let text) = item.content else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return false }
        if markers.contains(trimmed) { return true }
        // While streaming, "[SIL" is on its way to "[SILENT]".
        return item.metadata.delivery == "Streaming" && trimmed.count >= 2 && "[SILENT]".hasPrefix(trimmed)
    }
}
