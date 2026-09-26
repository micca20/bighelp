import CryptoKit
import Foundation
import Security

struct LoopdyLinkRuntimeCredentials: Equatable {
    let deviceID: String
    let authorizationEpoch: Int
    let signingPrivateKey: P256.Signing.PrivateKey
    let accountKey: Data

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deviceID == rhs.deviceID &&
            lhs.authorizationEpoch == rhs.authorizationEpoch &&
            lhs.signingPrivateKey.rawRepresentation == rhs.signingPrivateKey.rawRepresentation &&
            lhs.accountKey == rhs.accountKey
    }

    var signer: LoopdyLinkDeviceSigner {
        LoopdyLinkDeviceSigner(
            deviceID: deviceID,
            authorizationEpoch: authorizationEpoch,
            privateKey: signingPrivateKey
        )
    }
}

struct LoopdyLinkAccountDeletionTransaction: Codable, Equatable {
    let version: Int
    let accessToken: String
    let expiresAt: Int

    init(accessToken: String, expiresAt: Int) {
        self.version = 1
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    var isValid: Bool {
        version == 1 &&
            (32...128).contains(accessToken.utf8.count) &&
            accessToken.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 95
            } &&
            expiresAt > 0
    }
}

@MainActor
protocol LoopdyLinkCredentialVault: AnyObject {
    func load() throws -> LoopdyLinkRuntimeCredentials?
    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws
    func delete() throws
    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction?
    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws
    func deleteAccountDeletionTransaction() throws
}

@MainActor
final class LoopdyLinkMemoryCredentialVault: LoopdyLinkCredentialVault {
    private var value: LoopdyLinkRuntimeCredentials?
    private var accountDeletionTransaction: LoopdyLinkAccountDeletionTransaction?

    func load() throws -> LoopdyLinkRuntimeCredentials? { value }
    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws { value = credentials }
    func delete() throws { value = nil }
    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction? {
        accountDeletionTransaction
    }
    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws {
        accountDeletionTransaction = transaction
    }
    func deleteAccountDeletionTransaction() throws { accountDeletionTransaction = nil }
}

@MainActor
final class LoopdyLinkKeychainCredentialVault: LoopdyLinkCredentialVault {
    private struct Stored: Codable {
        let version: Int
        let deviceID: String
        let authorizationEpoch: Int
        let signingPrivateKey: String
        let accountKey: String
    }

    private let service: String
    private let account = "runtime-v1"
    private let accountDeletionAccount = "account-deletion-v1"

    init(service: String = "app.loopdy.mobile.link") {
        self.service = service
    }

    func load() throws -> LoopdyLinkRuntimeCredentials? {
        guard let data = try loadData(account: account) else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard
            stored.version == 1,
            stored.authorizationEpoch > 0,
            !stored.deviceID.isEmpty
        else { throw VaultError.invalidData }
        let privateKey = try P256.Signing.PrivateKey(
            rawRepresentation: LoopdyLinkBase64URL.decode(stored.signingPrivateKey)
        )
        let accountKey = try LoopdyLinkBase64URL.decode(stored.accountKey)
        guard accountKey.count == 32 else { throw VaultError.invalidData }
        return LoopdyLinkRuntimeCredentials(
            deviceID: stored.deviceID,
            authorizationEpoch: stored.authorizationEpoch,
            signingPrivateKey: privateKey,
            accountKey: accountKey
        )
    }

    func save(_ credentials: LoopdyLinkRuntimeCredentials) throws {
        let stored = Stored(
            version: 1,
            deviceID: credentials.deviceID,
            authorizationEpoch: credentials.authorizationEpoch,
            signingPrivateKey: LoopdyLinkBase64URL.encode(
                credentials.signingPrivateKey.rawRepresentation
            ),
            accountKey: LoopdyLinkBase64URL.encode(credentials.accountKey)
        )
        try saveData(try JSONEncoder().encode(stored), account: account)
    }

    func delete() throws {
        try deleteData(account: account)
    }

    func loadAccountDeletionTransaction() throws -> LoopdyLinkAccountDeletionTransaction? {
        guard let data = try loadData(account: accountDeletionAccount) else { return nil }
        let transaction = try JSONDecoder().decode(LoopdyLinkAccountDeletionTransaction.self, from: data)
        guard transaction.isValid else { throw VaultError.invalidData }
        return transaction
    }

    func saveAccountDeletionTransaction(_ transaction: LoopdyLinkAccountDeletionTransaction) throws {
        guard transaction.isValid else { throw VaultError.invalidData }
        try saveData(try JSONEncoder().encode(transaction), account: accountDeletionAccount)
    }

    func deleteAccountDeletionTransaction() throws {
        try deleteData(account: accountDeletionAccount)
    }

    private func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultError.keychain(status)
        }
        return data
    }

    private func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let addStatus = SecItemAdd(
            query.merging(attributes) { _, new in new } as CFDictionary,
            nil
        )
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else { throw VaultError.keychain(addStatus) }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else { throw VaultError.keychain(updateStatus) }
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status)
        }
    }

    private enum VaultError: Error {
        case invalidData
        case keychain(OSStatus)
    }
}
