import BuzzKit
import UserNotifications

/// BuzzKit, not the app's notification delegate, decides how its pushes show
/// while bighelp is open. This keeps an alert for the chat you're looking at
/// quiet, like Messages. Unsealed alerts carry the chat as `sessionReference`;
/// the notification extension adds it to sealed ones after opening them.
final class BighelpBuzzKitPresentation: BuzzKitDelegate {
    static let shared = BighelpBuzzKitPresentation()

    func buzzKit(_ buzzKit: BuzzKit, willPresent payload: PushPayload) -> UNNotificationPresentationOptions? {
        guard let thread = Self.thread(payload.data) else { return nil }
        return BighelpVisibleChats.isShowingFromAnyThread(thread: thread) ? [] : nil
    }

    static func thread(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"],
              case .string(let thread)? = loopdy["sessionReference"], !thread.isEmpty else { return nil }
        return thread
    }
}
