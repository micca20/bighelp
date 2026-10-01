import Foundation
import Security

/// Which person is using bighelp, for hosts that several people share.
///
/// A random ID kept in iCloud Keychain, so your iPhone, iPad and Vision Pro
/// count as one person and someone else's phone counts as another. It isn't a
/// login: it only lets the bighelp plugin tell people's messages apart.
@MainActor
enum BighelpPersonID {
    private static let service = "BighelpPerson"
    private static let account = "person-id"
    private static var cached: String?

    /// This person's ID, made on first use. `nil` when the keychain can't be
    /// read yet (before the first unlock after a restart); the message then
    /// goes without a name rather than as a new person.
    static func current() -> String? {
        if let cached { return cached }
        if let saved = read() {
            cached = saved
            return saved
        }
        let made = UUID().uuidString.lowercased()
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(made.utf8),
        ] as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            cached = made
            return made
        case errSecDuplicateItem:
            // Another device's ID synced in first.
            cached = read()
            return cached
        default:
            return nil
        }
    }

    private static func read() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), isValid(value) else { return nil }
        return value
    }

    /// The plugin accepts a lowercase UUID only.
    nonisolated static func isValid(_ value: String) -> Bool {
        value.count == 36 && value == value.lowercased() && UUID(uuidString: value) != nil
    }
}
