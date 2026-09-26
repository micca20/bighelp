import Foundation
import Testing
@testable import Bighelp

struct BighelpCardDataClientTests {
    @Test func staticOnlyProductionClientRejectsRemoteFetch() async throws {
        let client = BighelpCardStaticDataClient()
        let url = try #require(URL(string: "https://api.example.com/value"))

        await #expect(throws: BighelpCardStaticDataError.liveDataUnavailable) {
            _ = try await client.fetch(url)
        }
    }

    @Test func sendsCredentialFreeJSONGetAndDeduplicatesConcurrentRequests() async throws {
        let transport = BighelpCardHTTPTransportFixture(
            data: Data("{\"value\":42}".utf8),
            headers: ["Content-Type": "application/json"],
            delay: .milliseconds(50)
        )
        let client = BighelpCardDataClient(transport: transport)
        let url = try #require(URL(string: "https://api.example.com/value"))

        async let first = client.fetch(url)
        async let second = client.fetch(url)
        let values = try await [first, second]
        #expect(values == [.object(["value": .integer(42)]), .object(["value": .integer(42)])])
        #expect(await transport.requestCount == 1)
        let request = try #require(await transport.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func rejectsWrongMimeTypeOversizedBodiesAndExcessiveJSONComplexity() async throws {
        let url = try #require(URL(string: "https://api.example.com/value"))
        let wrongMime = BighelpCardDataClient(transport: BighelpCardHTTPTransportFixture(
            data: Data("{}".utf8),
            headers: ["Content-Type": "text/html"]
        ))
        await #expect(throws: BighelpCardDataClientError.self) {
            _ = try await wrongMime.fetch(url)
        }

        let oversized = BighelpCardDataClient(transport: BighelpCardHTTPTransportFixture(
            data: Data(repeating: 0x20, count: 2_000_001),
            headers: ["Content-Type": "application/json"]
        ))
        await #expect(throws: BighelpCardDataClientError.self) {
            _ = try await oversized.fetch(url)
        }

        var nested = "0"
        for _ in 0..<30 { nested = "[\(nested)]" }
        let excessive = BighelpCardDataClient(transport: BighelpCardHTTPTransportFixture(
            data: Data(nested.utf8),
            headers: ["Content-Type": "application/json"]
        ))
        await #expect(throws: BighelpCardDataClientError.self) {
            _ = try await excessive.fetch(url)
        }
    }
    @Test func rejectsUnsafeFinalURLAndNonSuccessStatus() async throws {
        let url = try #require(URL(string: "https://api.example.com/value"))
        let privateRedirect = BighelpCardDataClient(transport: BighelpCardHTTPTransportFixture(
            data: Data("{}".utf8),
            headers: ["Content-Type": "application/json"],
            responseURL: try #require(URL(string: "https://127.0.0.1/private"))
        ))
        await #expect(throws: BighelpCardDataClientError.self) {
            _ = try await privateRedirect.fetch(url)
        }

        let serverError = BighelpCardDataClient(transport: BighelpCardHTTPTransportFixture(
            data: Data("{}".utf8),
            headers: ["Content-Type": "application/json"],
            status: 503
        ))
        await #expect(throws: BighelpCardDataClientError.self) {
            _ = try await serverError.fetch(url)
        }
    }
}

private actor BighelpCardHTTPTransportFixture: BighelpCardHTTPTransport {
    private let data: Data
    private let headers: [String: String]
    private let status: Int
    private let responseURL: URL?
    private let delay: Duration?
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    init(
        data: Data,
        headers: [String: String],
        status: Int = 200,
        responseURL: URL? = nil,
        delay: Duration? = nil
    ) {
        self.data = data
        self.headers = headers
        self.status = status
        self.responseURL = responseURL
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        lastRequest = request
        if let delay { try await Task.sleep(for: delay) }
        let response = try #require(HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: headers
        ))
        return (data, response)
    }
}
