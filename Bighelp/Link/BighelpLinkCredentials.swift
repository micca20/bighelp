import CryptoKit
import Foundation
import Security

struct BighelpLinkRuntimeCredentials: Equatable {
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

    var signer: BighelpLinkDeviceSigner {
        BighelpLinkDeviceSigner(
            deviceID: deviceID,
            authorizationEpoch: authorizationEpoch,
            privateKey: signingPrivateKey
        )
    }
}

struct BighelpLinkAccountDeletionTransaction: Codable, Equatable {
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
protocol BighelpLinkCredentialVault: AnyObject {
    func load() throws -> BighelpLinkRuntimeCredentials?
    func save(_ credentials: BighelpLinkRuntimeCredentials) throws
    func delete() throws
    func loadAccountDeletionTransaction() throws -> BighelpLinkAccountDeletionTransaction?
    func saveAccountDeletionTransaction(_ transaction: BighelpLinkAccountDeletionTransaction) throws
    func deleteAccountDeletionTransaction() throws
}

@MainActor
final class BighelpLinkMemoryCredentialVault: BighelpLinkCredentialVault {
    private var value: BighelpLinkRuntimeCredentials?
    private var accountDeletionTransaction: BighelpLinkAccountDeletionTransaction?

    func load() throws -> BighelpLinkRuntimeCredentials? { value }
    func save(_ credentials: BighelpLinkRuntimeCredentials) throws { value = credentials }
    func delete() throws { value = nil }
    func loadAccountDeletionTransaction() throws -> BighelpLinkAccountDeletionTransaction? {
        accountDeletionTransaction
    }
    func saveAccountDeletionTransaction(_ transaction: BighelpLinkAccountDeletionTransaction) throws {
        accountDeletionTransaction = transaction
    }
    func deleteAccountDeletionTransaction() throws { accountDeletionTransaction = nil }
}

@MainActor
final class BighelpLinkKeychainCredentialVault: BighelpLinkCredentialVault {
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

    func load() throws -> BighelpLinkRuntimeCredentials? {
        guard let data = try loadData(account: account) else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard
            stored.version == 1,
            stored.authorizationEpoch > 0,
            !stored.deviceID.isEmpty
        else { throw VaultError.invalidData }
        let privateKey = try P256.Signing.PrivateKey(
            rawRepresentation: BighelpLinkBase64URL.decode(stored.signingPrivateKey)
        )
        let accountKey = try BighelpLinkBase64URL.decode(stored.accountKey)
        guard accountKey.count == 32 else { throw VaultError.invalidData }
        return BighelpLinkRuntimeCredentials(
            deviceID: stored.deviceID,
            authorizationEpoch: stored.authorizationEpoch,
            signingPrivateKey: privateKey,
            accountKey: accountKey
        )
    }

    func save(_ credentials: BighelpLinkRuntimeCredentials) throws {
        let stored = Stored(
            version: 1,
            deviceID: credentials.deviceID,
            authorizationEpoch: credentials.authorizationEpoch,
            signingPrivateKey: BighelpLinkBase64URL.encode(
                credentials.signingPrivateKey.rawRepresentation
            ),
            accountKey: BighelpLinkBase64URL.encode(credentials.accountKey)
        )
        try saveData(try JSONEncoder().encode(stored), account: account)
    }

    func delete() throws {
        try deleteData(account: account)
    }

    func loadAccountDeletionTransaction() throws -> BighelpLinkAccountDeletionTransaction? {
        guard let data = try loadData(account: accountDeletionAccount) else { return nil }
        let transaction = try JSONDecoder().decode(BighelpLinkAccountDeletionTransaction.self, from: data)
        guard transaction.isValid else { throw VaultError.invalidData }
        return transaction
    }

    func saveAccountDeletionTransaction(_ transaction: BighelpLinkAccountDeletionTransaction) throws {
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
