import Foundation
import Testing
@testable import Loopdy

struct LoopdyCardValidatorTests {
    @Test func rejectsUnreachableElementsCyclesAndUnknownBindingSources() throws {
        var base = try fixtureDocument()
        base["elements"] = .object([
            "root": .object([
                "type": .string("card"),
                "props": .object(["title": .string("Fixture")]),
                "children": .array([.string("metric")]),
            ]),
            "metric": .object([
                "type": .string("metric"),
                "props": .object([
                    "label": .string("Value"),
                    "value": .object([
                        "source": .string("missing"),
                        "pointer": .string("/value"),
                    ]),
                ]),
                "children": .array([]),
            ]),
        ])
        let unknownSource = try LoopdyCardDocument(document: base)
        #expect(throws: LoopdyCardValidationError.self) {
            try LoopdyCardValidator.validate(unknownSource)
        }

        var cyclic = base
        cyclic["data_sources"] = .array([
            .object([
                "id": .string("missing"),
                "request": .object([
                    "method": .string("GET"),
                    "url": .string("https://api.example.com/value"),
                ]),
                "response": .object(["format": .string("json"), "root": .string("")]),
                "refresh": .object([
                    "minimum_interval_seconds": .integer(60),
                    "stale_after_seconds": .integer(180),
                    "expires_at": .string("2026-09-03T12:00:00Z"),
                ]),
            ]),
        ])
        guard case .object(var elements) = cyclic["elements"] else { return }
        guard case .object(var metric) = elements["metric"] else { return }
        metric["children"] = .array([.string("root")])
        elements["metric"] = .object(metric)
        cyclic["elements"] = .object(elements)
        let cycle = try LoopdyCardDocument(document: cyclic)
        #expect(throws: LoopdyCardValidationError.self) {
            try LoopdyCardValidator.validate(cycle)
        }
    }

    @Test func acceptsTheBoundedFixtureGraph() throws {
        let card = try LoopdyCardDocument(document: fixtureDocument())
        #expect(try LoopdyCardValidator.validate(card) == card)
    }

    @Test func buildThreeRejectsLiveDataSourcesButKeepsStaticCardsValid() throws {
        let staticCard = try LoopdyCardDocument(document: fixtureDocument())
        #expect(try LoopdyCardValidator.validateForStaticRelease(staticCard) == staticCard)

        var liveDocument = try fixtureDocument()
        liveDocument["data_sources"] = .array([
            .object([
                "id": .string("prices"),
                "request": .object([
                    "method": .string("GET"),
                    "url": .string("https://api.example.com/value"),
                ]),
                "response": .object(["format": .string("json"), "root": .string("")]),
                "refresh": .object([
                    "minimum_interval_seconds": .integer(60),
                    "stale_after_seconds": .integer(180),
                    "expires_at": .string("2026-09-03T12:00:00Z"),
                ]),
            ]),
        ])
        let liveCard = try LoopdyCardDocument(document: liveDocument)

        do {
            _ = try LoopdyCardValidator.validateForStaticRelease(liveCard)
            Issue.record("Expected live card data to be unavailable in build 3")
        } catch let error as LoopdyCardValidationError {
            #expect(error == .liveDataUnavailable)
        }
    }

    private func fixtureDocument() throws -> [String: LoopdyJSONValue] {
        [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string("Fixture"),
            "spoken_summary": .string("Fixture summary"),
            "data_sources": .array([]),
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
        ]
    }
}
