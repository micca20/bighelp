import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesAccessCredentialsTests {
    private let id = "0123456789abcdef.access"
    private let secret = String(repeating: "f", count: 64)

    @Test func serviceTokensAreHeaderSafe() throws {
        let token = try DirectHermesAccessCredentials(clientID: " \(id)\n", clientSecret: secret)
        #expect(token.headers == ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret])
        for bad in ["", "has space", "line\nbreak", String(repeating: "a", count: 513), "émoji"] {
            #expect(throws: DirectHermesError.invalidAccessCredentials) {
                try DirectHermesAccessCredentials(clientID: bad, clientSecret: secret)
            }
        }
    }

    @Test func aStagedTokenIsUsedButOnlySavedAfterConnecting() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        defer { store.remove(for: endpoint) }
        let token = try DirectHermesAccessCredentials(clientID: id, clientSecret: secret)
        store.stage(token, for: endpoint)
        #expect(store.credentials(for: endpoint) == token)
        #expect(!store.hasSavedCredentials(for: endpoint))
        try store.commitStaged(for: endpoint)
        #expect(store.hasSavedCredentials(for: endpoint))
        // A fresh store (next launch) reads it back from Keychain.
        let relaunched = DirectHermesAccessCredentialStore(service: store.serviceForTesting)
        #expect(relaunched.credentials(for: endpoint) == token)
        store.remove(for: endpoint)
        #expect(!store.hasSavedCredentials(for: endpoint))
        #expect(store.credentials(for: endpoint) == nil)
    }

    @Test func tokensNeverGoOverPlainHTTP() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "http://10.8.0.5:9119", allowPrivateHTTP: true)
        store.stage(try DirectHermesAccessCredentials(clientID: id, clientSecret: secret), for: endpoint)
        #expect(store.headers(for: endpoint).isEmpty)
    }

    @Test func everyHostRequestAndSocketCarriesTheToken() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        let shared = DirectHermesAccessCredentialStore.shared
        shared.stage(try DirectHermesAccessCredentials(clientID: id, clientSecret: secret), for: endpoint)
        defer { shared.stage(nil, for: endpoint) }
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        let session = http.session.configuration.httpAdditionalHeaders as? [String: String]
        #expect(session?["CF-Access-Client-Id"] == id)
        #expect(session?["CF-Access-Client-Secret"] == secret)
        var socket = URLRequest(url: URL(string: "wss://example.com/api/ws")!)
        http.applyAccessHeaders(to: &socket)
        #expect(socket.value(forHTTPHeaderField: "CF-Access-Client-Id") == id)
        // Hosts without a token send nothing extra.
        let plain = DirectHermesHTTP(endpoint: try DirectHermesEndpoint(address: "https://other.example.com"))
        defer { plain.invalidate() }
        #expect(plain.accessHeaders.isEmpty)
    }

    @Test func cloudflareAccessRefusalsAreRecognized() throws {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://hermes.example.com/api/status")!, statusCode: status,
                            httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let login = response(302, ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/hermes.example.com"])
        #expect(DirectHermesHTTP.isCloudflareAccessDenial(login, sentAccessToken: false))
        let block = response(403, ["Content-Type": "text/html; charset=UTF-8", "CF-RAY": "8a1b2c3d4e5f-DFW"])
        #expect(DirectHermesHTTP.isCloudflareAccessDenial(block, sentAccessToken: true))
        // Hermes' own JSON errors and ordinary redirects are not Access.
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(response(403, ["Content-Type": "application/json", "CF-RAY": "x"]), sentAccessToken: true))
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(block, sentAccessToken: false))
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(response(302, ["Location": "https://evilcloudflareaccess.com/"]), sentAccessToken: true))
    }
}
