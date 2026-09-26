import Foundation
import Testing
@testable import Loopdy

@MainActor
struct UserIdentityStoreTests {
    @Test func identityPersistsAcrossStoreRecreation() {
        let defaults = isolatedDefaults()
        let store = UserIdentityStore(defaults: defaults)

        store.identity = UserIdentity(
            name: "Maya",
            avatarFileName: "maya.png",
            accountAvatar: UserProfileAvatar(
                mimeType: "image/png",
                byteCount: 8,
                sha256: "sha256-user-avatar-0001",
                encryptedData: "encrypted-user-avatar-0001"
            )
        )

        let restored = UserIdentityStore(defaults: defaults)
        #expect(restored.identity.accountAvatar?.encryptedData == "encrypted-user-avatar-0001")
    }

    @Test func nameOnlyLocalSavePersistsWithoutAnAccount() async throws {
        let defaults = isolatedDefaults()
        let store = UserIdentityStore(defaults: defaults)
        try await store.saveDisplayName("  Maya  ", to: nil)
        #expect(store.identity.name == "Maya")
        #expect(UserIdentityStore(defaults: defaults).identity.name == "Maya")
    }

    @Test func blankNameCannotReplaceAnAcceptedName() async {
        let store = UserIdentityStore(defaults: isolatedDefaults())
        store.identity.name = "Maya"
        do {
            try await store.saveDisplayName(" \n ", to: nil)
            Issue.record("Blank display names must be rejected")
        } catch {}
        #expect(store.identity.name == "Maya")
    }

    @Test func stableIdentityUsesTheLocalUserID() {
        #expect(UserIdentity.stableID == "local-user")
    }

    @Test func legacyIdentityWithoutAccountFieldsMigratesWithoutResettingTheProfile() throws {
        let defaults = isolatedDefaults()
        defaults.set(
            Data("""
            {"name":"Maya","avatarFileName":"maya.png"}
            """.utf8),
            forKey: "loopdy.demo.userIdentity"
        )

        let store = UserIdentityStore(defaults: defaults)

        #expect(store.identity.name == "Maya")
        #expect(store.identity.avatarFileName == "maya.png")
        #expect(store.identity.accountAvatar == nil)
        #expect(store.identity.accountProfileRevision == 0)
    }
}
