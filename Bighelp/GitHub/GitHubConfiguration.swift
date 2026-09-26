import Foundation

struct GitHubConfiguration: Equatable, Sendable {
    /// Public Info.plist integration keys. No registration values are shipped here.
    static let clientIDInfoKey = "BighelpGitHubClientID"
    static let installationURLInfoKey = "BighelpGitHubInstallationURL"
    let clientID: String
    let installationURL: URL
    let appSlug: String

    init(clientID: String, installationURL: URL) throws {
        guard clientID.range(of: #"^Iv[0-9][A-Za-z0-9.]{8,125}$"#, options: .regularExpression) != nil,
              !clientID.lowercased().contains("placeholder"),
              let parts = URLComponents(url: installationURL, resolvingAgainstBaseURL: false),
              GitHubURLPolicy.isOrigin(parts, host: "github.com"),
              parts.percentEncodedPath == parts.path,
              parts.path.range(of: #"^/apps/[a-z0-9][a-z0-9-]{0,99}/installations/new$"#, options: .regularExpression) != nil
        else { throw GitHubError.invalidConfiguration }
        self.clientID = clientID
        self.installationURL = installationURL
        appSlug = String(parts.path.split(separator: "/")[1])
    }

    static func from(bundle: Bundle = .main) throws -> GitHubConfiguration? {
        let client = bundle.object(forInfoDictionaryKey: clientIDInfoKey)
        let installation = bundle.object(forInfoDictionaryKey: installationURLInfoKey)
        if client == nil, installation == nil { return nil }
        guard let clientID = client as? String, let rawURL = installation as? String,
              let url = URL(string: rawURL) else { throw GitHubError.invalidConfiguration }
        return try GitHubConfiguration(clientID: clientID, installationURL: url)
    }
}

enum GitHubURLPolicy {
    static func isOrigin(_ parts: URLComponents, host: String, allowQuery: Bool = false) -> Bool {
        parts.scheme == "https" && parts.host == host && parts.port == nil
            && parts.user == nil && parts.password == nil && parts.fragment == nil
            && (allowQuery || parts.query == nil)
    }

    static func verification(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return isOrigin(parts, host: "github.com") && parts.percentEncodedPath == "/login/device"
    }

    static func repositoryName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
            && GitHubContent.safe(name) == name
            && ![".", ".."].contains(String(name.split(separator: "/").last ?? ""))
    }

    static func canonicalURL(repository: String, kind: GitHubResourceKind, number: Int?) throws -> URL {
        guard repositoryName(repository) else { throw GitHubError.invalidResponse }
        var path = "/\(repository)"
        if kind != .repository {
            guard let number, number > 0 else { throw GitHubError.invalidResponse }
            path += "/\(kind == .issue ? "issues" : "pull")/\(number)"
        }
        guard let url = URL(string: "https://github.com" + path) else { throw GitHubError.invalidResponse }
        return url
    }
}
