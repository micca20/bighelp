import CryptoKit
import Foundation
import Observation
import Security

struct LoopdyLinkPasskeyAuthorization: @unchecked Sendable {
    let response: [String: Any]
    let wrappingKey: Data
}

@MainActor
protocol LoopdyLinkPasskeyAuthorizing: AnyObject {
    func authorize(
        registration: Bool,
        options: [String: Any]
    ) async throws -> LoopdyLinkPasskeyAuthorization
}

enum LoopdyLinkAccountState: Equatable, Sendable {
    case signedOut
    case working
    case ready
    case failed
}

enum LoopdyLinkAccountProfileError: Error, Equatable {
    case signedOut
    case unsupportedAvatarFormat
}

/// Provider metadata can survive sign-out, but explicit deletion erases it.
protocol LoopdyLocalAccountLifecycleErasing: LoopdyLocalAccountDataErasing {
    func eraseForSignOut() throws
}

@MainActor
@Observable
final class LoopdyLinkAccountStore {
    private(set) var state: LoopdyLinkAccountState = .signedOut
    private(set) var credentials: LoopdyLinkRuntimeCredentials? {
        willSet {
            guard credentials != newValue else { return }
            onCredentialsWillChange()
        }
    }
    private(set) var errorMessage: String?

    // Every suspended account operation belongs to one local identity epoch.
    // Signing out invalidates it before returning control to the UI.
    private(set) var accountGeneration = UUID()
    private(set) var needsLocalCleanup = false
    /// Production App composition installs the notification boundary hook here.
    /// It runs synchronously before any credential coordinate is replaced.
    var onCredentialsWillChange: @MainActor () -> Void = {}
    var onLocalAccountCleared: @MainActor () -> Void = {}
    var onLocalAccountErasureCompleted: @MainActor () -> Void = {}
    /// Account deletion is also an explicit notification-data erasure. App
    /// composition installs a fail-closed hook that revokes and reads back the
    /// notification installation before either account or local data is erased.
    var eraseNotificationIdentityBeforeAccountDeletion: (@MainActor () async throws -> Void)?
    private var suppressCredentialRestore = false
    private var deletingAccountData = false
    private var recoveryGeneration = UUID()
    private var pendingAccountDeletion: LoopdyLinkAccountDeletionTransaction?

    private let api: any LoopdyLinkAccountAPI
    private let passkeys: any LoopdyLinkPasskeyAuthorizing
    private let vault: any LoopdyLinkCredentialVault
    private let localDataEraser: any LoopdyLocalAccountDataErasing
    private let eraseUserPreferences: () -> Void
    private let deviceName: String
    private let deviceKind: LoopdyLinkDeviceKind
    private let generateAccountKey: () throws -> Data
    private let makeDeviceID: () -> String
    private let makeSigningKey: () -> P256.Signing.PrivateKey
    private let now: () -> Date

    // `expiresAt` remains in the serialized transaction for compatibility, but
    // it never retires the only bearer capable of completing deletion cleanup.
    private static let accountDeletionRecoveryMetadataTTL = 86_400

    init(
        api: any LoopdyLinkAccountAPI,
        passkeys: any LoopdyLinkPasskeyAuthorizing,
        vault: any LoopdyLinkCredentialVault,
        localDataEraser: any LoopdyLocalAccountDataErasing = LoopdyNoopLocalAccountDataEraser(),
        eraseUserPreferences: @escaping () -> Void = {},
        deviceName: String,
        deviceKind: LoopdyLinkDeviceKind,
        generateAccountKey: @escaping () throws -> Data = {
            try LoopdyLinkAccountStore.secureRandomBytes(count: 32)
        },
        makeDeviceID: @escaping () -> String = {
            LoopdyLinkBase64URL.encode(
                (try? LoopdyLinkAccountStore.secureRandomBytes(count: 24)) ?? Data()
            )
        },
        makeSigningKey: @escaping () -> P256.Signing.PrivateKey = {
            P256.Signing.PrivateKey()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.passkeys = passkeys
        self.vault = vault
        self.localDataEraser = localDataEraser
        self.eraseUserPreferences = eraseUserPreferences
        self.deviceName = deviceName
        self.deviceKind = deviceKind
        self.generateAccountKey = generateAccountKey
        self.makeDeviceID = makeDeviceID
        self.makeSigningKey = makeSigningKey
        self.now = now
    }

    func restore() {
        guard !suppressCredentialRestore, state != .working else { return }
        accountGeneration = UUID()
        recoveryGeneration = UUID()
        do {
            if let transaction = try vault.loadAccountDeletionTransaction() {
                pendingAccountDeletion = transaction
                suppressCredentialRestore = true
                credentials = nil
                state = .working
                errorMessage = "Finishing your bighelp account deletion…"
                return
            }
            credentials = try vault.load()
            state = credentials == nil ? .signedOut : .ready
            errorMessage = nil
        } catch {
            credentials = nil
            state = .failed
            errorMessage = "Secure Loopdy Link credentials could not be loaded."
        }
    }

    /// Re-reads the canonical Keychain coordinate for a launch/foreground
    /// recovery. A locked device is a transient failure, not a signed-out
    /// account, so wait for protected data and retry the same coordinate once.
    @discardableResult
    func restoreForRecovery(
        protectedDataAvailability: any LoopdyProtectedDataAvailabilityProviding = LoopdySystemProtectedDataAvailability(),
        notificationCenter: NotificationCenter = .default
    ) async throws -> Bool {
        if pendingAccountDeletion != nil {
            return await resumePendingAccountDeletion()
        }
        guard !suppressCredentialRestore else { return false }
        guard state != .working else { throw CancellationError() }
        let generation = accountGeneration
        let recoveryGeneration = UUID()
        self.recoveryGeneration = recoveryGeneration
        let previousState = state
        let previousCredentials = credentials
        let previousErrorMessage = errorMessage
        var protectedDataNotifications = notificationCenter.notifications(
            named: LoopdyProtectedDataAvailabilityNotification.didBecomeAvailable
        ).makeAsyncIterator()

        func requireCurrentRecovery() throws {
            try requireCurrentAccount(generation)
            guard recoveryGeneration == self.recoveryGeneration else {
                throw CancellationError()
            }
        }

        func restorePreviousPresentationIfCurrent() {
            guard generation == accountGeneration,
                  recoveryGeneration == self.recoveryGeneration else { return }
            credentials = previousCredentials
            state = previousState
            errorMessage = previousErrorMessage
        }

        func publishFailure(_ error: Error) throws -> Never {
            guard generation == accountGeneration,
                  recoveryGeneration == self.recoveryGeneration else {
                throw CancellationError()
            }
            if previousCredentials == nil {
                credentials = nil
                state = .failed
                errorMessage = "Secure Loopdy Link credentials could not be loaded. Try again."
            } else {
                restorePreviousPresentationIfCurrent()
            }
            throw error
        }

        if previousCredentials == nil {
            state = .working
            errorMessage = nil
        }

        do {
            let restoredCredentials = try vault.load()
            try requireCurrentRecovery()
            credentials = restoredCredentials
            state = restoredCredentials == nil ? .signedOut : .ready
            errorMessage = nil
            return restoredCredentials != nil
        } catch is CancellationError {
            restorePreviousPresentationIfCurrent()
            throw CancellationError()
        } catch {
            guard generation == accountGeneration,
                  recoveryGeneration == self.recoveryGeneration else {
                throw CancellationError()
            }
            guard !protectedDataAvailability.isProtectedDataAvailable else {
                try publishFailure(error)
            }
        }

        while true {
            do {
                try requireCurrentRecovery()
            } catch {
                restorePreviousPresentationIfCurrent()
                throw CancellationError()
            }
            if !protectedDataAvailability.isProtectedDataAvailable {
                do {
                    guard await protectedDataNotifications.next() != nil else {
                        throw CancellationError()
                    }
                } catch {
                    restorePreviousPresentationIfCurrent()
                    throw CancellationError()
                }
                continue
            }
            do {
                let restoredCredentials = try vault.load()
                try requireCurrentRecovery()
                credentials = restoredCredentials
                state = restoredCredentials == nil ? .signedOut : .ready
                errorMessage = nil
                return restoredCredentials != nil
            } catch is CancellationError {
                restorePreviousPresentationIfCurrent()
                throw CancellationError()
            } catch {
                try publishFailure(error)
            }
        }
    }

    func register() async {
        await establishAccount(registration: true)
    }

    func signIn() async {
        await establishAccount(registration: false)
    }

    /// Authorizes a Watch-created device identity without copying this phone's
    /// signing key. The returned account grant is encrypted to the Watch's
    /// one-time agreement key and can only be opened by that Watch.
    func authorizeWatchEnrollment(
        _ request: WatchLoopdyEnrollmentRequest,
        baseURL: URL
    ) async throws -> WatchLoopdyEnrollmentGrant {
        guard state != .working else { throw LoopdyLinkAPIError.invalidConfiguration }
        let generation = accountGeneration
        let previousState = state
        recoveryGeneration = UUID()
        state = .working
        defer {
            if accountGeneration == generation, state == .working { state = previousState }
        }
        let options = try await api.passkeyOptions(registration: false)
        try requireCurrentAccount(generation)
        let authorization = try await passkeys.authorize(
            registration: false,
            options: options.options
        )
        try requireCurrentAccount(generation)
        guard authorization.wrappingKey.count == 32 else {
            throw LoopdyLinkCryptoError.invalidKey
        }
        let session = try await api.verifyPasskey(
            registration: false,
            flowID: options.flowID,
            response: authorization.response
        )
        try requireCurrentAccount(generation)
        let accountKey = try LoopdyLinkAccountKeyEnvelope.open(
            await api.loadAccountKeyEnvelope(accessToken: session.accessToken),
            wrappingKey: authorization.wrappingKey
        )
        try requireCurrentAccount(generation)
        _ = try await api.registerExternalDevice(
            accessToken: session.accessToken,
            deviceID: request.deviceID,
            publicKeySPKI: request.publicKeySPKI,
            accountKey: accountKey,
            name: request.deviceName,
            kind: .computer
        )
        try requireCurrentAccount(generation)
        let agreementKey = try LoopdyLinkBase64URL.decode(request.agreementPublicKey)
        let envelope = try LoopdyLinkHostGrant.seal(
            accountKey: accountKey,
            flowID: request.requestID,
            deviceID: request.deviceID,
            hostAgreementPublicKey: agreementKey
        )
        return try WatchLoopdyEnrollmentGrant(
            requestID: request.requestID,
            deviceID: request.deviceID,
            baseURL: baseURL.absoluteString,
            authorizationEpoch: session.authorizationEpoch,
            grantEnvelope: envelope
        )
    }

    /// Clears the local identity synchronously. Only the captured old device is
    /// revoked asynchronously; that completion may never mutate a newer account.
    @discardableResult
    func beginSignOut() -> Task<Void, Never> {
        let currentCredentials = credentials
        accountGeneration = UUID()
        recoveryGeneration = UUID()
        let generation = accountGeneration
        suppressCredentialRestore = true
        clearLocalAccountData()
        return Task { [weak self, api] in
            guard let currentCredentials else { return }
            do {
                try await api.revokeCurrentDevice(credentials: currentCredentials)
            } catch {
                guard let self, self.accountGeneration == generation,
                      self.credentials == nil, self.errorMessage == nil else { return }
                self.errorMessage = "bighelp signed out locally, but this device could not be revoked on the server."
            }
        }
    }

    func signOut() async {
        await beginSignOut().value
    }

    func deleteAccount() async {
        if let transaction = pendingAccountDeletion {
            await finishPendingAccountDeletion(
                transaction,
                generation: accountGeneration,
                mayRollbackBeforeServerAcceptance: true
            )
            return
        }
        guard state != .working, credentials != nil else { return }
        let generation = accountGeneration
        recoveryGeneration = UUID()
        state = .working
        errorMessage = nil

        do {
            let options = try await api.passkeyOptions(registration: false)
            try requireCurrentAccount(generation)
            let authorization = try await passkeys.authorize(
                registration: false,
                options: options.options
            )
            try requireCurrentAccount(generation)
            let session = try await api.verifyPasskey(
                registration: false,
                flowID: options.flowID,
                response: authorization.response
            )
            try requireCurrentAccount(generation)
            if let eraseNotificationIdentityBeforeAccountDeletion {
                try await eraseNotificationIdentityBeforeAccountDeletion()
                try requireCurrentAccount(generation)
            }
            let transaction = LoopdyLinkAccountDeletionTransaction(
                accessToken: session.accessToken,
                expiresAt: Int(now().timeIntervalSince1970) + Self.accountDeletionRecoveryMetadataTTL
            )
            try vault.saveAccountDeletionTransaction(transaction)
            try requireCurrentAccount(generation)
            pendingAccountDeletion = transaction
            suppressCredentialRestore = true
            credentials = nil
            state = .working
            onLocalAccountCleared()
            await finishPendingAccountDeletion(
                transaction,
                generation: generation,
                mayRollbackBeforeServerAcceptance: true
            )
        } catch {
            guard generation == accountGeneration else { return }
            state = .ready
            errorMessage = "Your bighelp account could not be deleted. Try again."
        }
    }

    func accountAvatar(from avatar: PreparedAvatar) throws -> UserProfileAvatar {
        guard let credentials else { throw LoopdyLinkAccountProfileError.signedOut }
        let mimeType: String
        switch avatar.fileExtension {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            throw LoopdyLinkAccountProfileError.unsupportedAvatarFormat
        }
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        return UserProfileAvatar(
            mimeType: mimeType,
            byteCount: avatar.data.count,
            sha256: LoopdyLinkBase64URL.encode(Data(SHA256.hash(data: avatar.data))),
            encryptedData: try cipher.sealProfileAvatar(avatar.data)
        )
    }

    func saveProfile(
        displayName: String,
        avatar: UserProfileAvatar?,
        expectedRevision: Int
    ) async throws -> LoopdyLinkAccountProfile {
        guard let credentials else { throw LoopdyLinkAccountProfileError.signedOut }
        let generation = accountGeneration
        let profile = try await api.saveAccountProfile(
            displayName: displayName,
            avatar: avatar,
            expectedRevision: expectedRevision,
            credentials: credentials
        )
        try requireCurrentAccount(generation)
        return profile
    }

    func loadProfile() async throws -> LoopdyLinkAccountProfile? {
        guard let credentials else { throw LoopdyLinkAccountProfileError.signedOut }
        let generation = accountGeneration
        let profile = try await api.loadAccountProfile(credentials: credentials)
        try requireCurrentAccount(generation)
        return profile
    }

    func preparedAvatar(from avatar: UserProfileAvatar) throws -> PreparedAvatar {
        guard let credentials else { throw LoopdyLinkAccountProfileError.signedOut }
        let fileExtension: String
        switch avatar.mimeType {
        case "image/png":
            fileExtension = "png"
        case "image/jpeg":
            fileExtension = "jpg"
        case "image/webp":
            fileExtension = "webp"
        default:
            throw LoopdyLinkAccountProfileError.unsupportedAvatarFormat
        }
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        let data = try cipher.openProfileAvatar(avatar.encryptedData)
        guard
            data.count == avatar.byteCount,
            LoopdyLinkBase64URL.encode(Data(SHA256.hash(data: data))) == avatar.sha256
        else { throw LoopdyLinkCryptoError.invalidPlaintext }
        return PreparedAvatar(data: data, fileExtension: fileExtension, pixelSize: .zero)
    }

    private func clearLocalAccountData() {
        credentials = nil
        state = .signedOut
        onLocalAccountCleared()
        errorMessage = nil
        needsLocalCleanup = false
        var localErasureFailed = false
        do { try LoopdyDirectProtectedStore().eraseAll() }
        catch { localErasureFailed = true }
        do {
            if !deletingAccountData, let lifecycle = localDataEraser as? any LoopdyLocalAccountLifecycleErasing {
                try lifecycle.eraseForSignOut()
            } else { try localDataEraser.erase() }
        } catch {
            localErasureFailed = true
        }

        do {
            try vault.delete()
            credentials = nil
            if localErasureFailed {
                needsLocalCleanup = true
                errorMessage = "Some local bighelp data could not be removed securely."
                state = .failed
            } else {
                state = .signedOut
                errorMessage = nil
                deletingAccountData = false
                onLocalAccountErasureCompleted()
            }
        } catch {
            needsLocalCleanup = true
            errorMessage = "Loopdy Link could not be signed out securely."
            state = .failed
        }
    }

    private func establishAccount(registration: Bool) async {
        guard state != .working, !needsLocalCleanup, pendingAccountDeletion == nil else { return }
        accountGeneration = UUID()
        recoveryGeneration = UUID()
        let generation = accountGeneration
        state = .working
        errorMessage = nil
        do {
            let options = try await api.passkeyOptions(registration: registration)
            try requireCurrentAccount(generation)
            let authorization = try await passkeys.authorize(
                registration: registration,
                options: options.options
            )
            try requireCurrentAccount(generation)
            guard authorization.wrappingKey.count == 32 else {
                throw LoopdyLinkCryptoError.invalidKey
            }
            let session = try await api.verifyPasskey(
                registration: registration,
                flowID: options.flowID,
                response: authorization.response
            )
            try requireCurrentAccount(generation)
            let accountKey: Data
            if registration {
                accountKey = try generateAccountKey()
                guard accountKey.count == 32 else { throw LoopdyLinkCryptoError.invalidKey }
                let envelope = try LoopdyLinkAccountKeyEnvelope.seal(
                    accountKey: accountKey,
                    wrappingKey: authorization.wrappingKey
                )
                try await api.storeAccountKeyEnvelope(
                    envelope,
                    accessToken: session.accessToken
                )
            } else {
                accountKey = try LoopdyLinkAccountKeyEnvelope.open(
                    await api.loadAccountKeyEnvelope(accessToken: session.accessToken),
                    wrappingKey: authorization.wrappingKey
                )
            }
            try requireCurrentAccount(generation)
            let deviceID = makeDeviceID()
            guard !deviceID.isEmpty, session.authorizationEpoch > 0 else {
                throw LoopdyLinkCryptoError.invalidKey
            }
            let established = LoopdyLinkRuntimeCredentials(
                deviceID: deviceID,
                authorizationEpoch: session.authorizationEpoch,
                signingPrivateKey: makeSigningKey(),
                accountKey: accountKey
            )
            _ = try await api.registerDevice(
                accessToken: session.accessToken,
                credentials: established,
                name: deviceName,
                kind: deviceKind
            )
            try requireCurrentAccount(generation)
            try vault.save(established)
            suppressCredentialRestore = false
            credentials = established
            state = .ready
        } catch {
            guard generation == accountGeneration else { return }
            credentials = nil
            state = .failed
            errorMessage = registration
                ? "Your secure bighelp account could not be created. Try again."
                : "Loopdy Link sign-in could not be completed. Try again."
        }
    }

    @discardableResult
    func resumePendingAccountDeletion() async -> Bool {
        guard let transaction = pendingAccountDeletion else { return false }
        state = .working
        errorMessage = "Finishing your bighelp account deletion…"
        await finishPendingAccountDeletion(
            transaction,
            generation: accountGeneration,
            mayRollbackBeforeServerAcceptance: true
        )
        return pendingAccountDeletion == nil
    }

    private func finishPendingAccountDeletion(
        _ transaction: LoopdyLinkAccountDeletionTransaction,
        generation: UUID,
        mayRollbackBeforeServerAcceptance: Bool
    ) async {
        var serverAcknowledged = false
        do {
            try await deleteAccountWithFinalPurgeRetries(
                accessToken: transaction.accessToken,
                generation: generation
            )
            serverAcknowledged = true
            try requireCurrentAccount(generation)
            eraseUserPreferences()
            deletingAccountData = true
            clearLocalAccountData()
            guard !needsLocalCleanup, state == .signedOut else {
                throw LoopdyLinkAPIError.invalidResponse
            }
            // Retire the recovery bearer last. A crash anywhere after the server
            // acknowledgement can then repeat the idempotent purge and cleanup.
            try vault.deleteAccountDeletionTransaction()
            pendingAccountDeletion = nil
            accountGeneration = UUID()
        } catch {
            guard generation == accountGeneration else { return }
            if mayRollbackBeforeServerAcceptance,
               !serverAcknowledged,
               Self.isAuthoritativeAccountDeletionRejection(error) {
                do {
                    try vault.deleteAccountDeletionTransaction()
                    pendingAccountDeletion = nil
                    suppressCredentialRestore = false
                    credentials = try vault.load()
                    state = credentials == nil ? .signedOut : .ready
                    errorMessage = "Your bighelp account could not be deleted. Try again."
                    return
                } catch {
                    // Failure to retire the durable deletion transaction must
                    // remain fail-closed rather than restoring normal account use.
                }
            }
            credentials = nil
            state = .working
            errorMessage = "Finishing your bighelp account deletion. bighelp will retry automatically."
        }
    }

    private func deleteAccountWithFinalPurgeRetries(
        accessToken: String,
        generation: UUID
    ) async throws {
        // DELETE is idempotent and the server binds its pending-purge receipt to
        // this exact bearer. Keep retries inside this authorization operation so
        // passkey approval and notification identity erasure are never repeated.
        let maximumAttempts = 3
        var attempt = 1
        while true {
            do {
                try await api.deleteAccount(accessToken: accessToken)
                try requireCurrentAccount(generation)
                return
            } catch {
                try requireCurrentAccount(generation)
                guard attempt < maximumAttempts,
                      Self.isRetryableAccountDeletionError(error) else {
                    throw error
                }
                attempt += 1
                await Task.yield()
                try requireCurrentAccount(generation)
            }
        }
    }

    private static func isRetryableAccountDeletionError(_ error: Error) -> Bool {
        !isAuthoritativeAccountDeletionRejection(error)
    }

    private static func isAuthoritativeAccountDeletionRejection(_ error: Error) -> Bool {
        guard let apiError = error as? LoopdyLinkAPIError,
              case let .requestFailed(status, code) = apiError else { return false }
        // Link emits this deletion-specific coordinate only after finding
        // neither a completed receipt nor pending authority for the bearer.
        return status == 401 && code == "account_deletion_not_accepted"
    }

    private func requireCurrentAccount(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw LoopdyLinkCryptoError.invalidKey
        }
        return Data(bytes)
    }
}
