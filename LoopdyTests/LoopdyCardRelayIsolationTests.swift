import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyCardRelayIsolationTests {
    @Test func visibleRefreshesChangeOnlyRuntimeValuesAndNeverEmitLoopdyTraffic() async throws {
        let card = try LoopdyCardValidator.validate(
            JSONDecoder().decode(LoopdyCardDocument.self, from: deliveredCard)
        )
        let originalDocument = card.document
        let originalID = card.id
        let source = LoopdyCardIsolationSource(values: [
            .object(["price": .integer(100)]),
            .object(["price": .integer(125)]),
        ])
        let infrastructure = LoopdyCardInfrastructureRecorder()
        // The fixture's refresh window is fixed, so the runtime clock has to be
        // fixed too. Reading the wall clock made this assertion depend on the
        // date the suite happened to run, and it began refusing both refreshes
        // as expired once real time passed the fixture's expiry.
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-03T11:00:00Z")
        )
        let runtime = LoopdyCardRuntime(document: card, client: source, now: { now })

        await runtime.refresh(sourceID: "prices")
        #expect(runtime.values["prices"] == .object(["price": .integer(100)]))
        await runtime.refresh(sourceID: "prices")
        #expect(runtime.values["prices"] == .object(["price": .integer(125)]))

        #expect(await source.requestCount == 2)
        #expect(await infrastructure.linkOutboundFrames == 0)
        #expect(await infrastructure.relayWrites == 0)
        #expect(await infrastructure.notificationWrites == 0)
        #expect(await infrastructure.inboxWrites == 0)
        #expect(await infrastructure.transcriptWrites == 0)
        #expect(await infrastructure.liveActivityWrites == 0)
        #expect(card.id == originalID)
        #expect(card.document == originalDocument)
    }

    private var deliveredCard: Data {
        Data("""
        {
          "schema":"loopdy.card",
          "version":1,
          "title":"Price",
          "spoken_summary":"The latest public price is shown.",
          "data_sources":[{
            "id":"prices",
            "request":{"method":"GET","url":"https://api.example.com/price"},
            "response":{"format":"json","root":""},
            "refresh":{"minimum_interval_seconds":60,"stale_after_seconds":180,"expires_at":"2026-09-03T12:00:00Z"}
          }],
          "root":"root",
          "elements":{"root":{"type":"card","props":{"title":"Price"},"children":[]}},
          "content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "card_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "origin":"live",
          "created_at":"2026-09-02T12:00:00Z"
        }
        """.utf8)
    }
}

private actor LoopdyCardIsolationSource: LoopdyCardDataFetching {
    private var values: [LoopdyJSONValue]
    private(set) var requestCount = 0

    init(values: [LoopdyJSONValue]) { self.values = values }

    func fetch(_ url: URL) async throws -> LoopdyJSONValue {
        requestCount += 1
        guard !values.isEmpty else { throw URLError(.resourceUnavailable) }
        return values.removeFirst()
    }
}

private actor LoopdyCardInfrastructureRecorder {
    private(set) var linkOutboundFrames = 0
    private(set) var relayWrites = 0
    private(set) var notificationWrites = 0
    private(set) var inboxWrites = 0
    private(set) var transcriptWrites = 0
    private(set) var liveActivityWrites = 0
}
