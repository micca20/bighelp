import Foundation
import Network
import Testing
@testable import Bighelp

/// The chat socket stays signed in from when it connected, but every web
/// request (the plugin's routes, sessions, voice) carries the app's sign-in
/// again. When Hermes turns one away (a token renewed elsewhere, revoked, or
/// a new dashboard token after a restart), the app renews the sign-in and
/// sends the request once more instead of failing until it reconnects. That
/// failure showed up as "could not reach its native API" under Device access.
@MainActor
struct DirectHermesSignInRenewalTests {
    private nonisolated static let oldToken = String(repeating: "o", count: 43)
    private nonisolated static let newToken = String(repeating: "n", count: 43)

    private func authenticator(port: UInt16, _ authentication: DirectHermesStoredAuthentication,
                               rotations: @escaping (DirectHermesSavedConnection) -> Void = { _ in })
        throws -> DirectHermesAuthenticator {
        let endpoint = try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true)
        let authenticator = DirectHermesAuthenticator(endpoint: endpoint)
        var saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: authentication)
        if case .bearer = authentication { (saved.provider, saved.userID) = ("basic", "fixture") }
        authenticator.adoptForTesting(saved)
        authenticator.persistRotation = { _, replacement in rotations(replacement) }
        return authenticator
    }

    private let context = DirectHermesHTTPRequest(path: "/api/plugins/loopdy/native/context", method: .get,
                                                  maximumResponseBytes: 16_384)

    @Test func aDashboardTokenTurnedAwayIsReadAgainAndTheRequestSentOnce() async throws {
        let host = try ScriptedHermes { request in
            if request.path == "/" {
                return .html("<script>window.__HERMES_SESSION_TOKEN__=\"\(Self.newToken)\";"
                             + "window.__HERMES_AUTH_REQUIRED__=false;</script>")
            }
            return request.header("x-hermes-session-token") == Self.newToken ? .json("{}") : .status(401)
        }
        var rotated: [DirectHermesSavedConnection] = []
        let authenticator = try authenticator(port: try await host.start(),
                                              .dashboardSession(token: Self.oldToken, automatic: true)) {
            rotated.append($0)
        }

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.paths == ["/api/plugins/loopdy/native/context", "/", "/api/plugins/loopdy/native/context"])
        #expect(rotated.map(\.authentication) == [.dashboardSession(token: Self.newToken, automatic: true)])
    }

    @Test func aBearerTurnedAwayIsRefreshedAndTheRequestSentOnce() async throws {
        let host = try ScriptedHermes { request in
            if request.path == "/auth/native/refresh" {
                let expires = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
                return .json("{\"token_type\":\"Bearer\",\"access_token\":\"\(Self.newToken)\","
                             + "\"refresh_token\":\"refresh-2\",\"provider\":\"basic\",\"user_id\":\"fixture\","
                             + "\"expires_at\":\(expires)}")
            }
            return request.header("authorization") == "Bearer \(Self.newToken)" ? .json("{}") : .status(401)
        }
        let authenticator = try authenticator(port: try await host.start(), .bearer(
            accessToken: Self.oldToken, refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3_600)))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.paths == ["/api/plugins/loopdy/native/context", "/auth/native/refresh",
                               "/api/plugins/loopdy/native/context"])
    }

    @Test func withNothingToRenewTheRejectionIsReturnedOnce() async throws {
        let host = try ScriptedHermes { _ in .status(401) }
        let authenticator = try authenticator(port: try await host.start(), .bearer(
            accessToken: Self.oldToken, refreshToken: nil, expiresAt: Date().addingTimeInterval(3_600)))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 401)
        #expect(host.paths == ["/api/plugins/loopdy/native/context"])
    }

    @Test func otherFailuresAreNotRetried() async throws {
        let host = try ScriptedHermes { _ in .status(404) }
        let authenticator = try authenticator(port: try await host.start(),
                                              .dashboardSession(token: Self.oldToken, automatic: true))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 404)
        #expect(host.paths == ["/api/plugins/loopdy/native/context"])
    }

    @Test func deviceAccessOnlyAsksForARestartWhenThePluginRouteIsMissing() {
        let restart = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.unavailable(.pluginRequired))
        let signIn = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.authenticationRequired)
        let quiet = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.transportUnavailable)

        #expect(restart.contains("restart the hermes serve process"))
        #expect(signIn.contains("Sign in to the host again"))
        #expect(!signIn.contains("restart"))
        #expect(quiet.contains("Check again in a moment"))
        #expect(!quiet.contains("restart"))
    }
}

/// A loopback stand-in for Hermes that answers each request from a script.
private final class ScriptedHermes: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        func header(_ name: String) -> String? { headers[name] }
    }

    enum Reply {
        case status(Int)
        case json(String)
        case html(String)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "bighelp.test.scripted-hermes")
    private let lock = NSLock()
    private let script: @Sendable (Request) -> Reply
    private var seen: [String] = []
    private var started = false
    var paths: [String] { lock.withLock { seen } }

    init(_ script: @escaping @Sendable (Request) -> Reply) throws {
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit { listener.cancel() }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, prefix: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            guard error == nil, let data else { connection.cancel(); return }
            let buffer = prefix + data
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { receive(connection, prefix: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = head.first?.split(separator: " ") ?? []
            guard line.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for field in head.dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                headers[field[..<colon].lowercased()] = field[field.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let path = String(line[1].split(separator: "?").first ?? "")
            lock.withLock { seen.append(path) }
            let reply = script(Request(method: String(line[0]), path: path, headers: headers))
            let (status, type, body): (Int, String, String) = switch reply {
            case .status(let code): (code, "application/json", "{\"detail\":\"fixture\"}")
            case .json(let text): (200, "application/json", text)
            case .html(let text): (200, "text/html; charset=utf-8", text)
            }
            let bytes = Data(body.utf8)
            let response = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + bytes, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
