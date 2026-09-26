import Foundation

/// Uses the existing no-redirect/TLS delegate. Account proof never follows a
/// redirect, shares cookies, uses a credential store, or reaches a host origin.
@MainActor
final class BighelpManagedAccountTransport: BighelpLinkHTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: DirectHermesSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == "link.loopdy.app",
              url.port == nil || url.port == 443 else { throw BighelpLinkAPIError.invalidConfiguration }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url,
              !(300...399).contains(response.statusCode), response.expectedContentLength <= 262_144 else {
            bytes.task.cancel(); throw BighelpLinkAPIError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262_144 else { bytes.task.cancel(); throw BighelpLinkAPIError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}

@MainActor
protocol DirectHostNotificationServing: AnyObject {
    func request(_ suffix: String, method: String, body: [String: BighelpJSONValue]?,
                 isCurrent: @escaping @MainActor () -> Bool) async throws -> BighelpJSONValue
}

enum DirectHostNotificationError: Error { case backendRestartRequired }

/// Native authentication only. A fresh authenticator is restored from the exact
/// host vault for each request, so a chat client's newer rotation is not replaced
/// by a retained notification snapshot. Unknown writes are never auto-replayed.
@MainActor
final class DirectHostNotificationClient: DirectHostNotificationServing {
    private let host: BighelpConfiguredHost
    private let vault: any DirectHermesCredentialVault
    private let connectionIsCurrent: @MainActor () -> Bool

    init(host: BighelpConfiguredHost, vault: any DirectHermesCredentialVault,
         connectionIsCurrent: @escaping @MainActor () -> Bool) {
        self.host = host; self.vault = vault; self.connectionIsCurrent = connectionIsCurrent
    }

    func request(_ suffix: String, method: String = "GET", body: [String: BighelpJSONValue]? = nil,
                 isCurrent: @escaping @MainActor () -> Bool) async throws -> BighelpJSONValue {
        guard suffix.utf8.count <= 512, suffix.hasPrefix("/"), !suffix.contains(".."),
              !suffix.contains("%"), !suffix.contains("?"), !suffix.contains("#"), !suffix.contains("\\"),
              suffix.utf8.allSatisfy({ (33...126).contains($0) }),
              ["GET", "POST", "PUT", "DELETE"].contains(method) else { throw DirectHermesError.invalidResponse }
        @MainActor func check() throws {
            try Task.checkCancellation()
            guard connectionIsCurrent(), isCurrent() else { throw DirectHermesError.secureStorageChanged }
        }
        try check()
        guard let saved = try vault.load(), DirectHermesIdentity.matches(saved.identity, host.principalIdentity),
              saved.endpoint == host.endpoint else { throw DirectHermesError.secureStorageChanged }
        let auth = DirectHermesAuthenticator(endpoint: host.endpoint)
        defer { auth.http.invalidate() }
        auth.persistRotation = { [vault] old, replacement in
            try check()
            guard DirectHermesIdentity.matches(old.identity, saved.identity),
                  DirectHermesIdentity.matches(replacement.identity, saved.identity),
                  try vault.load() == old else { throw DirectHermesError.secureStorageChanged }
            try vault.save(replacement)
        }
        try await auth.restore(saved)
        try check()
        guard let current = auth.savedConnection, DirectHermesIdentity.matches(current.identity, saved.identity),
              try vault.load() == current else { throw DirectHermesError.secureStorageChanged }
        if let body { try DirectHermesWire.validateValueSize(.object(body), limit: 262_144) }
        let bearer: String?; let legacy: String?
        switch current.authentication {
        case .bearer(let token, _, _): bearer = token; legacy = nil
        case .legacyLoopbackToken(let token), .dashboardSession(let token, _): bearer = nil; legacy = token
        }
        let response = try await auth.http.send(route: "/api/plugins/loopdy/notifications" + suffix,
            method: method, body: body, bearer: bearer, legacyToken: legacy)
        try check()
        guard try vault.load() == current else { throw DirectHermesError.secureStorageChanged }
        if response.http.statusCode == 404, suffix == "/capabilities" {
            throw DirectHostNotificationError.backendRestartRequired
        }
        try DirectHermesHTTP.requireSuccess(response)
        guard response.body.count <= 262_144 else { throw DirectHermesError.messageTooLarge }
        let object = try response.object()
        guard object["version"]?.integer == 1 else { throw DirectHermesError.invalidResponse }
        return .object(object)
    }
}
