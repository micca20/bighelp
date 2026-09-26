import BuzzKitNotificationServiceExtension

/// BuzzKit exclusively owns rich notification media and receipts.
final class NotificationService: BuzzKitNotificationService {
    override var buzzKitAppGroup: String? { "group.app.loopdy.mobile.buzzkit" }
}
