import Foundation
import Testing
@testable import Bighelp

struct BighelpCardEnvelopeTests {
    @Test func staticCardDecodesWithoutChangingLegacyEnvelopeDispatch() throws {
        let cardJSON = """
        {
          "schema":"loopdy.card",
          "version":1,
          "title":"Fixture card",
          "spoken_summary":"Fixture card summary",
          "data_sources":[],
          "root":"root",
          "elements":{"root":{"type":"card","props":{"title":"Fixture card"},"children":[]}},
          "content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "card_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "origin":"live",
          "created_at":"2026-09-02T12:00:00Z"
        }
        """
        let envelope = try JSONDecoder().decode(BighelpCardEnvelope.self, from: Data(cardJSON.utf8))
        guard case .card(let card) = envelope else {
            Issue.record("Expected the static card envelope")
            return
        }
        #expect(card.title == "Fixture card")

        let legacyJSON = """
        {
          "schema":"loopdy.generative_ui",
          "version":1,
          "component":"summary",
          "title":"Legacy fixture",
          "body":"Still supported"
        }
        """
        let legacy = try JSONDecoder().decode(
            BighelpCardEnvelope.self,
            from: Data(legacyJSON.utf8)
        )
        guard case .legacy(let card) = legacy else {
            Issue.record("Expected legacy envelope")
            return
        }
        #expect(card.title == "Legacy fixture")
    }

    @Test func envelopeRejectsUnknownSchemaAndVersion() {
        let unknown = Data("{\"schema\":\"loopdy.card\",\"version\":2}".utf8)
        #expect(throws: BighelpCardEnvelopeError.self) {
            try JSONDecoder().decode(BighelpCardEnvelope.self, from: unknown)
        }
    }

    @Test func deliveredEnvelopeRejectsLiveDataSourcesForBuildThree() {
        let liveCard = Data("""
        {
          "schema":"loopdy.card",
          "version":1,
          "title":"Live fixture",
          "spoken_summary":"This live fixture must not reach the renderer.",
          "data_sources":[{
            "id":"feed",
            "request":{"method":"GET","url":"https://api.example.com/value"},
            "response":{"format":"json","root":""},
            "refresh":{"minimum_interval_seconds":60,"stale_after_seconds":180,"expires_at":"2026-09-03T12:00:00Z"}
          }],
          "root":"root",
          "elements":{"root":{"type":"card","props":{"title":"Live fixture"},"children":[]}},
          "content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "card_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "origin":"live",
          "created_at":"2026-09-02T12:00:00Z"
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(BighelpCardEnvelope.self, from: liveCard)
            Issue.record("Expected the delivered live-source envelope to be rejected")
        } catch let error as BighelpCardValidationError {
            #expect(error == .liveDataUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
