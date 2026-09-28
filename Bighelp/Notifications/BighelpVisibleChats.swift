import Foundation

/// Chats on screen right now, so an alert for a conversation you're already
/// looking at isn't also shown as a banner (like Messages).
@MainActor
final class BighelpVisibleChats {
    static let shared = BighelpVisibleChats()

    private final class Entry {
        weak var model: ChatModel?
        init(_ model: ChatModel) { self.model = model }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func appeared(_ model: ChatModel) {
        entries[ObjectIdentifier(model)] = Entry(model)
    }

    func disappeared(_ model: ChatModel) {
        entries[ObjectIdentifier(model)] = nil
    }

    /// Notification thread identifiers of the visible chats. Hosts send each
    /// alert with `thread-id` = sessionReference(profile, stored session).
    var threadIdentifiers: Set<String> {
        Set(entries.values.compactMap { entry in
            guard let native = entry.model?.nativeConversationClient else { return nil }
            return ManagedNotificationValidation.sessionReference(profile: native.profile, session: native.storedID)
        })
    }

    /// Whether an alert with this thread belongs to a chat that's on screen.
    func isShowing(thread: String) -> Bool {
        !thread.isEmpty && threadIdentifiers.contains(thread)
    }

    /// For callbacks that don't promise the main thread (BuzzKit's foreground
    /// presentation). The system calls them on main; otherwise this waits for it.
    nonisolated static func isShowingFromAnyThread(thread: String) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { shared.isShowing(thread: thread) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { shared.isShowing(thread: thread) } }
    }
}
