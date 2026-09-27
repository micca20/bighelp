import Foundation
import Security

/// Credentials for whatever guards a Hermes address before Hermes itself:
/// a Cloudflare Access service token (for a Cloudflare Tunnel), or a proxy's
/// username and password (HTTP basic auth on nginx, Caddy, Traefik and the
/// like). bighelp sends them on every request and socket to that exact address,
/// and nowhere else.
struct DirectHermesAccessCredentials: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cloudflareAccess
        case basic
    }

    let kind: Kind
    /// The Cloudflare client ID, or the proxy username.
    let clientID: String
    /// The Cloudflare client secret, or the proxy password.
    let clientSecret: String

    /// A Cloudflare Access service token.
    init(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(id), Self.valid(secret) else { throw DirectHermesError.invalidAccessCredentials }
        kind = .cloudflareAccess
        self.clientID = id
        self.clientSecret = secret
    }

    /// A proxy's username and password. Passwords keep their spaces.
    init(username: String, password: String) throws {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, user.utf8.count <= 256, !user.contains(":"),
              !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.isEmpty, password.utf8.count <= 512,
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidAccessCredentials
        }
        kind = .basic
        clientID = user
        clientSecret = password
    }

    var headers: [String: String] {
        switch kind {
        case .cloudflareAccess:
            ["CF-Access-Client-Id": clientID, "CF-Access-Client-Secret": clientSecret]
        case .basic:
            ["Authorization": "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()]
        }
    }

    /// Basic auth may also go to a plain-HTTP address on a private network the
    /// person allowed, like their Hermes session. Cloudflare Access is HTTPS only.
    func canSend(to endpoint: DirectHermesEndpoint) -> Bool {
        endpoint.baseURL.scheme == "https"
            || (kind == .basic && endpoint.allowPrivateHTTP
                && DirectHermesEndpoint.isPrivateNetworkHost(endpoint.host))
    }

    /// Header-safe: printable ASCII, no spaces, bounded.
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }

    private enum CodingKeys: String, CodingKey { case kind, clientID, clientSecret }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .clientID)
        let secret = try values.decode(String.self, forKey: .clientSecret)
        // Items saved before basic auth have no kind: they are Cloudflare Access tokens.
        switch try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .cloudflareAccess {
        case .cloudflareAccess: try self.init(clientID: id, clientSecret: secret)
        case .basic: try self.init(username: id, password: secret)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(clientID, forKey: .clientID)
        try values.encode(clientSecret, forKey: .clientSecret)
    }
}

/// Device-local Keychain storage, one item per host address. While a host is
/// being set up its credentials are staged in memory (used for requests) and
/// only saved once a connection succeeds. The Keychain service name predates
/// basic auth and stays, so saved tokens keep working.
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

    /// Only for the exact address, and never over the open internet in plain HTTP.
    func credentials(for endpoint: DirectHermesEndpoint) -> DirectHermesAccessCredentials? {
        guard endpoint.baseURL.scheme == "https" || endpoint.allowPrivateHTTP else { return nil }
        let key = endpoint.identity
        let known: DirectHermesAccessCredentials?? = lock.withLock {
            if let value = staged[key] { return .some(value) }
            return cache[key]
        }
        let value: DirectHermesAccessCredentials?
        if let known {
            value = known
        } else {
            value = load(key)
            lock.withLock { cache[key] = .some(value) }
        }
        guard let value, value.canSend(to: endpoint) else { return nil }
        return value
    }

    func headers(for endpoint: DirectHermesEndpoint) -> [String: String] {
        credentials(for: endpoint)?.headers ?? [:]
    }

    func hasSavedCredentials(for endpoint: DirectHermesEndpoint) -> Bool {
        savedCredentials(for: endpoint) != nil
    }

    func savedCredentials(for endpoint: DirectHermesEndpoint) -> DirectHermesAccessCredentials? {
        guard let value = load(endpoint.identity), value.canSend(to: endpoint) else { return nil }
        return value
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
