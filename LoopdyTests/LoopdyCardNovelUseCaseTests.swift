import Foundation
import Testing
@testable import Loopdy

struct LoopdyCardNovelUseCaseTests {
    @Test func threeUnrelatedFixturesUseOnlyTheSharedFiniteCatalog() throws {
        let cards = try ["live-bitcoin.json", "live-earthquakes.json", "live-weather.json"].map(load)
        let typeSets = cards.map { card in
            Set(card.elements.values.compactMap { $0.object?["type"]?.string })
        }
        #expect(typeSets[0].isSuperset(of: ["card", "hstack", "image", "metric", "badge"]))
        #expect(typeSets[1].isSuperset(of: ["card", "list", "hstack", "text", "badge"]))
        #expect(typeSets[2].isSuperset(of: ["card", "grid", "metric", "progress"]))
        #expect(typeSets.allSatisfy { $0.isSubset(of: LoopdyCardRenderer.supportedTypes) })
    }

    @Test func fixtureBindingsResolveAgainstDeterministicPublicResponses() throws {
        let bitcoin = try load("live-bitcoin.json")
        let bitcoinPrice = try #require(bitcoin.elements["price"]?.object?["props"]?.object?["value"])
        #expect(LoopdyCardValueResolver.resolve(
            bitcoinPrice,
            sources: ["coinbase": .object(["amount": .string("64000.25"), "currency": .string("USD")])]
        ) == .value(.string("64000.25")))

        let earthquakes = try load("live-earthquakes.json")
        let itemsBinding = try #require(earthquakes.elements["quakes"]?.object?["props"]?.object?["items"])
        let feature: LoopdyJSONValue = .object([
            "properties": .object(["place": .string("10 km west of Test"), "mag": .number(5.2)]),
        ])
        let feed: LoopdyJSONValue = .object(["features": .array([feature])])
        #expect(LoopdyCardValueResolver.resolve(itemsBinding, sources: ["usgs": feed]) == .value(.array([feature])))
        let placeBinding = try #require(earthquakes.elements["quake_place"]?.object?["props"]?.object?["value"])
        #expect(LoopdyCardValueResolver.resolve(
            placeBinding,
            sources: ["usgs": feed],
            item: feature,
            itemSourceID: "usgs"
        ) == .value(.string("10 km west of Test")))

        let weather = try load("live-weather.json")
        let humidityBinding = try #require(weather.elements["humidity"]?.object?["props"]?.object?["value"])
        #expect(LoopdyCardValueResolver.resolve(
            humidityBinding,
            sources: ["weather": .object(["relative_humidity_2m": .integer(63)])]
        ) == .value(.integer(63)))
    }

    private func load(_ name: String) throws -> LoopdyCardDocument {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository
            .appendingPathComponent("plugins/loopdy/fixtures/loopdy_card_v1")
            .appendingPathComponent(name)
        var document = try JSONDecoder().decode(
            [String: LoopdyJSONValue].self,
            from: Data(contentsOf: url)
        )
        document["content_hash"] = .string(String(repeating: "a", count: 64))
        document["card_id"] = .string(String(repeating: "b", count: 32))
        document["origin"] = .string("live")
        document["created_at"] = .string("2026-09-02T12:00:00Z")
        return try LoopdyCardValidator.validate(LoopdyCardDocument(document: document))
    }
}
