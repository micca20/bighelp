import CryptoKit
import Foundation
import Security

struct GitHubCredentialScope: Codable, Equatable, Sendable {
    let ownerID: String
    let clientID: String
    let host: String

    init(ownerID: String, clientID: String) {
        self.ownerID = ownerID
        self.clientID = clientID
        host = "github.com"
    }
}

/// Never pass this type to content, telemetry, Link, exports or a preferences store.
struct GitHubTokenPair: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date

    static func decode(_ object: [String: GitHubJSON], now: Date) throws -> GitHubTokenPair {
        let access = try object.required("access_token").string(max: 1024)
        let refresh = try object.required("refresh_token").string(max: 1024)
        guard valid(access, prefix: "ghu_"), valid(refresh, prefix: "ghr_"),
              try object.required("token_type").string() == "bearer",
              try object.required("scope").string(allowEmpty: true).isEmpty
        else { throw GitHubError.invalidResponse }
        let accessSeconds = try object.required("expires_in").integer(min: 1, max: 86_400)
        let refreshSeconds = try object.required("refresh_token_expires_in").integer(min: 1, max: 31_622_400)
        guard refreshSeconds > accessSeconds else { throw GitHubError.invalidResponse }
        return GitHubTokenPair(
            accessToken: access, refreshToken: refresh,
            accessExpiresAt: now.addingTimeInterval(TimeInterval(accessSeconds)),
            refreshExpiresAt: now.addingTimeInterval(TimeInterval(refreshSeconds))
        )
    }

    func validate() throws {
        guard Self.valid(accessToken, prefix: "ghu_"), Self.valid(refreshToken, prefix: "ghr_"),
              accessExpiresAt.timeIntervalSince1970.isFinite, refreshExpiresAt.timeIntervalSince1970.isFinite,
              refreshExpiresAt > accessExpiresAt else { throw GitHubError.vaultUnavailable }
    }

    private static func valid(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count > prefix.utf8.count && value.utf8.count <= 1024
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value) || scalar.value == 95
            }
    }

    var description: String { "GitHubTokenPair(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

struct GitHubCredentialRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let scope: GitHubCredentialScope
    let identity: GitHubIdentity
    let id: String
    let origin: GitHubCredentialOrigin
    let tokens: GitHubTokenPair?
    let personalAccessToken: GitHubPersonalAccessToken?
    /// Persisted BEFORE device-token rotation; ambiguity requires reconnect.
    let refreshPending: Bool

    init(scope: GitHubCredentialScope, identity: GitHubIdentity, tokens: GitHubTokenPair, refreshPending: Bool) {
        self.scope = scope
        self.identity = identity
        id = String(identity.id) // Preserve the legacy device-flow Keychain account.
        origin = .deviceFlow
        self.tokens = tokens
        personalAccessToken = nil
        self.refreshPending = refreshPending
    }

    init(scope: GitHubCredentialScope, identity: GitHubIdentity, personalAccessToken: GitHubPersonalAccessToken) {
        self.scope = scope
        self.identity = identity
        id = UUID().uuidString
        origin = .personalAccessToken
        tokens = nil
        self.personalAccessToken = personalAccessToken
        refreshPending = false
    }

    private enum CodingKeys: String, CodingKey {
        case scope, identity, id, origin, tokens, personalAccessToken, refreshPending
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(GitHubCredentialScope.self, forKey: .scope)
        identity = try values.decode(GitHubIdentity.self, forKey: .identity)
        // Only legacy records omit origin/id. Their namespace and account remain unchanged.
        origin = try values.decodeIfPresent(GitHubCredentialOrigin.self, forKey: .origin) ?? .deviceFlow
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? String(identity.id)
        tokens = try values.decodeIfPresent(GitHubTokenPair.self, forKey: .tokens)
        personalAccessToken = try values.decodeIfPresent(GitHubPersonalAccessToken.self, forKey: .personalAccessToken)
        refreshPending = try values.decode(Bool.self, forKey: .refreshPending)
        try validate()
    }

    var summary: GitHubSavedCredential { GitHubSavedCredential(id: id, identity: identity, origin: origin) }

    func validate() throws {
        guard scope.host == "github.com", identity.id > 0 else { throw GitHubError.vaultUnavailable }
        switch origin {
        case .deviceFlow:
            guard id == String(identity.id), !scope.clientID.isEmpty,
                  personalAccessToken == nil, let tokens else { throw GitHubError.vaultUnavailable }
            try tokens.validate()
        case .personalAccessToken:
            guard UUID(uuidString: id) != nil, scope.clientID.isEmpty, tokens == nil,
                  !refreshPending, let personalAccessToken,
                  GitHubPersonalAccessToken.isValid(personalAccessToken.value)
            else { throw GitHubError.vaultUnavailable }
        }
    }

    var description: String { "GitHubCredentialRecord(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}

/// Synchronous actor-isolated persistence avoids a write completing after disconnect.
/// Inject a memory vault in parent-owned tests; never use the production vault there.
@MainActor
protocol GitHubCredentialVault {
    func records(in scope: GitHubCredentialScope) throws -> [GitHubCredentialRecord]
    func save(_ record: GitHubCredentialRecord) throws
    func remove(userID: Int, in scope: GitHubCredentialScope) throws
    func remove(recordID: String, in scope: GitHubCredentialScope) throws
    func removeAll(in scope: GitHubCredentialScope) throws
}

extension GitHubCredentialVault {
    // Compatibility for existing device-only injected vaults. Never broaden a PAT deletion.
    func remove(recordID: String, in scope: GitHubCredentialScope) throws {
        guard let userID = Int(recordID), recordID == String(userID), !scope.clientID.isEmpty else {
            throw GitHubError.vaultUnavailable
        }
        try remove(userID: userID, in: scope)
    }
}

@MainActor
final class GitHubKeychainVault: GitHubCredentialVault {
    private let servicePrefix = "app.loopdy.github.user-tokens.v1."

    func records(in scope: GitHubCredentialScope) throws -> [GitHubCredentialRecord] {
        var query = base(scope)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data], items.count <= 50 else {
            throw GitHubError.vaultUnavailable
        }
        return try items.map { data in
            guard data.count <= 16_384,
                  let record = try? JSONDecoder().decode(GitHubCredentialRecord.self, from: data),
                  record.scope == scope, record.identity.id > 0,
                  record.identity.login.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}$"#, options: .regularExpression) != nil
            else { throw GitHubError.vaultUnavailable }
            try record.validate()
            return record
        }
    }

    func save(_ record: GitHubCredentialRecord) throws {
        try record.validate()
        guard record.identity.id > 0 else { throw GitHubError.vaultUnavailable }
        let data = try JSONEncoder().encode(record)
        var query = base(record.scope)
        query[kSecAttrAccount as String] = record.id
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw GitHubError.vaultUnavailable
            }
        } else if updated != errSecSuccess { throw GitHubError.vaultUnavailable }
    }

    func remove(userID: Int, in scope: GitHubCredentialScope) throws {
        var query = base(scope)
        query[kSecAttrAccount as String] = String(userID)
        try delete(query)
    }

    func remove(recordID: String, in scope: GitHubCredentialScope) throws {
        var query = base(scope)
        query[kSecAttrAccount as String] = recordID
        try delete(query)
    }

    func removeAll(in scope: GitHubCredentialScope) throws { try delete(base(scope)) }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubError.vaultUnavailable }
    }

    private func base(_ scope: GitHubCredentialScope) -> [String: Any] {
        // Length-prefix owner/registration instead of ambiguous delimiter concatenation.
        let key = "\(scope.ownerID.utf8.count):\(scope.ownerID)\(scope.clientID.utf8.count):\(scope.clientID):\(scope.host)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + digest,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
