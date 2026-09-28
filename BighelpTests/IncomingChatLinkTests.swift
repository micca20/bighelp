import Foundation
import Testing
@testable import Bighelp

/// `loopdy://chat/<id>` carries either a chat's own ID (widgets, Shortcuts) or
/// a notification's scoped digest (Live Activities, notification taps). Both
/// start with "native-", so the prefix alone can't tell them apart.
struct IncomingChatLinkTests {
    @Test func aChatsOwnIDIsNotANotificationLink() throws {
        let owner = WorkspaceOwner(
            authority: try WorkspaceAuthority.dashboard(endpointIdentity: "https://links.example"),
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let chatID = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "default",
                                                           anchorID: "20260928_064512_ab12cd")
        #expect(chatID.hasPrefix("native-"), "The ID the widget stores starts the same way")
        #expect(!ManagedNotificationValidation.isOpaqueSessionID(chatID))
    }

    @Test func notificationLinksAreTheScopedDigest() {
        let digest = "native-" + ManagedNotificationValidation.digest("scope\0host\0default\0session")
        #expect(ManagedNotificationValidation.isOpaqueSessionID(digest))
        #expect(!ManagedNotificationValidation.isOpaqueSessionID(digest.uppercased()))
        #expect(!ManagedNotificationValidation.isOpaqueSessionID(String(digest.dropLast())))
        #expect(!ManagedNotificationValidation.isOpaqueSessionID(digest + "0"))
        #expect(!ManagedNotificationValidation.isOpaqueSessionID("native-"))
        #expect(!ManagedNotificationValidation.isOpaqueSessionID("demo-chat-1"))
    }
}
