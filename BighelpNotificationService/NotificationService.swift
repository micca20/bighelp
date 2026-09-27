import BuzzKitNotificationServiceExtension
import Foundation
import UserNotifications

/// BuzzKit owns rich notification media and receipts. Sealed bighelp alerts are
/// opened here first: only this phone can read their title, text and avatar.
final class NotificationService: BuzzKitNotificationService, @unchecked Sendable {
    override var buzzKitAppGroup: String? { "group.app.loopdy.mobile.buzzkit" }

    private let lock = NSLock()
    private var pending: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Anything that isn't a sealed alert, or can't be opened, shows as sent.
        guard let sealed = BighelpSealedNotification(userInfo: request.content.userInfo),
              let opened = try? sealed.open(),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            super.didReceive(request, withContentHandler: contentHandler)
            return
        }
        content.title = opened.title
        content.body = opened.body
        setPending((contentHandler, content.copy() as? UNNotificationContent ?? content))
        let box = UncheckedBox((request: request, content: content))
        Task {
            if let file = await sealed.avatarFile(for: opened),
               let attachment = try? UNNotificationAttachment(identifier: "bk.image", url: file) {
                box.value.content.attachments = [attachment]
            }
            guard let handler = self.takePending()?.handler else { return }
            self.forward(UNNotificationRequest(identifier: box.value.request.identifier,
                                               content: box.value.content, trigger: nil), handler)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of time before the avatar arrived: show the opened text without it.
        if let pending = takePending() { pending.handler(pending.content) }
        super.serviceExtensionTimeWillExpire()
    }

    /// BuzzKit then registers the actions and sends the delivered receipt.
    private func forward(_ request: UNNotificationRequest, _ handler: @escaping (UNNotificationContent) -> Void) {
        super.didReceive(request, withContentHandler: handler)
    }

    private func setPending(_ value: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)) {
        lock.withLock { pending = value }
    }

    private func takePending() -> (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
