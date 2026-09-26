import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpCardRuntimeTests {
    @Test func keepsLastGoodValueFreshUntilStaleThresholdThenMarksItStale() async throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z"))
        let clock = BighelpCardMutableClock(start)
        let client = BighelpCardDataFixture(responses: [
            .object(["payload": .object(["value": .integer(42)])]),
            nil,
            nil,
        ])
        let runtime = BighelpCardRuntime(
            document: try document(expiry: "2026-09-03T12:00:00Z", root: "/payload"),
            client: client,
            now: { clock.date }
        )

        await runtime.refresh(sourceID: "feed")
        #expect(runtime.values["feed"] == .object(["value": .integer(42)]))
        guard case .updated = runtime.state else {
            Issue.record("Expected updated state")
            return
        }

        clock.date = start.addingTimeInterval(179)
        await runtime.refresh(sourceID: "feed")
        #expect(runtime.values["feed"] == .object(["value": .integer(42)]))
        guard case .updated = runtime.state else {
            Issue.record("Expected cached value to remain fresh before stale_after_seconds")
            return
        }

        clock.date = start.addingTimeInterval(180)
        await runtime.refresh(sourceID: "feed")
        #expect(runtime.values["feed"] == .object(["value": .integer(42)]))
        #expect(runtime.state == .stale)
    }

    @Test func expiredSourceDoesNotPerformNetworkAccess() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-04T12:00:00Z"))
        let client = BighelpCardDataFixture(responses: [.object([:])])
        let runtime = BighelpCardRuntime(
            document: try document(expiry: "2026-09-03T12:00:00Z", root: ""),
            client: client,
            now: { now }
        )

        await runtime.refresh(sourceID: "feed")
        #expect(runtime.state == .expired)
        #expect(await client.requestCount == 0)
    }

    @Test func leavingTheVisibleActiveLifecycleCancelsScheduledRefresh() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z"))
        let client = BighelpCardDataFixture(responses: [.object(["value": .integer(1)])])
        let runtime = BighelpCardRuntime(
            document: try document(expiry: "2026-09-03T12:00:00Z", root: ""),
            client: client,
            now: { now }
        )
        runtime.start()
        for _ in 0..<100 {
            if await client.requestCount > 0 { break }
            await Task.yield()
        }
        #expect(await client.requestCount == 1)
        runtime.setSceneActive(false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await client.requestCount == 1)
    }

    private func document(expiry: String, root: String) throws -> BighelpCardDocument {
        try BighelpCardDocument(document: [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string("Fixture"),
            "spoken_summary": .string("Fixture summary"),
            "data_sources": .array([
                .object([
                    "id": .string("feed"),
                    "request": .object([
                        "method": .string("GET"),
                        "url": .string("https://api.example.com/value"),
                    ]),
                    "response": .object(["format": .string("json"), "root": .string(root)]),
                    "refresh": .object([
                        "minimum_interval_seconds": .integer(60),
                        "stale_after_seconds": .integer(180),
                        "expires_at": .string(expiry),
                    ]),
                ]),
            ]),
            "root": .string("root"),
            "elements": .object([
                "root": .object([
                    "type": .string("card"),
                    "props": .object(["title": .string("Fixture")]),
                    "children": .array([]),
                ]),
            ]),
            "content_hash": .string(String(repeating: "a", count: 64)),
            "card_id": .string(String(repeating: "b", count: 32)),
            "origin": .string("live"),
            "created_at": .string("2026-09-02T12:00:00Z"),
        ])
    }
}

private final class BighelpCardMutableClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

private actor BighelpCardDataFixture: BighelpCardDataFetching {
    private var responses: [BighelpJSONValue?]
    private(set) var requestCount = 0

    init(responses: [BighelpJSONValue?]) {
        self.responses = responses
    }

    func fetch(_ url: URL) async throws -> BighelpJSONValue {
        requestCount += 1
        guard !responses.isEmpty, let response = responses.removeFirst() else {
            throw URLError(.cannotLoadFromNetwork)
        }
        return response
    }
}
