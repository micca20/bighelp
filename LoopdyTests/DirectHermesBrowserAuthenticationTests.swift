import Foundation
import Testing
@testable import Loopdy

struct DirectHermesBrowserAuthenticationTests {
    @Test @MainActor func syntheticBrokerReturnsThroughTheRealLoopbackListener() async throws {
        var callbackTask: Task<Void, Error>?
        let browser = DirectHermesBrowserAuthentication { authorizeURL in
            let authorize = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false))
            #expect(authorize.path == "/prefix/auth/native/authorize")
            let items = try #require(authorize.queryItems)
            #expect(!items.contains(where: { $0.name == "provider" }))
            #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
            let redirect = try #require(items.first(where: { $0.name == "redirect_uri" })?.value)
            let state = try #require(items.first(where: { $0.name == "state" })?.value)
            var callback = try #require(URLComponents(string: redirect))
            #expect(callback.host == "127.0.0.1" && callback.port != nil)
            callback.queryItems = [URLQueryItem(name: "state", value: state),
                                   URLQueryItem(name: "code", value: "synthetic-broker-code")]
            let url = try #require(callback.url)
            callbackTask = Task { @MainActor in
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (_, response) = try await session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
        }
        defer { callbackTask?.cancel(); browser.cancel() }
        let result = try await browser.authorizationCode(
            endpoint: DirectHermesEndpoint(address: "https://example.invalid/prefix"),
            callbackPath: "/callback/synthetic", state: "synthetic-state",
            challenge: "synthetic-challenge", provider: nil
        )
        #expect(result == "synthetic-broker-code")
        let task = try #require(callbackTask)
        try await task.value
    }

    @Test @MainActor func cancellingBrowserOwnerRetiresTheActualListener() async throws {
        var browser: DirectHermesBrowserAuthentication?
        browser = DirectHermesBrowserAuthentication { _ in browser?.cancel() }
        let instance = try #require(browser)
        defer { instance.cancel() }
        await #expect(throws: DirectHermesError.cancelled(outcomeUnknown: false)) {
            try await instance.authorizationCode(
                endpoint: DirectHermesEndpoint(address: "https://example.invalid"),
                callbackPath: "/callback/cancel", state: "synthetic-state",
                challenge: "synthetic-challenge", provider: nil
            )
        }
    }

    @Test func callbackRequiresExactPathHostAndState() throws {
        let callback = try DirectHermesBrowserCallback(port: 49152, path: "/callback/attempt-a", state: "state-a")
        let request = "GET /callback/attempt-a?state=state-a&code=one-use-code HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nUser-Agent: WebKit\r\n\r\n"
        #expect(try callback.validate(Data(request.utf8)) == "one-use-code")
        for bad in [
            request.replacingOccurrences(of: "state=state-a", with: "state=state-b"),
            request.replacingOccurrences(of: "127.0.0.1:49152", with: "127.0.0.1:49153"),
            request.replacingOccurrences(of: "/callback/attempt-a?", with: "/callback/other?"),
            request.replacingOccurrences(of: "&code=", with: "&state=state-a&code="),
            request.replacingOccurrences(of: "GET ", with: "POST "),
            request.replacingOccurrences(of: "one-use-code", with: "%ZZ"),
            request.replacingOccurrences(of: "one-use-code", with: "bad%0Acode"),
            request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n"),
            request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: attacker\r\n\r\n")
        ] {
            #expect(throws: DirectHermesError.self) { try callback.validate(Data(bad.utf8)) }
        }
    }

    @Test func callbackFramingIsBoundedAndSingleRequest() throws {
        var parser = DirectHermesBrowserRequestParser()
        let partial = try parser.append(Data("GET /callback?code=c&state=s HTTP/1.1\r\n".utf8))
        #expect(partial == nil)
        let completedRequest = try parser.append(Data("Host: 127.0.0.1:49152\r\n\r\n".utf8))
        let complete = try #require(completedRequest)
        #expect(!complete.isEmpty)
        #expect(throws: DirectHermesError.self) { try parser.append(Data([0])) }
        var oversized = DirectHermesBrowserRequestParser()
        #expect(throws: DirectHermesError.self) { try oversized.append(Data(repeating: 65, count: 16_385)) }
        var pipelined = DirectHermesBrowserRequestParser()
        #expect(throws: DirectHermesError.self) { try pipelined.append(Data("GET / HTTP/1.1\r\nHost: h\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)) }
    }
}
