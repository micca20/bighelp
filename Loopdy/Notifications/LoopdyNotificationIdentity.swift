import CryptoKit
import Foundation
import Security

enum LoopdyNotificationCredentialAuthority: String, Codable, Sendable {
    case legacyAccount
    case notificationOnly
}

struct LoopdyManagedNotificationCredentials: Equatable {
    let authority: LoopdyNotificationCredentialAuthority
    let deviceID: String
    let authorizationEpoch: Int
    let signingPrivateKey: P256.Signing.PrivateKey

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.authority == rhs.authority && lhs.deviceID == rhs.deviceID
            && lhs.authorizationEpoch == rhs.authorizationEpoch
            && lhs.signingPrivateKey.rawRepresentation == rhs.signingPrivateKey.rawRepresentation
    }

    static func legacy(_ value: LoopdyLinkRuntimeCredentials) -> Self {
        Self(authority: .legacyAccount, deviceID: value.deviceID,
             authorizationEpoch: value.authorizationEpoch,
             signingPrivateKey: value.signingPrivateKey)
    }

    var subscriberScope: String {
        authority == .legacyAccount ? "account" : "notification-instance"
    }

    func headers(method: String, path: String, body: Data, timestamp: Int, nonce: String) throws -> [String: String] {
        if authority == .legacyAccount {
            return try LoopdyLinkDeviceSigner(
                deviceID: deviceID,
                authorizationEpoch: authorizationEpoch,
                privateKey: signingPrivateKey
            ).headers(method: method, path: path, body: String(decoding: body, as: UTF8.self),
                      timestamp: timestamp, nonce: nonce).headers
        }
        let digest = LoopdyLinkBase64URL.encode(Data(SHA256.hash(data: body)))
        let transcript = [
            "loopdy-notification-device-v1", method.uppercased(), path, deviceID,
            String(timestamp), nonce, String(authorizationEpoch), digest,
        ].joined(separator: "\n")
        let signature = try signingPrivateKey.signature(for: Data(transcript.utf8))
        return [
            "x-loopdy-notification-installation": deviceID,
            "x-loopdy-timestamp": String(timestamp),
            "x-loopdy-nonce": nonce,
            "x-loopdy-authorization-epoch": String(authorizationEpoch),
            "x-loopdy-signature": LoopdyLinkBase64URL.encode(signature.rawRepresentation),
        ]
    }
}

struct LoopdyNotificationBootstrapIntent: Equatable {
    let installationID: String
    let requestID: String
    let signingPrivateKey: P256.Signing.PrivateKey
    let body: Data
    let timestamp: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.installationID == rhs.installationID && lhs.requestID == rhs.requestID
            && lhs.signingPrivateKey.rawRepresentation == rhs.signingPrivateKey.rawRepresentation
            && lhs.body == rhs.body && lhs.timestamp == rhs.timestamp
    }

    func refreshed(now: Int) throws -> Self {
        try Self.make(installationID: installationID, signingPrivateKey: signingPrivateKey, now: now)
    }

    static func make(
        installationID: String = UUID().uuidString.lowercased(),
        signingPrivateKey: P256.Signing.PrivateKey = .init(),
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Self {
        let requestID = UUID().uuidString.lowercased()
        let nonce = randomBase64URL(count: 24)
        let publicKey = LoopdyLinkDeviceSigner(
            deviceID: installationID,
            authorizationEpoch: 1,
            privateKey: signingPrivateKey
        ).publicKeySPKI
        let transcript = [
            "loopdy-notification-bootstrap-v1", "POST", LoopdyNotificationBrokerClient.bootstrapPath,
            installationID, requestID, String(now), nonce, publicKey,
        ].joined(separator: "\n")
        let proof = try signingPrivateKey.signature(for: Data(transcript.utf8))
        let object: [String: Any] = [
            "version": 1,
            "installationId": installationID,
            "requestId": requestID,
            "publicKeySPKI": publicKey,
            "timestamp": now,
            "nonce": nonce,
            "proof": LoopdyLinkBase64URL.encode(proof.rawRepresentation),
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return Self(installationID: installationID, requestID: requestID,
                    signingPrivateKey: signingPrivateKey, body: body, timestamp: now)
    }

    private static func randomBase64URL(count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return LoopdyLinkBase64URL.encode(Data(bytes))
    }
}

enum LoopdyNotificationIdentityRecord: Equatable {
    case pending(LoopdyNotificationBootstrapIntent)
    case active(LoopdyManagedNotificationCredentials)
}

enum LoopdyNotificationIdentityLoad: Equatable {
    case none
    case current(LoopdyNotificationIdentityRecord)
    case orphaned(LoopdyNotificationIdentityRecord)
}

@MainActor
protocol LoopdyNotificationIdentityVault: AnyObject {
    func load() throws -> LoopdyNotificationIdentityLoad
    func save(_ record: LoopdyNotificationIdentityRecord) throws
    func delete() throws
}

@MainActor
final class LoopdyNotificationKeychainIdentityVault: LoopdyNotificationIdentityVault {
    private struct Stored: Codable {
        enum State: String, Codable { case pending, active }
        let version: Int
        let state: State
        let installationMarker: String
        let installationID: String
        let requestID: String?
        let authorizationEpoch: Int?
        let signingPrivateKey: String
        let bootstrapBody: Data?
        let bootstrapTimestamp: Int?
    }

    private let service: String
    private let account = "notification-identity-v2"
    private let markerFile: URL

    init(
        service: String = "app.loopdy.mobile.notification-identity",
        markerFile: URL = LoopdyManagedNotificationLedger.storageRoot.appending(path: "installation-marker-v1")
    ) {
        self.service = service
        self.markerFile = markerFile
    }

    func load() throws -> LoopdyNotificationIdentityLoad {
        let stored = try loadStored()
        guard let stored else { return .none }
        let record = try decode(stored)
        guard let marker = try readMarker(), marker == stored.installationMarker else {
            return .orphaned(record)
        }
        return .current(record)
    }

    func save(_ record: LoopdyNotificationIdentityRecord) throws {
        let marker = try currentOrNewMarker()
        let stored: Stored
        switch record {
        case .pending(let intent):
            stored = Stored(version: 2, state: .pending, installationMarker: marker,
                installationID: intent.installationID, requestID: intent.requestID,
                authorizationEpoch: nil,
                signingPrivateKey: LoopdyLinkBase64URL.encode(intent.signingPrivateKey.rawRepresentation),
                bootstrapBody: intent.body, bootstrapTimestamp: intent.timestamp)
        case .active(let credentials):
            guard credentials.authority == .notificationOnly else { throw DirectHermesError.invalidCredentials }
            stored = Stored(version: 2, state: .active, installationMarker: marker,
                installationID: credentials.deviceID, requestID: nil,
                authorizationEpoch: credentials.authorizationEpoch,
                signingPrivateKey: LoopdyLinkBase64URL.encode(credentials.signingPrivateKey.rawRepresentation),
                bootstrapBody: nil, bootstrapTimestamp: nil)
        }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 32_768 else { throw DirectHermesError.messageTooLarge }
        let query = keychainQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status != errSecSuccess {
            guard status == errSecDuplicateItem,
                  SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw DirectHermesError.secureStorageUnavailable
            }
        }
        guard case .current(let readback) = try load(), readback == record else {
            throw DirectHermesError.secureStorageUnavailable
        }
    }

    func delete() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DirectHermesError.secureStorageUnavailable
        }
        if FileManager.default.fileExists(atPath: markerFile.path) {
            try FileManager.default.removeItem(at: markerFile)
        }
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func loadStored() throws -> Stored? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count <= 32_768 else {
            throw DirectHermesError.secureStorageUnavailable
        }
        return try JSONDecoder().decode(Stored.self, from: data)
    }

    private func decode(_ stored: Stored) throws -> LoopdyNotificationIdentityRecord {
        guard stored.version == 2, ManagedNotificationValidation.uuid(stored.installationID),
              ManagedNotificationValidation.uuid(stored.installationMarker) else {
            throw DirectHermesError.savedConnectionInvalid
        }
        let key = try P256.Signing.PrivateKey(
            rawRepresentation: LoopdyLinkBase64URL.decode(stored.signingPrivateKey)
        )
        switch stored.state {
        case .pending:
            guard let requestID = stored.requestID, ManagedNotificationValidation.uuid(requestID),
                  let body = stored.bootstrapBody, body.count <= 16_384,
                  let timestamp = stored.bootstrapTimestamp, timestamp > 0 else {
                throw DirectHermesError.savedConnectionInvalid
            }
            return .pending(.init(installationID: stored.installationID, requestID: requestID,
                                  signingPrivateKey: key, body: body, timestamp: timestamp))
        case .active:
            guard let epoch = stored.authorizationEpoch, epoch > 0 else {
                throw DirectHermesError.savedConnectionInvalid
            }
            return .active(.init(authority: .notificationOnly, deviceID: stored.installationID,
                                 authorizationEpoch: epoch, signingPrivateKey: key))
        }
    }

    private func readMarker() throws -> String? {
        guard FileManager.default.fileExists(atPath: markerFile.path) else { return nil }
        let values = try markerFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 64 else {
            throw DirectHermesError.savedConnectionInvalid
        }
        return try String(contentsOf: markerFile, encoding: .utf8)
    }

    private func currentOrNewMarker() throws -> String {
        if let marker = try readMarker() { return marker }
        let marker = UUID().uuidString.lowercased()
        let directory = markerFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                         .posixPermissions: 0o700])
        try Data(marker.utf8).write(to: markerFile,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerFile.path)
        return marker
    }
}

@MainActor
final class LoopdyNotificationBrokerClient: LoopdyManagedNotificationAccountAPI {
    nonisolated static let bootstrapPath = "/v1/notifications/bootstrap"
    static let currentInstallationPath = "/v1/notifications/installations/current"
    static let accountBindingPath = "/v1/notifications/installations/current/account-binding"

    private let legacyAPI: LoopdyLinkAPI
    private let transport: any LoopdyLinkHTTPTransport
    private let now: () -> Date
    private let nonce: () -> String
    private let baseURL = URL(string: "https://link.loopdy.app")!

    init(
        legacyAPI: LoopdyLinkAPI,
        transport: any LoopdyLinkHTTPTransport = LoopdyManagedAccountTransport(),
        now: @escaping () -> Date = Date.init,
        nonce: @escaping () -> String = { LoopdyLinkBase64URL.encode(LoopdyNotificationBrokerClient.randomBytes(count: 24)) }
    ) {
        self.legacyAPI = legacyAPI
        self.transport = transport
        self.now = now
        self.nonce = nonce
    }

    func bootstrap(_ intent: LoopdyNotificationBootstrapIntent) async throws -> LoopdyManagedNotificationCredentials {
        let response = try await request(path: Self.bootstrapPath, method: "POST", body: intent.body, headers: [:])
        guard response.object?["version"]?.integer == 2,
              let credential = response.object?["credential"]?.object,
              credential["scope"]?.string == "notification-only",
              credential["installationId"]?.string == intent.installationID,
              let epoch = credential["authorizationEpoch"]?.integer, epoch == 1 else {
            throw DirectHermesError.invalidResponse
        }
        return .init(authority: .notificationOnly, deviceID: intent.installationID,
                     authorizationEpoch: epoch, signingPrivateKey: intent.signingPrivateKey)
    }

    func revokeInstallation(_ credentials: LoopdyManagedNotificationCredentials) async throws {
        guard credentials.authority == .notificationOnly else { return }
        let response = try await signedRequest(
            path: Self.currentInstallationPath, method: "DELETE", body: Data(), credentials: credentials
        )
        guard response.object?["version"]?.integer == 2,
              response.object?["installation"]?.object?["installationId"]?.string == credentials.deviceID,
              response.object?["installation"]?.object?["state"]?.string == "revoked" else {
            throw DirectHermesError.invalidResponse
        }
    }

    func bindWakeRouting(
        accountCredentials: LoopdyLinkRuntimeCredentials,
        notificationCredentials: LoopdyManagedNotificationCredentials,
        grantID: String
    ) async throws {
        guard notificationCredentials.authority == .notificationOnly,
              ManagedNotificationValidation.uuid(grantID) else {
            throw DirectHermesError.invalidCredentials
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "grantId": grantID,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let timestamp = Int(now().timeIntervalSince1970)
        let installationProof = try notificationCredentials.headers(
            method: "POST", path: Self.accountBindingPath, body: body,
            timestamp: timestamp, nonce: nonce()
        )
        let accountProof = try accountCredentials.signer.headers(
            method: "POST", path: Self.accountBindingPath,
            body: String(decoding: body, as: UTF8.self), timestamp: timestamp, nonce: nonce()
        )
        var headers = installationProof
        let accountHeaderNames = [
            "x-loopdy-device-id": "x-loopdy-account-device-id",
            "x-loopdy-timestamp": "x-loopdy-account-timestamp",
            "x-loopdy-nonce": "x-loopdy-account-nonce",
            "x-loopdy-authorization-epoch": "x-loopdy-account-authorization-epoch",
            "x-loopdy-signature": "x-loopdy-account-signature",
        ]
        for (source, destination) in accountHeaderNames {
            guard let value = accountProof.headers[source] else {
                throw DirectHermesError.invalidCredentials
            }
            headers[destination] = value
        }
        let response = try await request(
            path: Self.accountBindingPath, method: "POST", body: body, headers: headers
        )
        guard response.object?["version"]?.integer == 2,
              let binding = response.object?["binding"]?.object,
              binding["installationId"]?.string == notificationCredentials.deviceID,
              binding["grantId"]?.string == grantID,
              binding["state"]?.string == "active" else {
            throw DirectHermesError.invalidResponse
        }
    }

    func retireLegacyNotificationAuthority(_ credentials: LoopdyManagedNotificationCredentials) async throws {
        guard credentials.authority == .legacyAccount else { throw DirectHermesError.invalidCredentials }
        let response = try await managedNotificationRequest(
            path: LoopdyManagedNotificationService.root + "/buzzkit/identity",
            method: "DELETE",
            body: nil,
            credentials: credentials
        )
        guard response.object?["version"]?.integer == 1,
              response.object?["identity"]?.object?["scope"]?.string == "account",
              response.object?["identity"]?.object?["state"]?.string == "revoked" else {
            throw DirectHermesError.invalidResponse
        }
    }

    func managedNotificationRequest(path: String, method: String, body: Data?,
                                    credentials: LoopdyManagedNotificationCredentials) async throws -> LoopdyJSONValue {
        if credentials.authority == .legacyAccount {
            let legacy = LoopdyLinkRuntimeCredentials(
                deviceID: credentials.deviceID,
                authorizationEpoch: credentials.authorizationEpoch,
                signingPrivateKey: credentials.signingPrivateKey,
                accountKey: Data(repeating: 0, count: 32)
            )
            return try await legacyAPI.managedNotificationRequest(
                path: path, method: method, body: body, credentials: legacy
            )
        }
        return try await signedRequest(path: path, method: method, body: body ?? Data(), credentials: credentials)
    }

    private func signedRequest(path: String, method: String, body: Data,
                               credentials: LoopdyManagedNotificationCredentials) async throws -> LoopdyJSONValue {
        guard path == Self.currentInstallationPath || path == LoopdyManagedNotificationService.root
                || path.hasPrefix(LoopdyManagedNotificationService.root + "/"),
              !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              path.utf8.count <= 512, body.count <= 262_144,
              ["GET", "POST", "PUT", "DELETE"].contains(method), method != "GET" || body.isEmpty else {
            throw LoopdyLinkAPIError.invalidConfiguration
        }
        let timestamp = Int(now().timeIntervalSince1970)
        let proof = try credentials.headers(
            method: method, path: path, body: body, timestamp: timestamp, nonce: nonce()
        )
        return try await request(path: path, method: method, body: body, headers: proof)
    }

    private func request(path: String, method: String, body: Data, headers: [String: String]) async throws -> LoopdyJSONValue {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https", url.host == "link.loopdy.app", url.port == nil else {
            throw LoopdyLinkAPIError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await transport.data(for: request)
        guard response.url == url, !(300...399).contains(response.statusCode), data.count <= 262_144 else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        try DirectHermesWire.validateNesting(data)
        // Check the HTTP status before the envelope version. Error bodies are
        // not guaranteed to carry a version, and gating on it first discards
        // the server's error code (e.g. notification_credentials_revoked),
        // which defeats the revoked-credential retry in enroll().
        guard (200..<300).contains(response.statusCode) else {
            let value = try? JSONDecoder().decode(LoopdyJSONValue.self, from: data)
            let code = value?.object?["error"]?.object?["code"]?.string
                ?? value?.object?["error"]?.string ?? "managed_notification_request_failed"
            throw LoopdyLinkAPIError.requestFailed(status: response.statusCode, code: code)
        }
        let value = try JSONDecoder().decode(LoopdyJSONValue.self, from: data)
        guard let version = value.object?["version"]?.integer, version == 1 || version == 2 else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        return value
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

@MainActor
final class LoopdyNotificationIdentityCoordinator {
    private let vault: any LoopdyNotificationIdentityVault
    private let legacyVault: any LoopdyLinkCredentialVault
    private let broker: LoopdyNotificationBrokerClient
    private let now: () -> Date
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(vault: any LoopdyNotificationIdentityVault, legacyVault: any LoopdyLinkCredentialVault,
         broker: LoopdyNotificationBrokerClient, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.legacyVault = legacyVault
        self.broker = broker
        self.now = now
    }

    func current() throws -> LoopdyManagedNotificationCredentials? {
        switch try vault.load() {
        case .current(.active(let credentials)): return try requireInstallationAuthority(credentials)
        case .current(.pending(_)), .orphaned(_), .none: return nil
        }
    }

    func resolveForEnrollment() async throws -> LoopdyManagedNotificationCredentials {
        try await serialized {
            try await self.resolveForEnrollmentUnserialized()
        }
    }

    /// Explicit setup may replace credentials only after the provider has
    /// authoritatively rejected this exact installation as revoked.
    func replaceRevokedForEnrollment(
        expected: LoopdyManagedNotificationCredentials
    ) async throws -> LoopdyManagedNotificationCredentials {
        try await serialized {
            guard case .current(.active(let current)) = try self.vault.load(),
                  current == expected else {
                throw DirectHermesError.secureStorageChanged
            }
            try self.vault.delete()
            let intent = try LoopdyNotificationBootstrapIntent.make(
                now: Int(self.now().timeIntervalSince1970)
            )
            try self.vault.save(.pending(intent))
            return try await self.complete(intent)
        }
    }

    func erase() async throws {
        try await serialized {
            try await self.eraseUnserialized()
        }
    }

    func bindWakeRouting(
        credentials: LoopdyManagedNotificationCredentials,
        grantID: String
    ) async throws {
        let notificationCredentials = try requireInstallationAuthority(credentials)
        guard try current() == notificationCredentials else {
            throw DirectHermesError.secureStorageChanged
        }
        // Notification-only use remains available without a Link account. When
        // account credentials exist, both authorities must confirm this binding.
        guard let accountCredentials = try legacyVault.load() else { return }
        try await broker.bindWakeRouting(
            accountCredentials: accountCredentials,
            notificationCredentials: notificationCredentials,
            grantID: grantID
        )
        guard try current() == notificationCredentials,
              try legacyVault.load() == accountCredentials else {
            throw DirectHermesError.secureStorageChanged
        }
    }

    private func resolveForEnrollmentUnserialized() async throws -> LoopdyManagedNotificationCredentials {
        // Every enrollment attempt reasserts retirement for the currently loaded
        // Link account. The server's durable retirement marker keeps this request
        // idempotent without deleting the chat credentials that sign it.
        if let legacy = try legacyVault.load() {
            try await broker.retireLegacyNotificationAuthority(.legacy(legacy))
            guard try legacyVault.load() == legacy else {
                throw DirectHermesError.secureStorageChanged
            }
        }

        switch try vault.load() {
        case .current(.active(let credentials)):
            return try requireInstallationAuthority(credentials)
        case .current(.pending(let intent)):
            return try await complete(intent)
        case .orphaned(let record):
            let credentials: LoopdyManagedNotificationCredentials
            switch record {
            case .active(let value): credentials = try requireInstallationAuthority(value)
            case .pending(let intent): credentials = try await recover(intent, persistRefresh: false)
            }
            try await broker.revokeInstallation(credentials)
            try vault.delete()
        case .none:
            break
        }
        let intent = try LoopdyNotificationBootstrapIntent.make(now: Int(now().timeIntervalSince1970))
        try vault.save(.pending(intent))
        return try await complete(intent)
    }

    private func eraseUnserialized() async throws {
        switch try vault.load() {
        case .current(.active(let credentials)), .orphaned(.active(let credentials)):
            try await broker.revokeInstallation(requireInstallationAuthority(credentials))
        case .current(.pending(let intent)):
            let credentials = try await recover(intent)
            try await broker.revokeInstallation(credentials)
        case .orphaned(.pending(let intent)):
            let credentials = try await recover(intent, persistRefresh: false)
            try await broker.revokeInstallation(credentials)
        case .none:
            break
        }
        try vault.delete()
    }

    private func serialized<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await acquireOperationFence()
        defer {
            releaseOperationFence()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireOperationFence() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationFence() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func complete(_ intent: LoopdyNotificationBootstrapIntent) async throws -> LoopdyManagedNotificationCredentials {
        let credentials = try requireInstallationAuthority(await recover(intent))
        try vault.save(.active(credentials))
        return credentials
    }

    private func requireInstallationAuthority(
        _ credentials: LoopdyManagedNotificationCredentials
    ) throws -> LoopdyManagedNotificationCredentials {
        guard credentials.authority == .notificationOnly else { throw DirectHermesError.invalidCredentials }
        return credentials
    }

    private func recover(
        _ intent: LoopdyNotificationBootstrapIntent,
        persistRefresh: Bool = true
    ) async throws -> LoopdyManagedNotificationCredentials {
        do {
            return try await broker.bootstrap(intent)
        } catch LoopdyLinkAPIError.requestFailed(_, let code)
            where ["notification_bootstrap_stale", "notification_bootstrap_replayed"].contains(code) {
            let refreshed = try intent.refreshed(now: Int(now().timeIntervalSince1970))
            if persistRefresh { try vault.save(.pending(refreshed)) }
            return try await broker.bootstrap(refreshed)
        }
    }
}
