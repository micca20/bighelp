import CryptoKit
import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Loopdy

private final class WikiAccountLifecycleEraserProbe: LoopdyLocalAccountLifecycleErasing {
    var signOutCalls = 0
    var deletionCalls = 0
    func eraseForSignOut() throws { signOutCalls += 1 }
    func erase() throws { deletionCalls += 1 }
}

@MainActor
struct LoopdyLinkAccountStoreTests {
    @Test func accountLifecycleDistinguishesSignOutFromExplicitDeletion() async throws {
        let wrappingKey = Data(repeating: 0x44, count: 32)
        let api = AccountAPIStub(session: .init(accessToken: "fixture", expiresAt: 1_900_000_000, authorizationEpoch: 1))
        let vault = LoopdyLinkMemoryCredentialVault()
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "wiki-lifecycle-fixture", authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 0x33, count: 32))
        let eraser = WikiAccountLifecycleEraserProbe()
        func makeStore() -> LoopdyLinkAccountStore {
            LoopdyLinkAccountStore(api: api, passkeys: PasskeyAuthorizerStub(wrappingKey: wrappingKey), vault: vault,
                localDataEraser: eraser, deviceName: "Fixture", deviceKind: .phone)
        }
        try vault.save(credentials)
        let signedOut = makeStore()
        signedOut.restore()
        await signedOut.signOut()
        #expect(eraser.signOutCalls == 1)
        #expect(eraser.deletionCalls == 0)
        #expect(try vault.load() == nil)
        try vault.save(credentials)
        let deleted = makeStore()
        deleted.restore()
        await deleted.deleteAccount()
        #expect(deleted.state == .signedOut)
        #expect(eraser.signOutCalls == 1)
        #expect(eraser.deletionCalls == 1)
        #expect(try vault.load() == nil)
    }

    @Test func v2ReadyAccountRendersAtPhoneAndTabletSizes() async throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(LoopdyLinkRuntimeCredentials(deviceID: "account-ui-fixture", authorizationEpoch: 1, signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 17, count: 32)))
        let api = AccountAPIStub(session: .init(accessToken: "fixture", expiresAt: 1_900_000_000, authorizationEpoch: 1))
        let store = LoopdyLinkAccountStore(api: api, passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 18, count: 32)), vault: vault, deviceName: "Test iPhone", deviceKind: .phone)
        store.restore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loopdy-v2-account-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
            let screen = NavigationStack {
                LoopdyLinkAccountView(store: store, onReady: {}, onManageDevices: {})
            }
            .environment(\.loopdyUIV2Enabled, true)
            .environment(\.horizontalSizeClass, size.width >= 1000 ? .regular : .compact)
            let controller = UIHostingController(rootView: screen)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(200))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let data = try #require(image.pngData())
            try data.write(to: directory.appendingPathComponent("account-\(Int(size.width))x\(Int(size.height)).png"))
            #expect(store.state == .ready)
            window.isHidden = true
        }
    }
    @Test func accountPresentationUsesResponsiveColumnsAndNeutralGlassActions() {
        #expect(
            LoopdyLinkAccountLayout.mode(
                horizontalSizeClass: .compact,
                usesAccessibilityLayout: false
            ) == .stacked
        )
        #expect(
            LoopdyLinkAccountLayout.mode(
                horizontalSizeClass: .regular,
                usesAccessibilityLayout: false
            ) == .split
        )
        #expect(
            LoopdyLinkAccountLayout.mode(
                horizontalSizeClass: .regular,
                usesAccessibilityLayout: true
            ) == .stacked
        )
        #expect(LoopdyLinkAccountLayout.maximumContentWidth == 920)
        #expect(LoopdyLinkAccountActionPresentation.surfaceRole == .capsuleControl)
        #expect(LoopdyLinkAccountActionPresentation.usesColoredBorder == false)
        #expect(LoopdyLinkAccountConfirmationPresentation.signOut == .centeredAlert)
    }

    @Test func confirmedSignOutDismissesManagementBeforeSecureCleanupBegins() async {
        var events: [String] = []

        await LoopdyLinkAccountSignOutSequence.perform(
            dismissManagement: { events.append("dismiss") },
            signOutSecurely: { events.append("sign-out") }
        )

        #expect(events == ["dismiss", "sign-out"])
    }

    @Test func registrationEstablishesTheOpaqueAccountKeyBeforeSavingDeviceCredentials() async throws {
        let wrappingKey = Data(repeating: 0x22, count: 32)
        let accountKey = Data(repeating: 0x11, count: 32)
        let api = AccountAPIStub(
            session: .init(accessToken: "access-token", expiresAt: 1_788_000_900, authorizationEpoch: 1)
        )
        let vault = LoopdyLinkMemoryCredentialVault()
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: wrappingKey),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone,
            generateAccountKey: { accountKey },
            makeDeviceID: { "mobile-device-1" },
            makeSigningKey: { P256.Signing.PrivateKey() }
        )

        await store.register()

        let loaded = try vault.load()
        let saved = try #require(loaded)
        #expect(saved.deviceID == "mobile-device-1")
        #expect(saved.authorizationEpoch == 1)
        #expect(saved.accountKey == accountKey)
        #expect(api.events == ["options:registration", "verify:registration", "envelope:store", "device:register"])
        #expect(try LoopdyLinkAccountKeyEnvelope.open(
            #require(api.storedEnvelope),
            wrappingKey: wrappingKey
        ) == accountKey)
        #expect(store.state == .ready)
    }

    @Test func authenticationRecoversTheSameAccountKeyAndRegistersAFreshDeviceIdentity() async throws {
        let wrappingKey = Data(repeating: 0x44, count: 32)
        let accountKey = Data(repeating: 0x33, count: 32)
        let api = AccountAPIStub(
            session: .init(accessToken: "access-token", expiresAt: 1_788_000_900, authorizationEpoch: 7),
            envelope: try LoopdyLinkAccountKeyEnvelope.seal(
                accountKey: accountKey,
                wrappingKey: wrappingKey,
                nonce: Data(repeating: 0x55, count: 12)
            )
        )
        let vault = LoopdyLinkMemoryCredentialVault()
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: wrappingKey),
            vault: vault,
            deviceName: "Travel iPhone",
            deviceKind: .phone,
            generateAccountKey: { Issue.record("Sign in must not generate a new account key"); return Data() },
            makeDeviceID: { "mobile-device-2" },
            makeSigningKey: { P256.Signing.PrivateKey() }
        )

        await store.signIn()

        let loaded = try vault.load()
        let saved = try #require(loaded)
        #expect(saved.deviceID == "mobile-device-2")
        #expect(saved.authorizationEpoch == 7)
        #expect(saved.accountKey == accountKey)
        #expect(api.events == ["options:authentication", "verify:authentication", "envelope:load", "device:register"])
        #expect(store.state == .ready)
    }

    @Test func delayedProfileRefreshCannotReplaceANewerLocalIdentity() async throws {
        let api = HeldProfileAPI()
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        api.holdLoad = true
        let refresh = Task { await identity.hydrateAccountProfile(from: account) }
        try await waitForProfileRequest { api.loadContinuation != nil }
        identity.identity = UserIdentity(name: "Updated name", avatarFileName: nil, accountProfileRevision: 2)
        api.loadContinuation?.resume(returning: .init(revision: 1, displayName: "Old name", avatar: nil, updatedAt: 1))
        await refresh.value
        #expect(identity.identity.name == "Updated name")
        #expect(identity.identity.accountProfileRevision == 2)
    }

    @Test func nameOnlySavePersistsAccountNameWithoutReplacingAvatar() async throws {
        let api = HeldProfileAPI()
        let account = try profileAccount(api)
        let defaults = isolatedDefaults()
        let identity = UserIdentityStore(defaults: defaults)
        let avatar = UserProfileAvatar(mimeType: "image/png", byteCount: 5, sha256: "digest", encryptedData: "ciphertext")
        identity.identity = UserIdentity(name: "Old name", avatarFileName: "avatar.png", accountAvatar: avatar, accountProfileRevision: 4)
        try await identity.saveDisplayName("  New name  ", to: account)
        #expect(api.savedName == "New name")
        #expect(api.savedAvatar == avatar)
        #expect(api.savedRevision == 4)
        #expect(identity.identity.name == "New name")
        #expect(identity.identity.avatarFileName == "avatar.png")
        #expect(identity.identity.accountAvatar == avatar)
        #expect(identity.identity.accountProfileRevision == 5)
        #expect(UserIdentityStore(defaults: defaults).identity.name == "New name")
    }

    @Test func avatarSavePreservesAcceptedNameAndEncryptedAccountProfile() async throws {
        let api = HeldProfileAPI()
        let account = try profileAccount(api)
        let directory = FileManager.default.temporaryDirectory.appending(path: "avatar-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = UserIdentityStore(defaults: isolatedDefaults(), avatarDirectory: directory)
        identity.identity.name = "Accepted name"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let avatar = try AvatarImageProcessor().prepare(data: image)
        try await identity.saveAvatar(avatar, to: account)
        #expect(api.savedName == "Accepted name")
        #expect(identity.identity.name == "Accepted name")
        let storedAvatar = try #require(identity.identity.accountAvatar)
        #expect(try account.preparedAvatar(from: storedAvatar).data == avatar.data)
        #expect(try Data(contentsOf: #require(identity.avatarURL())) == avatar.data)
        #expect(identity.identity.accountProfileRevision == 1)
    }

    @Test func revisionConflictRefreshesProfileBeforeManualNameRetry() async throws {
        let api = HeldProfileAPI()
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        let avatar = UserProfileAvatar(mimeType: "image/png", byteCount: 5, sha256: "remote", encryptedData: "remote-avatar")
        api.refreshedProfile = .init(revision: 4, displayName: "Other device name", avatar: avatar, updatedAt: 4)
        api.conflictSave = true
        do {
            try await identity.saveDisplayName("Retained draft", to: account)
            Issue.record("Conflict must remain an explicit rejected save")
        } catch {}
        #expect(api.profileLoadCount == 1)
        #expect(identity.identity.accountProfileRevision == 4)
        #expect(identity.identity.name == "Other device name")
        #expect(identity.identity.accountAvatar == avatar)
        api.conflictSave = false
        try await identity.saveDisplayName("Retained draft", to: account)
        #expect(api.savedRevision == 4)
        #expect(api.savedAvatar == avatar)
        #expect(identity.identity.name == "Retained draft")
        #expect(identity.identity.accountProfileRevision == 5)
    }

    @Test func rejectedNameSavePreservesTheAcceptedIdentity() async throws {
        let api = HeldProfileAPI()
        api.rejectSave = true
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        identity.identity.name = "Accepted name"
        do {
            try await identity.saveDisplayName("Unsaved draft", to: account)
            Issue.record("A rejected account save must throw")
        } catch {}
        #expect(identity.identity.name == "Accepted name")
    }

    @Test func accountResetDuringNameSaveRejectsLatePublication() async throws {
        let api = HeldProfileAPI()
        api.holdSave = true
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        let save = Task { try await identity.saveDisplayName("Old account name", to: account) }
        try await waitForProfileRequest { api.saveContinuation != nil }
        identity.resetForAccountBoundary()
        api.saveContinuation?.resume()
        do {
            try await save.value
            Issue.record("Reset must invalidate the old save")
        } catch {}
        #expect(identity.identity.name == "You")
        #expect(identity.identity.accountProfileRevision == 0)
    }

    @Test func staleRefreshCannotUndoNameSave() async throws {
        let api = HeldProfileAPI()
        api.holdLoad = true
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        let refresh = Task { await identity.hydrateAccountProfile(from: account) }
        try await waitForProfileRequest { api.loadContinuation != nil }
        try await identity.saveDisplayName("Saved name", to: account)
        api.loadContinuation?.resume(returning: .init(revision: 0, displayName: "Old name", avatar: nil, updatedAt: 1))
        await refresh.value
        #expect(identity.identity.name == "Saved name")
        #expect(identity.identity.accountProfileRevision == 1)
    }

    @Test func refreshDuringNameSaveCannotPublishAnOldProfile() async throws {
        let api = HeldProfileAPI()
        api.holdSave = true
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        identity.identity.name = "Accepted name"
        let save = Task { try await identity.saveDisplayName("Saved name", to: account) }
        try await waitForProfileRequest { api.saveContinuation != nil }
        await identity.hydrateAccountProfile(from: account)
        #expect(identity.identity.name == "Accepted name")
        api.saveContinuation?.resume()
        try await save.value
        #expect(identity.identity.name == "Saved name")
    }

    @Test func signedOutAccountCannotPublishLateNameSave() async throws {
        let api = HeldProfileAPI()
        api.holdSave = true
        let account = try profileAccount(api)
        let identity = UserIdentityStore(defaults: isolatedDefaults())
        identity.identity.name = "Accepted name"
        let save = Task { try await identity.saveDisplayName("Old account draft", to: account) }
        try await waitForProfileRequest { api.saveContinuation != nil }
        account.beginSignOut()
        api.saveContinuation?.resume()
        do {
            try await save.value
            Issue.record("Signed-out account must reject late save")
        } catch {}
        #expect(identity.identity.name == "Accepted name")
    }

    private func waitForProfileRequest(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(ready(), "Expected profile request did not begin")
    }

    private func profileAccount(_ api: AccountAPIStub) throws -> LoopdyLinkAccountStore {
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        let account = LoopdyLinkAccountStore(api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault, deviceName: "Test iPhone", deviceKind: .phone)
        account.restore()
        return account
    }

    @Test func signedInAccountProfileHydrationRestoresTheAvatarWithoutOpeningSettings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AccountProfileHydrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let pngData = try #require(Data(base64Encoded: pngBase64))
        let profile = LoopdyLinkAccountProfile(
            revision: 4,
            displayName: "Maya",
            avatar: UserProfileAvatar(
                mimeType: "image/png",
                byteCount: 68,
                sha256: "QxztaRaiohoVbjhwGv5Vu9f4iWn7v8Vtf-CZ1H8mVGA",
                encryptedData: try LoopdyLinkAccountCipher(
                    key: Self.credentials.accountKey
                ).sealProfileAvatar(pngData, nonce: Data(repeating: 0x21, count: 12))
            ),
            updatedAt: 1_788_000_001
        )
        let api = AccountAPIStub(
            session: .init(
                accessToken: "unused",
                expiresAt: 1_788_000_900,
                authorizationEpoch: 1
            ),
            loadedProfile: profile
        )
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        let account = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "Fresh iPhone",
            deviceKind: .phone
        )
        account.restore()
        let identity = UserIdentityStore(
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )

        await identity.hydrateAccountProfile(from: account)

        #expect(identity.identity.name == "Maya")
        #expect(identity.identity.accountProfileRevision == 4)
        let localURL = try #require(identity.avatarURL())
        #expect(try Data(contentsOf: localURL) == pngData)
    }

    @Test func newerAccountAvatarReplacesTheStaleLocalCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AccountProfileHydrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleURL = directory.appending(path: "stale.png")
        try Data("stale-avatar".utf8).write(to: staleURL)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let pngData = try #require(Data(base64Encoded: pngBase64))
        let profile = LoopdyLinkAccountProfile(
            revision: 5,
            displayName: "Maya",
            avatar: UserProfileAvatar(
                mimeType: "image/png",
                byteCount: 68,
                sha256: "QxztaRaiohoVbjhwGv5Vu9f4iWn7v8Vtf-CZ1H8mVGA",
                encryptedData: try LoopdyLinkAccountCipher(
                    key: Self.credentials.accountKey
                ).sealProfileAvatar(pngData, nonce: Data(repeating: 0x31, count: 12))
            ),
            updatedAt: 1_788_000_002
        )
        let api = AccountAPIStub(
            session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1),
            loadedProfile: profile
        )
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        let account = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "Fresh iPhone",
            deviceKind: .phone
        )
        account.restore()
        let identity = UserIdentityStore(defaults: isolatedDefaults(), avatarDirectory: directory)
        identity.identity = UserIdentity(
            name: "Maya",
            avatarFileName: "stale.png",
            accountAvatar: UserProfileAvatar(
                mimeType: "image/png",
                byteCount: 12,
                sha256: "old-avatar-digest",
                encryptedData: "old-avatar-envelope"
            ),
            accountProfileRevision: 4
        )

        await identity.hydrateAccountProfile(from: account)

        let localURL = try #require(identity.avatarURL())
        #expect(identity.identity.accountProfileRevision == 5)
        #expect(try Data(contentsOf: localURL) == pngData)
        #expect(localURL.lastPathComponent != "stale.png")
    }

    @Test func failedRegistrationNeverCommitsLocalCredentials() async throws {
        let api = AccountAPIStub(
            session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1),
            failure: .verify
        )
        let vault = LoopdyLinkMemoryCredentialVault()
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )

        await store.register()

        #expect(try vault.load() == nil)
        #expect(store.state == .failed)
    }

    @Test func restorePublishesOnlyCompleteKeychainCredentials() throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        let credentials = LoopdyLinkRuntimeCredentials(
            deviceID: "restored-device",
            authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x77, count: 32)
        )
        try vault.save(credentials)
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )

        store.restore()

        #expect(store.state == .ready)
        #expect(store.credentials == credentials)
    }

    @Test func recoveryRetriesAKeychainReadAfterProtectedDataBecomesAvailable() async throws {
        let vault = ProtectedDataCredentialVault(credentials: Self.credentials)
        let availability = MutableProtectedDataAvailability(isAvailable: false)
        let notifications = NotificationCenter()
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        let recovery = Task {
            try await store.restoreForRecovery(
                protectedDataAvailability: availability,
                notificationCenter: notifications
            )
        }

        while vault.loadCount < 1 { await Task.yield() }
        #expect(store.state == .working)
        #expect(store.errorMessage == nil)
        availability.isAvailable = true
        vault.isLocked = false
        await Task.yield()
        notifications.post(
            name: LoopdyProtectedDataAvailabilityNotification.didBecomeAvailable,
            object: nil
        )

        #expect(try await recovery.value)
        #expect(vault.loadCount == 2)
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)
    }

    @Test func cancelledRecoveryRestoresThePriorAccountPresentation() async throws {
        let vault = ProtectedDataCredentialVault(credentials: Self.credentials)
        let availability = MutableProtectedDataAvailability(isAvailable: false)
        let notifications = NotificationCenter()
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        let recovery = Task {
            try await store.restoreForRecovery(
                protectedDataAvailability: availability,
                notificationCenter: notifications
            )
        }

        while vault.loadCount < 1 { await Task.yield() }
        #expect(store.state == .working)
        #expect(store.credentials == nil)
        #expect(store.errorMessage == nil)

        recovery.cancel()
        do {
            _ = try await recovery.value
            Issue.record("Cancelled account recovery must not report success")
        } catch is CancellationError {
            // Expected cancellation is not an account failure.
        }

        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func transientRecoveryPreservesAReadyAccountAndItsCredentials() async throws {
        let vault = ProtectedDataCredentialVault(credentials: Self.credentials)
        vault.isLocked = false
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)

        let availability = MutableProtectedDataAvailability(isAvailable: false)
        let notifications = NotificationCenter()
        vault.isLocked = true
        let recovery = Task {
            try await store.restoreForRecovery(
                protectedDataAvailability: availability,
                notificationCenter: notifications
            )
        }

        while vault.loadCount < 2 { await Task.yield() }
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)
        #expect(store.errorMessage == nil)

        availability.isAvailable = true
        vault.isLocked = false
        notifications.post(
            name: LoopdyProtectedDataAvailabilityNotification.didBecomeAvailable,
            object: nil
        )
        #expect(try await recovery.value)
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)
        #expect(store.errorMessage == nil)
    }

    @Test func staleRecoveryCannotPublishAFailureAfterANewerRecoverySucceeds() async throws {
        let vault = SequencedCredentialVault(
            credentials: Self.credentials,
            outcomes: [.credentials, .failure, .credentials, .failure]
        )
        let availability = MutableProtectedDataAvailability(isAvailable: false)
        let notifications = NotificationCenter()
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        let staleRecovery = Task {
            try await store.restoreForRecovery(
                protectedDataAvailability: availability,
                notificationCenter: notifications
            )
        }
        while vault.loadCount < 2 { await Task.yield() }
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)

        availability.isAvailable = true
        let currentRecovery = Task {
            try await store.restoreForRecovery(
                protectedDataAvailability: availability,
                notificationCenter: notifications
            )
        }
        while vault.loadCount < 3 { await Task.yield() }
        #expect(try await currentRecovery.value)
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)

        notifications.post(
            name: LoopdyProtectedDataAvailabilityNotification.didBecomeAvailable,
            object: nil
        )
        do {
            _ = try await staleRecovery.value
            Issue.record("Stale recovery must not report success")
        } catch is CancellationError {
            // A superseded recovery is expected to cancel quietly.
        } catch {
            Issue.record("Stale recovery must not surface its vault error: \(error)")
        }
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)
        #expect(store.errorMessage == nil)
    }

    @Test func signOutRevokesThisDeviceThenErasesAccountScopedLocalData() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = AccountAPIStub(
            session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        await store.signOut()

        #expect(api.events == ["device:revoke"])
        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
    }

    @Test func signOutPublishesSignedOutStateBeforeRemoteRevocationFinishes() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = DeferredRevocationAccountAPI(
            session: .init(
                accessToken: "unused",
                expiresAt: 1_788_000_900,
                authorizationEpoch: 1
            )
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        var presentationCleared = false
        store.onLocalAccountCleared = { [weak store] in
            #expect(store?.credentials == nil)
            #expect(store?.state == .signedOut)
            presentationCleared = true
        }
        let signOut = store.beginSignOut()
        #expect(presentationCleared) // Synchronous, before any revocation await.
        await api.waitUntilRevocationStarts()

        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
        #expect(try vault.load() == nil)

        api.finishRevocation()
        await signOut.value
    }

    @Test func signOutStillClearsCredentialsWhenLocalErasurePartiallyFails() async throws {
        let vault = RecordingCredentialVault()
        let eraser = RecordingLocalDataEraser(events: vault.events, shouldFail: true)
        let store = LoopdyLinkAccountStore(
            api: AccountAPIStub(
                session: .init(accessToken: "unused", expiresAt: 1_788_000_900, authorizationEpoch: 1)
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            deviceName: "This iPhone",
            deviceKind: .phone
        )

        await store.signOut()

        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(store.state == .failed)
        #expect(store.credentials == nil)
        #expect(store.errorMessage == "Some local bighelp data could not be removed securely.")
    }

    @Test func signOutSurfacesRemoteRevocationFailureAfterClearingLocalState() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        var preferenceEraseCount = 0
        let api = AccountAPIStub(
            session: .init(
                accessToken: "unused",
                expiresAt: 1_788_000_900,
                authorizationEpoch: 1
            ),
            failure: .revoke
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            eraseUserPreferences: { preferenceEraseCount += 1 },
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        await store.signOut()

        #expect(api.events == ["device:revoke"])
        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
        #expect(store.errorMessage == "bighelp signed out locally, but this device could not be revoked on the server.")
        #expect(preferenceEraseCount == 0)
    }

    @Test func accountDeletionRequiresFreshPasskeyAuthorizationBeforeErasingLocalState() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        var preferenceEraseCount = 0
        let api = AccountAPIStub(
            session: .init(
                accessToken: "fresh-deletion-session",
                expiresAt: 1_788_000_900,
                authorizationEpoch: 2
            )
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            eraseUserPreferences: { preferenceEraseCount += 1 },
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        await store.deleteAccount()

        #expect(api.events == ["options:authentication", "verify:authentication", "account:delete"])
        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
        #expect(preferenceEraseCount == 1)
    }

    @Test func ambiguousRemoteAccountDeletionPreservesDurableRecoveryState() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = AccountAPIStub(
            session: .init(
                accessToken: "fresh-deletion-session",
                expiresAt: 1_788_000_900,
                authorizationEpoch: 2
            ),
            failure: .delete
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: eraser,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        await store.deleteAccount()

        #expect(try vault.load() == Self.credentials)
        #expect(try vault.loadAccountDeletionTransaction() != nil)
        #expect(vault.events.values.isEmpty)
        #expect(store.credentials == nil)
        #expect(store.state == .working)
        #expect(store.errorMessage == "Finishing your bighelp account deletion. bighelp will retry automatically.")
    }

    @Test func accountDeletionRetriesFinalPurgeWithTheSameFreshBearerBeforeLocalCleanup() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = RetryingDeletionAccountAPI(
            accessToken: "fresh-final-purge-bearer",
            outcomes: [.retryableFailure, .retryableFailure, .success]
        )
        let passkeys = PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32))
        var notificationEraseCount = 0
        var preferenceEraseCount = 0
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: passkeys,
            vault: vault,
            localDataEraser: eraser,
            eraseUserPreferences: { preferenceEraseCount += 1 },
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.eraseNotificationIdentityBeforeAccountDeletion = {
            notificationEraseCount += 1
        }
        api.onDeleteAttempt = { attempt in
            if attempt < 3 {
                #expect(vault.events.values.isEmpty)
                #expect((try? vault.load()) == Self.credentials)
            }
        }
        store.restore()

        await store.deleteAccount()

        #expect(api.deleteAccessTokens == Array(repeating: "fresh-final-purge-bearer", count: 3))
        #expect(api.events == ["options:authentication", "verify:authentication"])
        #expect(passkeys.authorizeCallCount == 1)
        #expect(notificationEraseCount == 1)
        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(preferenceEraseCount == 1)
        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
    }

    @Test func accountDeletionRecoversAfterBoundedFailuresAndAppRestartWithoutAnotherPasskey() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = RetryingDeletionAccountAPI(
            accessToken: "bounded-final-purge-bearer",
            outcomes: [
                .retryableFailure, .retryableFailure, .retryableFailure,
                .retryableFailure, .success,
            ]
        )
        let passkeys = PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32))
        var notificationEraseCount = 0
        var preferenceEraseCount = 0
        func makeStore() -> LoopdyLinkAccountStore {
            let store = LoopdyLinkAccountStore(
                api: api,
                passkeys: passkeys,
                vault: vault,
                localDataEraser: eraser,
                eraseUserPreferences: { preferenceEraseCount += 1 },
                deviceName: "This iPhone",
                deviceKind: .phone
            )
            store.eraseNotificationIdentityBeforeAccountDeletion = {
                notificationEraseCount += 1
            }
            return store
        }
        let store = makeStore()
        store.restore()

        await store.deleteAccount()

        #expect(api.deleteAccessTokens == Array(repeating: "bounded-final-purge-bearer", count: 3))
        #expect(passkeys.authorizeCallCount == 1)
        #expect(notificationEraseCount == 1)
        #expect(vault.events.values.isEmpty)
        #expect(preferenceEraseCount == 0)
        #expect(try vault.load() == Self.credentials)
        #expect(store.state == .working)
        #expect(store.credentials == nil)

        let restartedStore = makeStore()
        restartedStore.restore()
        #expect(restartedStore.state == .working)
        #expect(restartedStore.credentials == nil)

        #expect(await restartedStore.resumePendingAccountDeletion())

        #expect(api.deleteAccessTokens == Array(repeating: "bounded-final-purge-bearer", count: 5))
        #expect(api.events == ["options:authentication", "verify:authentication"])
        #expect(passkeys.authorizeCallCount == 1)
        #expect(notificationEraseCount == 1)
        #expect(vault.events.values == ["local:erase", "vault:delete"])
        #expect(preferenceEraseCount == 1)
        #expect(try vault.load() == nil)
        #expect(restartedStore.state == .signedOut)
        #expect(restartedStore.credentials == nil)
    }

    @Test func pendingAccountDeletionBearerSurvivesAKeychainVaultReopen() throws {
        let service = "app.loopdy.tests.account-deletion.\(UUID().uuidString)"
        let transaction = LoopdyLinkAccountDeletionTransaction(
            accessToken: "keychain-bound-deletion-bearer-with-enough-entropy-0001",
            expiresAt: 1_900_000_000
        )
        let vault = LoopdyLinkKeychainCredentialVault(service: service)
        defer {
            try? vault.deleteAccountDeletionTransaction()
            try? vault.delete()
        }

        try vault.saveAccountDeletionTransaction(transaction)

        let reopened = LoopdyLinkKeychainCredentialVault(service: service)
        #expect(try reopened.loadAccountDeletionTransaction() == transaction)
        try reopened.deleteAccountDeletionTransaction()
        #expect(try vault.loadAccountDeletionTransaction() == nil)
    }

    @Test func oldDeletionTransactionStillFinishesTheServerPurge() async throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        try vault.saveAccountDeletionTransaction(.init(
            accessToken: "expired-deletion-bearer-with-enough-entropy-0001",
            expiresAt: 99
        ))
        let api = RetryingDeletionAccountAPI(
            accessToken: "unused",
            outcomes: [.success]
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone,
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.restore()
        #expect(await store.resumePendingAccountDeletion())

        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
        #expect(api.deleteAccessTokens == ["expired-deletion-bearer-with-enough-entropy-0001"])
        #expect(try vault.load() == nil)
        #expect(try vault.loadAccountDeletionTransaction() == nil)
    }

    @Test func expiredPersistedDeletionBeforeServerAcceptanceRestoresCredentials() async throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        try vault.saveAccountDeletionTransaction(.init(
            accessToken: "expired-unaccepted-deletion-bearer-with-enough-entropy-0001",
            expiresAt: 99
        ))
        let transport = AccountDeletionHTTPTransport(
            status: 401,
            object: [
                "version": 1,
                "error": "account_deletion_not_accepted",
                "message": "Account deletion was not accepted",
            ]
        )
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone,
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.restore()
        #expect(await store.resumePendingAccountDeletion())

        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.url?.path == "/v1/accounts/current")
        #expect(store.state == .ready)
        #expect(store.credentials == Self.credentials)
        #expect(try vault.loadAccountDeletionTransaction() == nil)
    }

    @Test func nonauthoritativeClientErrorKeepsPersistedDeletionFailClosed() async throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        let transaction = LoopdyLinkAccountDeletionTransaction(
            accessToken: "ambiguous-client-deletion-bearer-with-enough-entropy-0001",
            expiresAt: 99
        )
        try vault.saveAccountDeletionTransaction(transaction)
        let transport = AccountDeletionHTTPTransport(
            status: 401,
            object: ["version": 1, "error": "session_expired"]
        )
        let store = LoopdyLinkAccountStore(
            api: LoopdyLinkAPI(
                baseURL: URL(string: "https://link.loopdy.example")!,
                transport: transport
            ),
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            deviceName: "This iPhone",
            deviceKind: .phone
        )

        store.restore()
        #expect(!(await store.resumePendingAccountDeletion()))

        #expect(transport.requests.count == 3)
        #expect(store.state == .working)
        #expect(store.credentials == nil)
        #expect(try vault.load() == Self.credentials)
        #expect(try vault.loadAccountDeletionTransaction() == transaction)
    }

    @Test func ambiguousSuccessfulDeletionResponseKeepsDurableRecoveryState() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let api = RetryingDeletionAccountAPI(
            accessToken: "ambiguous-final-purge-bearer",
            outcomes: [.ambiguousFailure, .ambiguousFailure, .ambiguousFailure]
        )
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32)),
            vault: vault,
            localDataEraser: RecordingLocalDataEraser(events: vault.events),
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.restore()

        await store.deleteAccount()

        #expect(api.deleteAccessTokens == Array(repeating: "ambiguous-final-purge-bearer", count: 3))
        #expect(store.state == .working)
        #expect(store.credentials == nil)
        #expect(try vault.load() == Self.credentials)
        #expect(try vault.loadAccountDeletionTransaction() != nil)
    }

    @Test func accountDeletionDoesNotRetryAuthoritativeRejection() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = RetryingDeletionAccountAPI(
            accessToken: "rejected-final-purge-bearer",
            outcomes: [.authoritativeRejection, .success]
        )
        let passkeys = PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32))
        var notificationEraseCount = 0
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: passkeys,
            vault: vault,
            localDataEraser: eraser,
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.eraseNotificationIdentityBeforeAccountDeletion = {
            notificationEraseCount += 1
        }
        store.restore()

        await store.deleteAccount()

        #expect(api.deleteAccessTokens == ["rejected-final-purge-bearer"])
        #expect(api.events == ["options:authentication", "verify:authentication"])
        #expect(passkeys.authorizeCallCount == 1)
        #expect(notificationEraseCount == 1)
        #expect(vault.events.values.isEmpty)
        #expect(try vault.load() == Self.credentials)
        #expect(store.state == .ready)
    }

    @Test func accountGenerationChangeCancelsFinalPurgeRetries() async throws {
        let vault = RecordingCredentialVault()
        try vault.save(Self.credentials)
        let eraser = RecordingLocalDataEraser(events: vault.events)
        let api = RetryingDeletionAccountAPI(
            accessToken: "cancelled-final-purge-bearer",
            outcomes: [.retryableFailure, .success]
        )
        let passkeys = PasskeyAuthorizerStub(wrappingKey: Data(repeating: 0x22, count: 32))
        var notificationEraseCount = 0
        var preferenceEraseCount = 0
        let store = LoopdyLinkAccountStore(
            api: api,
            passkeys: passkeys,
            vault: vault,
            localDataEraser: eraser,
            eraseUserPreferences: { preferenceEraseCount += 1 },
            deviceName: "This iPhone",
            deviceKind: .phone
        )
        store.eraseNotificationIdentityBeforeAccountDeletion = {
            notificationEraseCount += 1
        }
        api.onDeleteAttempt = { attempt in
            guard attempt == 1 else { return }
            _ = store.beginSignOut()
        }
        store.restore()

        await store.deleteAccount()

        #expect(api.deleteAccessTokens == ["cancelled-final-purge-bearer"])
        #expect(api.events.filter { $0 == "options:authentication" }.count == 1)
        #expect(api.events.filter { $0 == "verify:authentication" }.count == 1)
        #expect(passkeys.authorizeCallCount == 1)
        #expect(notificationEraseCount == 1)
        #expect(preferenceEraseCount == 0)
        #expect(store.state == .signedOut)
        #expect(store.credentials == nil)
    }

    private static let credentials = LoopdyLinkRuntimeCredentials(
            deviceID: "mobile-delete-fixture",
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x66, count: 32)
        )
}

private final class EventRecorder {
    var values: [String] = []
}

@MainActor
private final class ProtectedDataCredentialVault: LoopdyLinkCredentialVault {
    enum Failure: Error { case locked }

    let credentials: LoopdyLinkRuntimeCredentials
    var isLocked = true
    private(set) var loadCount = 0

    init(credentials: LoopdyLinkRuntimeCredentials) {
        self.credentials = credentials
    }

    func load() throws -> LoopdyLinkRuntimeCredentials? {
        loadCount += 1
        if isLocked { throw Failure.locked }
        return credentials
    }

    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws {}
    func delete() throws {}
    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction? { nil }
    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws {}
    func deleteAccountDeletionTransaction() throws {}
}

@MainActor
private final class SequencedCredentialVault: LoopdyLinkCredentialVault {
    enum LoadOutcome {
        case credentials
        case failure
    }

    enum Failure: Error { case unavailable }

    let credentials: LoopdyLinkRuntimeCredentials
    private var outcomes: [LoadOutcome]
    private(set) var loadCount = 0

    init(credentials: LoopdyLinkRuntimeCredentials, outcomes: [LoadOutcome]) {
        self.credentials = credentials
        self.outcomes = outcomes
    }

    func load() throws -> LoopdyLinkRuntimeCredentials? {
        loadCount += 1
        switch outcomes.removeFirst() {
        case .credentials:
            return credentials
        case .failure:
            throw Failure.unavailable
        }
    }

    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws {}
    func delete() throws {}
    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction? { nil }
    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws {}
    func deleteAccountDeletionTransaction() throws {}
}

private final class MutableProtectedDataAvailability: LoopdyProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isAvailable: Bool
    var isProtectedDataAvailable: Bool { isAvailable }

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }
}

private final class RecordingLocalDataEraser: LoopdyLocalAccountDataErasing {
    enum Failure: Error { case erase }

    let events: EventRecorder
    let shouldFail: Bool

    init(events: EventRecorder, shouldFail: Bool = false) {
        self.events = events
        self.shouldFail = shouldFail
    }

    func erase() throws {
        events.values.append("local:erase")
        if shouldFail { throw Failure.erase }
    }
}

private final class RecordingCredentialVault: LoopdyLinkCredentialVault {
    let events = EventRecorder()
    private var credentials: LoopdyLinkRuntimeCredentials?
    private var accountDeletionTransaction: LoopdyLinkAccountDeletionTransaction?

    func load() throws -> LoopdyLinkRuntimeCredentials? { credentials }

    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws {
        self.credentials = credentials
    }

    func delete() throws {
        events.values.append("vault:delete")
        credentials = nil
    }

    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction? {
        accountDeletionTransaction
    }

    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws {
        accountDeletionTransaction = transaction
    }

    func deleteAccountDeletionTransaction() throws {
        accountDeletionTransaction = nil
    }
}

@MainActor
private final class HeldProfileAPI: AccountAPIStub {
    var holdLoad = false
    var holdSave = false
    var rejectSave = false
    var conflictSave = false
    var refreshedProfile: LoopdyLinkAccountProfile?
    var profileLoadCount = 0
    var loadContinuation: CheckedContinuation<LoopdyLinkAccountProfile?, Error>?
    var saveContinuation: CheckedContinuation<Void, Error>?
    var savedName: String?
    var savedAvatar: UserProfileAvatar?
    var savedRevision: Int?

    init() {
        super.init(session: .init(accessToken: "fixture", expiresAt: 1_900_000_000, authorizationEpoch: 1))
    }

    override func loadAccountProfile(credentials: LoopdyLinkRuntimeCredentials) async throws -> LoopdyLinkAccountProfile? {
        profileLoadCount += 1
        if let refreshedProfile { return refreshedProfile }
        if holdLoad {
            return try await withCheckedThrowingContinuation { loadContinuation = $0 }
        }
        return .init(revision: 0, displayName: "Old name", avatar: nil, updatedAt: 1)
    }

    override func saveAccountProfile(displayName: String, avatar: UserProfileAvatar?, expectedRevision: Int, credentials: LoopdyLinkRuntimeCredentials) async throws -> LoopdyLinkAccountProfile {
        savedName = displayName
        savedAvatar = avatar
        savedRevision = expectedRevision
        if conflictSave { throw LoopdyLinkAPIError.requestFailed(status: 409, code: "stale_profile_revision") }
        if rejectSave { throw URLError(.notConnectedToInternet) }
        if holdSave { try await withCheckedThrowingContinuation { saveContinuation = $0 } }
        return try await super.saveAccountProfile(displayName: displayName, avatar: avatar,
            expectedRevision: expectedRevision, credentials: credentials)
    }
}

@MainActor
private class AccountAPIStub: LoopdyLinkAccountAPI {
    enum Failure: Error { case verify, delete, revoke }

    let session: LoopdyLinkAccountSession
    let failure: Failure?
    let loadedProfile: LoopdyLinkAccountProfile?
    var envelope: String?
    private(set) var storedEnvelope: String?
    private(set) var events: [String] = []

    init(
        session: LoopdyLinkAccountSession,
        envelope: String? = nil,
        failure: Failure? = nil,
        loadedProfile: LoopdyLinkAccountProfile? = nil
    ) {
        self.session = session
        self.envelope = envelope
        self.failure = failure
        self.loadedProfile = loadedProfile
    }

    func passkeyOptions(registration: Bool) async throws -> LoopdyLinkPasskeyOptions {
        events.append("options:\(registration ? "registration" : "authentication")")
        return .init(flowID: "passkey-flow", options: ["challenge": "challenge"])
    }

    func verifyPasskey(
        registration: Bool,
        flowID: String,
        response: [String: Any]
    ) async throws -> LoopdyLinkAccountSession {
        events.append("verify:\(registration ? "registration" : "authentication")")
        if failure == .verify { throw Failure.verify }
        return session
    }

    func storeAccountKeyEnvelope(_ envelope: String, accessToken: String) async throws {
        events.append("envelope:store")
        storedEnvelope = envelope
    }

    func loadAccountKeyEnvelope(accessToken: String) async throws -> String {
        events.append("envelope:load")
        return try #require(envelope)
    }

    func saveAccountProfile(
        displayName: String,
        avatar: UserProfileAvatar?,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile {
        LoopdyLinkAccountProfile(
            revision: expectedRevision + 1,
            displayName: displayName,
            avatar: avatar,
            updatedAt: 1_788_000_001
        )
    }

    func loadAccountProfile(
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile? {
        loadedProfile
    }

    func registerDevice(
        accessToken: String,
        credentials: LoopdyLinkRuntimeCredentials,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice {
        events.append("device:register")
        return LoopdyLinkDevice(
            id: credentials.deviceID,
            name: name,
            kind: kind,
            isCurrentDevice: true,
            connection: .online,
            pushState: .permissionRequired,
            lastSeenAt: nil,
            revision: 1
        )
    }

    func deleteAccount(accessToken: String) async throws {
        events.append("account:delete")
        if failure == .delete { throw Failure.delete }
    }

    func revokeCurrentDevice(credentials: LoopdyLinkRuntimeCredentials) async throws {
        events.append("device:revoke")
        if failure == .revoke { throw Failure.revoke }
    }
}

@MainActor
private final class RetryingDeletionAccountAPI: AccountAPIStub {
    enum Outcome {
        case success
        case retryableFailure
        case authoritativeRejection
        case ambiguousFailure
    }

    private var outcomes: [Outcome]
    private(set) var deleteAccessTokens: [String] = []
    var onDeleteAttempt: (@MainActor (Int) -> Void)?

    init(accessToken: String, outcomes: [Outcome]) {
        self.outcomes = outcomes
        super.init(
            session: .init(
                accessToken: accessToken,
                expiresAt: 1_788_000_900,
                authorizationEpoch: 2
            )
        )
    }

    override func deleteAccount(accessToken: String) async throws {
        deleteAccessTokens.append(accessToken)
        onDeleteAttempt?(deleteAccessTokens.count)
        switch outcomes.removeFirst() {
        case .success:
            return
        case .retryableFailure:
            throw LoopdyLinkAPIError.requestFailed(status: 500, code: "internal_error")
        case .authoritativeRejection:
            throw LoopdyLinkAPIError.requestFailed(
                status: 401,
                code: "account_deletion_not_accepted"
            )
        case .ambiguousFailure:
            throw LoopdyLinkAPIError.invalidResponse
        }
    }
}

@MainActor
private final class AccountDeletionHTTPTransport: LoopdyLinkHTTPTransport {
    let status: Int
    let data: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int, object: Any) {
        self.status = status
        self.data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/2",
                headerFields: ["content-type": "application/json"]
            )!
        )
    }
}

@MainActor
private final class DeferredRevocationAccountAPI: AccountAPIStub {
    private var revocationContinuation: CheckedContinuation<Void, Never>?
    private var didStartRevocation = false

    override func revokeCurrentDevice(
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws {
        didStartRevocation = true
        await withCheckedContinuation { continuation in
            revocationContinuation = continuation
        }
    }

    func waitUntilRevocationStarts() async {
        while !didStartRevocation { await Task.yield() }
    }

    func finishRevocation() {
        revocationContinuation?.resume()
        revocationContinuation = nil
    }
}

@MainActor
private final class PasskeyAuthorizerStub: LoopdyLinkPasskeyAuthorizing {
    let wrappingKey: Data
    private(set) var authorizeCallCount = 0

    init(wrappingKey: Data) {
        self.wrappingKey = wrappingKey
    }

    func authorize(
        registration: Bool,
        options: [String: Any]
    ) async throws -> LoopdyLinkPasskeyAuthorization {
        authorizeCallCount += 1
        return .init(response: ["id": "passkey-response"], wrappingKey: wrappingKey)
    }
}
