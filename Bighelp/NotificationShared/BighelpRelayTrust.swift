import CryptoKit
import Foundation
import Security

enum BighelpRelayTrustError: Error, Equatable {
    case invalidSenderKey
    case invalidSenderKeySet
    case keychain(OSStatus)
}

struct BighelpRelaySenderKey: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case current
        case previous
    }

    let keyID: String
    let publicKey: String
    let state: State
    let notBefore: Int
    let notAfter: Int

    static func parse(_ value: Any, expectedState: State) throws -> Self {
        guard
            let value = value as? [String: Any],
            Set(value.keys) == Set(["key_id", "public_key", "state", "not_before", "not_after"]),
            let keyID = value["key_id"] as? String,
            let publicKey = value["public_key"] as? String,
            let rawState = value["state"] as? String,
            let state = State(rawValue: rawState),
            state == expectedState,
            let notBefore = value["not_before"] as? Int,
            let notAfter = value["not_after"] as? Int,
            notBefore > 0,
            notAfter > notBefore,
            notAfter - notBefore <= 2_678_400,
            let publicBytes = BighelpNotificationBase64URL.decodeCanonical(publicKey),
            publicBytes.count == 65,
            publicBytes.first == 0x04,
            (try? P256.Signing.PublicKey(x963Representation: publicBytes)) != nil,
            BighelpNotificationBase64URL.decodeCanonical(keyID)?.count == 32,
            BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: publicBytes))) == keyID
        else { throw BighelpRelayTrustError.invalidSenderKey }
        return Self(
            keyID: keyID,
            publicKey: publicKey,
            state: state,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    func isActive(at timestamp: Int) -> Bool {
        notBefore <= timestamp && timestamp <= notAfter
    }
}

struct BighelpRelaySenderKeySet: Codable, Equatable, Sendable {
    let revision: Int
    let current: BighelpRelaySenderKey
    let previous: BighelpRelaySenderKey?

    static func parse(
        revision: Any,
        current: Any,
        previous rawPrevious: Any,
        now: Int
    ) throws -> Self {
        guard let revision = revision as? Int, revision > 0 else {
            throw BighelpRelayTrustError.invalidSenderKeySet
        }
        let current = try BighelpRelaySenderKey.parse(current, expectedState: .current)
        let previous: BighelpRelaySenderKey?
        if rawPrevious is NSNull {
            previous = nil
        } else {
            previous = try BighelpRelaySenderKey.parse(rawPrevious, expectedState: .previous)
        }
        guard current.isActive(at: now) else {
            throw BighelpRelayTrustError.invalidSenderKeySet
        }
        if let previous {
            guard
                previous.keyID != current.keyID,
                previous.notAfter - current.notBefore <= 604_800
            else { throw BighelpRelayTrustError.invalidSenderKeySet }
        }
        return Self(revision: revision, current: current, previous: previous)
    }

    func acknowledgedKeyIDs(at timestamp: Int) -> [String] {
        [current, previous]
            .compactMap { $0 }
            .filter { $0.isActive(at: timestamp) }
            .map(\.keyID)
    }

    func key(id: String, issuedAt: Int) -> BighelpRelaySenderKey? {
        [current, previous]
            .compactMap { $0 }
            .first { $0.keyID == id && $0.isActive(at: issuedAt) }
    }
}

protocol BighelpRelaySenderKeyPinStoring: AnyObject {
    func load() throws -> BighelpRelaySenderKeySet?
    func save(_ value: BighelpRelaySenderKeySet) throws
}

final class BighelpRelaySenderKeychainPinStore: BighelpRelaySenderKeyPinStoring {
    private let accessGroup: String?
    private let service = "app.loopdy.mobile.notification-trust"
    private let account = "relay-sender-key-set-v1"

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group) {
        self.accessGroup = accessGroup
    }

    func load() throws -> BighelpRelaySenderKeySet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BighelpRelayTrustError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(BighelpRelaySenderKeySet.self, from: data)
        } catch {
            throw BighelpRelayTrustError.invalidSenderKeySet
        }
    }

    func save(_ value: BighelpRelaySenderKeySet) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(
            baseQuery.merging(attributes) { _, replacement in replacement } as CFDictionary,
            nil
        )
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else {
            throw BighelpRelayTrustError.keychain(status)
        }
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updated == errSecSuccess else {
            throw BighelpRelayTrustError.keychain(updated)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

protocol BighelpNotificationRecipientKeyLoading: AnyObject {
    func load() throws -> Data?
}

final class BighelpNotificationRecipientKeyStore: BighelpNotificationRecipientKeyLoading {
    private let accessGroup: String?
    private let service = "app.loopdy.mobile.link-push"
    private let account = "p256-agreement-v1"

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group) {
        self.accessGroup = accessGroup
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BighelpRelayTrustError.keychain(status)
        }
        return data
    }

    func save(_ value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(
            baseQuery.merging(attributes) { _, replacement in replacement } as CFDictionary,
            nil
        )
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else {
            throw BighelpRelayTrustError.keychain(status)
        }
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updated == errSecSuccess else {
            throw BighelpRelayTrustError.keychain(updated)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

enum BighelpNotificationKeychainAccess {
    static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationKeychainGroup") as? String
    }
}

enum BighelpNotificationBase64URL {
    static func encode(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCanonical(_ value: String) -> Data? {
        guard
            !value.isEmpty,
            value.count % 4 != 1,
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { return nil }
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard
            let decoded = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)),
            encode(decoded) == value
        else { return nil }
        return decoded
    }
}
