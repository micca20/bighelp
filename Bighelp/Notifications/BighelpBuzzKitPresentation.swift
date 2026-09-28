import BuzzKit
import UserNotifications

/// BuzzKit, not the app's notification delegate, decides how its pushes show
/// while bighelp is open and where their links go when tapped. This keeps an
/// alert for the chat you're looking at quiet, like Messages. Unsealed alerts
/// carry the chat as `sessionReference`; the notification extension adds it to
/// sealed ones after opening them.
final class BighelpBuzzKitPresentation: BuzzKitDelegate {
    static let shared = BighelpBuzzKitPresentation()

    func buzzKit(_ buzzKit: BuzzKit, willPresent payload: PushPayload) -> UNNotificationPresentationOptions? {
        guard let thread = Self.thread(payload.data) else { return nil }
        return BighelpVisibleChats.isShowingFromAnyThread(thread: thread) ? [] : nil
    }

    /// Alerts carry `loopdy:///dashboard?eventId=…`, which used to open the
    /// Activity inbox. The app's own tap handler (BuzzKit forwards the tap)
    /// opens the alert's chat, so this link is claimed and goes nowhere.
    func buzzKit(_ buzzKit: BuzzKit, openDeepLink url: URL) -> Bool {
        Self.isManagedEventLink(url)
    }

    static func isManagedEventLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "loopdy" && BighelpIncomingURLRoute.parse(url) == .home
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "eventId" && !($0.value ?? "").isEmpty } == true
    }

    static func thread(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"],
              case .string(let thread)? = loopdy["sessionReference"], !thread.isEmpty else { return nil }
        return thread
    }
}
