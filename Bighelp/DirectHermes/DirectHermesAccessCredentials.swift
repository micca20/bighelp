import Foundation
import Security

/// A Cloudflare Access service token, for a Hermes host published through a
/// Cloudflare Tunnel. bighelp sends it as `CF-Access-Client-Id` and
/// `CF-Access-Client-Secret` on every request and socket to that exact HTTPS
/// address, and nowhere else.
struct DirectHermesAccessCredentials: Codable, Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    init(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(id), Self.valid(secret) else { throw DirectHermesError.invalidAccessCredentials }
        self.clientID = id
        self.clientSecret = secret
    }

    var headers: [String: String] {
        ["CF-Access-Client-Id": clientID, "CF-Access-Client-Secret": clientSecret]
    }

    /// Header-safe: printable ASCII, no spaces, bounded.
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }

    private enum CodingKeys: String, CodingKey { case clientID, clientSecret }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(clientID: values.decode(String.self, forKey: .clientID),
                      clientSecret: values.decode(String.self, forKey: .clientSecret))
    }
}

/// Device-local Keychain storage, one item per host address. While a host is
/// being set up its token is staged in memory (used for requests) and only
/// saved once a connection succeeds.
final class DirectHermesAccessCredentialStore: @unchecked Sendable {
    static let shared = DirectHermesAccessCredentialStore()

    private let service: String
    private let lock = NSLock()
    /// Keychain reads by address; `.some(nil)` records "none saved".
    private var cache: [String: DirectHermesAccessCredentials?] = [:]
    private var staged: [String: DirectHermesAccessCredentials] = [:]

    init(service: String = "app.loopdy.mobile.cloudflare-access") {
        self.service = service
    }

    #if DEBUG
    var serviceForTesting: String { service }
    #endif

    /// Never sent over plain HTTP.
    func credentials(for endpoint: DirectHermesEndpoint) -> DirectHermesAccessCredentials? {
        guard endpoint.baseURL.scheme == "https" else { return nil }
        let key = endpoint.identity
        let known: DirectHermesAccessCredentials?? = lock.withLock {
            if let value = staged[key] { return .some(value) }
            return cache[key]
        }
        if let known { return known }
        let loaded = load(key)
        lock.withLock { cache[key] = .some(loaded) }
        return loaded
    }

    func headers(for endpoint: DirectHermesEndpoint) -> [String: String] {
        credentials(for: endpoint)?.headers ?? [:]
    }

    func hasSavedCredentials(for endpoint: DirectHermesEndpoint) -> Bool {
        endpoint.baseURL.scheme == "https" && load(endpoint.identity) != nil
    }

    /// Use these for a host being set up; nil stops using staged values.
    func stage(_ credentials: DirectHermesAccessCredentials?, for endpoint: DirectHermesEndpoint) {
        lock.withLock { staged[endpoint.identity] = credentials }
    }

    /// Saves a staged token once its connection worked.
    func commitStaged(for endpoint: DirectHermesEndpoint) throws {
        let key = endpoint.identity
        guard let value = lock.withLock({ staged[key] }) else { return }
        try save(value, key)
        lock.withLock {
            staged[key] = nil
            cache[key] = .some(value)
        }
    }

    func remove(for endpoint: DirectHermesEndpoint) {
        let key = endpoint.identity
        SecItemDelete(query(key) as CFDictionary)
        lock.withLock {
            staged[key] = nil
            cache[key] = .some(nil)
        }
    }

    // MARK: Keychain

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func load(_ account: String) -> DirectHermesAccessCredentials? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(DirectHermesAccessCredentials.self, from: data)
    }

    private func save(_ credentials: DirectHermesAccessCredentials, _ account: String) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw DirectHermesError.secureStorageUnavailable }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DirectHermesError.secureStorageUnavailable }
    }
}
