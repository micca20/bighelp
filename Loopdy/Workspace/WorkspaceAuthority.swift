import CryptoKit
import Foundation

/// Non-secret authority coordinates. Construct these only after the owning
/// transport verifies authentication; a display label is never an authority.
struct WorkspaceAuthority: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case direct
        case link
        case fixture
    }

    let kind: Kind
    let endpointIdentity: String
    let principalID: String
    let providerID: String?
    let hostID: String
    let deviceAuthorizationEpoch: Int?
    let hostAuthorizationEpoch: Int?

    private var canonicalIdentity: Data {
        let fields = [
            kind.rawValue, endpointIdentity, principalID, providerID ?? "", hostID,
            deviceAuthorizationEpoch.map(String.init) ?? "",
            hostAuthorizationEpoch.map(String.init) ?? "",
        ]
        let canonical = "workspace-authority-v1:" + fields.map { "\($0.utf8.count):\($0)" }.joined()
        return Data(canonical.utf8)
    }

    var cacheScopeID: String {
        SHA256.hash(data: canonicalIdentity).map { String(format: "%02x", $0) }.joined()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonicalIdentity == rhs.canonicalIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalIdentity)
    }

    static func direct(endpointIdentity: String, providerID: String, userID: String) throws -> Self {
        let endpoint = try canonicalEndpoint(endpointIdentity)
        return try Self(kind: .direct, endpointIdentity: endpoint, principalID: userID,
                        providerID: providerID, hostID: endpoint,
                        deviceAuthorizationEpoch: nil, hostAuthorizationEpoch: nil)
    }

    /// The dashboard grants shared host access without a person identity.
    /// A nil provider keeps this scope distinct from every provider login.
    static func dashboard(endpointIdentity: String) throws -> Self {
        let endpoint = try canonicalEndpoint(endpointIdentity)
        return try Self(kind: .direct, endpointIdentity: endpoint, principalID: "dashboard-session",
                        providerID: nil, hostID: endpoint,
                        deviceAuthorizationEpoch: nil, hostAuthorizationEpoch: nil)
    }

    static func link(origin: String, deviceID: String, deviceAuthorizationEpoch: Int,
                     hostID: String, hostAuthorizationEpoch: Int?) throws -> Self {
        let endpoint = try canonicalEndpoint(origin)
        guard let parts = URLComponents(string: endpoint), parts.scheme == "https",
              parts.path.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return try Self(kind: .link, endpointIdentity: endpoint, principalID: deviceID,
                        providerID: nil, hostID: hostID,
                        deviceAuthorizationEpoch: deviceAuthorizationEpoch,
                        hostAuthorizationEpoch: hostAuthorizationEpoch)
    }

    static func fixture(id: String) throws -> Self {
        try Self(kind: .fixture, endpointIdentity: "fixture", principalID: id,
                 providerID: nil, hostID: id,
                 deviceAuthorizationEpoch: nil, hostAuthorizationEpoch: nil)
    }

    private init(kind: Kind, endpointIdentity: String, principalID: String, providerID: String?,
                 hostID: String, deviceAuthorizationEpoch: Int?, hostAuthorizationEpoch: Int?) throws {
        try Self.validateIdentifier(principalID, maximumBytes: 512)
        try Self.validateIdentifier(hostID, maximumBytes: 2_048)
        if let providerID { try Self.validateIdentifier(providerID, maximumBytes: 128) }
        guard deviceAuthorizationEpoch.map({ $0 > 0 }) ?? true,
              hostAuthorizationEpoch.map({ $0 > 0 }) ?? true else {
            throw WorkspaceClientError.invalidResponse
        }
        self.kind = kind
        self.endpointIdentity = endpointIdentity
        self.principalID = principalID
        self.providerID = providerID
        self.hostID = hostID
        self.deviceAuthorizationEpoch = deviceAuthorizationEpoch
        self.hostAuthorizationEpoch = hostAuthorizationEpoch
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let endpoint = try values.decode(String.self, forKey: .endpointIdentity)
        let principal = try values.decode(String.self, forKey: .principalID)
        let provider = try values.decodeIfPresent(String.self, forKey: .providerID)
        let host = try values.decode(String.self, forKey: .hostID)
        let deviceEpoch = try values.decodeIfPresent(Int.self, forKey: .deviceAuthorizationEpoch)
        let hostEpoch = try values.decodeIfPresent(Int.self, forKey: .hostAuthorizationEpoch)
        switch kind {
        case .direct:
            guard deviceEpoch == nil, hostEpoch == nil else { throw WorkspaceClientError.invalidResponse }
            if let provider {
                self = try .direct(endpointIdentity: endpoint, providerID: provider, userID: principal)
            } else {
                guard principal == "dashboard-session" else { throw WorkspaceClientError.invalidResponse }
                self = try .dashboard(endpointIdentity: endpoint)
            }
            guard host == hostID else { throw WorkspaceClientError.invalidResponse }
        case .link:
            guard provider == nil, let deviceEpoch else { throw WorkspaceClientError.invalidResponse }
            self = try .link(origin: endpoint, deviceID: principal, deviceAuthorizationEpoch: deviceEpoch,
                             hostID: host, hostAuthorizationEpoch: hostEpoch)
        case .fixture:
            guard endpoint == "fixture", host == principal, provider == nil,
                  deviceEpoch == nil, hostEpoch == nil else { throw WorkspaceClientError.invalidResponse }
            self = try .fixture(id: principal)
        }
    }

    static func validateIdentifier(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidResponse
        }
    }

    private static func canonicalEndpoint(_ value: String) throws -> String {
        try validateIdentifier(value, maximumBytes: 2_048)
        guard !value.contains("\\"),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw WorkspaceClientError.invalidResponse
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        if parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let endpoint = parts.url?.absoluteString else { throw WorkspaceClientError.invalidResponse }
        return endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case kind, endpointIdentity, principalID, providerID, hostID
        case deviceAuthorizationEpoch, hostAuthorizationEpoch
    }
}
