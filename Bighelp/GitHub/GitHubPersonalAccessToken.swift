import Foundation

/// No prefix-based identity, permission or expiry inference. Never export this value.
struct GitHubPersonalAccessToken: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    init(_ value: String) throws {
        guard Self.isValid(value) else { throw GitHubError.invalidPersonalAccessToken }
        self.value = value
    }

    static func isValid(_ value: String) -> Bool {
        // RFC 6750 bearer-token alphabet. Reject rather than trim whitespace or controls.
        !value.isEmpty && value.utf8.count <= 1024
            && value.range(of: #"^[A-Za-z0-9._~+/-]+=*$"#, options: .regularExpression) != nil
            && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    var description: String { "GitHubPersonalAccessToken(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "<redacted>"]) }
}

enum GitHubCredentialOrigin: String, Codable, Sendable {
    case deviceFlow, personalAccessToken

    var title: String {
        switch self {
        case .deviceFlow: "Device-code login"
        case .personalAccessToken: "Personal access token"
        }
    }
}

/// Device-local selection metadata only; never serialize into reference snapshots.
struct GitHubSavedCredential: Equatable, Identifiable, Sendable {
    let id: String
    let identity: GitHubIdentity
    let origin: GitHubCredentialOrigin

    /// Distinguishes multiple PATs for the same account without exposing token bytes.
    var label: String {
        origin == .personalAccessToken ? "Personal access token · " + String(id.prefix(8)) : origin.title
    }
}
