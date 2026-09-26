import CryptoKit
import Foundation
import Testing
@testable import Loopdy

struct LoopdyCardCatalogClientTests {
    private static let fixtureSigningSeed = Data((1...32).map(UInt8.init))
    private static let fixtureSigningKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: fixtureSigningSeed
    )

    @Test func committedFixtureHasAValidSignatureAndBundleHash() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/card-catalog-index.json")
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let client = LoopdyCardCatalogClient(
            indexURL: fixtureURL,
            pinnedPublicKey: Self.fixtureSigningKey.publicKey.rawRepresentation,
            supportedLoopdyVersion: "1.0.0",
            supportedCardVersion: 1,
            cacheURL: cacheURL
        )

        let snapshot = try await client.load()

        #expect(snapshot.source == .index)
        #expect(snapshot.entries.map(\.id) == ["weather-brief"])
        #expect(snapshot.entries.first?.name == "Weather Brief")
        #expect(snapshot.entries.first?.document.title == "Weather Brief")
    }

    @Test func invalidIndexSignatureIsRejected() async throws {
        let signed = try makeSignedIndex(entries: [makeEntry()])
        var object = try #require(JSONSerialization.jsonObject(with: signed) as? [String: Any])
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let client = makeClient(data: tampered)

        await #expect(throws: LoopdyCardCatalogError.invalidSignature) {
            try await client.load()
        }
    }

    @Test func bundleHashMismatchIsRejectedEvenWhenIndexSignatureIsValid() async throws {
        var entry = makeEntry()
        entry["bundle_sha256"] = String(repeating: "0", count: 64)
        let client = makeClient(data: try makeSignedIndex(entries: [entry]))

        await #expect(throws: LoopdyCardCatalogError.bundleHashMismatch(id: "weather-brief")) {
            try await client.load()
        }
    }

    @Test func entriesRequiringANewerLoopdyVersionAreFilteredOut() async throws {
        var future = makeEntry(id: "future-card")
        future["minimum_loopdy_version"] = "99.0.0"
        let client = makeClient(
            data: try makeSignedIndex(entries: [makeEntry(), future]),
            supportedLoopdyVersion: "1.0.0"
        )

        let snapshot = try await client.load()

        #expect(snapshot.entries.map(\.id) == ["weather-brief"])
    }

    @Test func malformedEntryRejectsTheWholeSignedIndex() async throws {
        var malformed = makeEntry()
        malformed.removeValue(forKey: "bundle_sha256")
        let client = makeClient(data: try makeSignedIndex(entries: [malformed]))

        await #expect(throws: LoopdyCardCatalogError.malformedIndex) {
            try await client.load()
        }
    }

    @Test func unsupportedCardVersionIsRejectedBeforeDisplay() async throws {
        let entry = makeEntry(minimumCardVersion: 2)
        let client = makeClient(
            data: try makeSignedIndex(entries: [entry]),
            supportedCardVersion: 1
        )

        await #expect(throws: LoopdyCardCatalogError.unsupportedCardVersion(id: "weather-brief", version: 2)) {
            try await client.load()
        }
    }

    @Test func duplicateTemplateIDRejectsTheWholeSignedIndex() async throws {
        let client = makeClient(
            data: try makeSignedIndex(entries: [makeEntry(), makeEntry()])
        )

        await #expect(throws: LoopdyCardCatalogError.duplicateID("weather-brief")) {
            try await client.load()
        }
    }

    @Test func verifiedCachedIndexIsUsedWhenRefreshIsOffline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyCardCatalogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cacheURL = directory.appending(path: "catalog-index.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try makeSignedIndex(entries: [makeEntry()])
        let warmClient = makeClient(data: signed, cacheURL: cacheURL)
        _ = try await warmClient.load()
        let offlineClient = LoopdyCardCatalogClient(
            indexURL: URL(string: "https://catalog.invalid/index.json"),
            pinnedPublicKey: Self.fixtureSigningKey.publicKey.rawRepresentation,
            supportedLoopdyVersion: "1.0.0",
            supportedCardVersion: 1,
            cacheURL: cacheURL,
            dataLoader: { _ in throw URLError(.notConnectedToInternet) }
        )

        let snapshot = try await offlineClient.load()

        #expect(snapshot.source == .cache)
        #expect(snapshot.entries.map(\.id) == ["weather-brief"])
    }

    @Test func productionConfigurationHasNoCatalogURL() {
        #expect(LoopdyCardCatalogClient.productionIndexURL == nil)
    }

    private func makeClient(
        data: Data,
        supportedLoopdyVersion: String = "1.0.0",
        supportedCardVersion: Int = 1,
        cacheURL: URL? = nil
    ) -> LoopdyCardCatalogClient {
        LoopdyCardCatalogClient(
            indexURL: URL(string: "https://fixture.invalid/index.json"),
            pinnedPublicKey: Self.fixtureSigningKey.publicKey.rawRepresentation,
            supportedLoopdyVersion: supportedLoopdyVersion,
            supportedCardVersion: supportedCardVersion,
            cacheURL: cacheURL ?? temporaryCacheURL(),
            dataLoader: { _ in data }
        )
    }

    private func makeSignedIndex(entries: [[String: Any]]) throws -> Data {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "schema": "loopdy.card.catalog-payload",
                "version": 1,
                "entries": entries,
            ],
            options: [.sortedKeys]
        )
        let signature = try Self.fixtureSigningKey.signature(for: payload)
        return try JSONSerialization.data(
            withJSONObject: [
                "schema": "loopdy.card.catalog-index",
                "version": 1,
                "payload": payload.base64EncodedString(),
                "signature": signature.base64EncodedString(),
            ],
            options: [.sortedKeys]
        )
    }

    private func makeEntry(
        id: String = "weather-brief",
        minimumCardVersion: Int = 1
    ) -> [String: Any] {
        let document: [String: Any] = [
            "schema": "loopdy.card",
            "version": 1,
            "title": "Weather Brief",
            "spoken_summary": "Current conditions and forecast",
            "data_sources": [[
                "id": "forecast",
                "request": ["method": "GET", "url": "https://api.weather.gov/gridpoints/TOP/31,80/forecast"],
                "response": ["format": "json", "root": ""],
                "refresh": [
                    "minimum_interval_seconds": 900,
                    "stale_after_seconds": 3600,
                    "expires_at": "2026-09-08T12:00:00Z",
                ],
            ]],
            "root": "root",
            "elements": [
                "root": [
                    "type": "card",
                    "props": ["title": "Weather Brief"],
                    "children": ["temperature"],
                ],
                "temperature": [
                    "type": "metric",
                    "props": ["label": "Temperature", "value": "72°"],
                    "children": [],
                ],
            ],
            "content_hash": String(repeating: "a", count: 64),
            "card_id": "0123456789abcdef0123456789abcdef",
            "origin": "live",
            "created_at": "2026-09-02T12:00:00Z",
            "valid_until": "2026-09-08T12:00:00Z",
        ]
        let documentData = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let typedDocument = try! JSONDecoder().decode(
            [String: LoopdyJSONValue].self,
            from: documentData
        )
        let bundle: [String: Any] = [
            "id": id,
            "version": 1,
            "name": "Weather Brief",
            "summary": "A compact forecast from the National Weather Service.",
            "author": "Loopdy",
            "license": "MIT",
            "minimum_card_version": minimumCardVersion,
            "parameters_schema": ["type": "object", "properties": [:]],
            "document": document,
            "sha256": try! LoopdyCardTemplate.sha256(for: typedDocument),
        ]
        let bundleData = try! JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        return [
            "id": id,
            "minimum_loopdy_version": "1.0.0",
            "bundle": bundleData.base64EncodedString(),
            "bundle_sha256": SHA256.hash(data: bundleData).map { String(format: "%02x", $0) }.joined(),
        ]
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LoopdyCardCatalogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "catalog-index.json")
    }
}
