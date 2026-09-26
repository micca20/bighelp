import Foundation
import Testing
@testable import Loopdy

@MainActor
struct ModelNameCatalogTests {
    private func catalogData(_ label: String = "GPT-6 Astra") -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "revision": "test", "models": ["gpt-6-astra": label]])
    }

    @Test func catalogOverridesDisplayButPreservesUnknownIDs() throws {
        let catalog = try ModelNameCatalog.decode(catalogData())
        #expect(catalog.displayName(for: "gpt-6-astra") == "GPT-6 Astra")
        #expect(catalog.displayName(for: "custom/production-model-v2") == "custom/production-model-v2")
        #expect(catalog.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(catalog.displayName(for: "fable-5.1") == "Fable 5.1")
        #expect(catalog.displayName(for: "gemini-3.8-flash") == "Gemini 3.8 Flash")
    }

    @Test func knownFamiliesAndProviderQualifiedIDsHaveFriendlyFallbacks() {
        let catalog = ModelNameCatalog.empty
        for (id, label) in [("gpt-5.6", "GPT-5.6"), ("claude-sonnet-4.6", "Sonnet 4.6"), ("anthropic/claude-opus-5", "Opus 5"), ("google/gemini-3.8-flash", "Gemini 3.8 Flash"), ("custom/gpt-6-astra", "custom/gpt-6-astra")] {
            #expect(catalog.displayName(for: id) == label)
        }
    }

    @Test func searchMatchesFriendlyNameAndExactIDWithoutChangingResults() {
        let provider = LoopdyLinkModelProvider(id: "copilot", name: "Copilot", isCurrent: true, isCustom: false, models: ["gpt-6-astra"])
        for query in ["GPT-6 Astra", "gpt-6-astra"] {
            let groups = LoopdyModelPickerFiltering.groups(providers: [provider], currentProviderID: "copilot", query: query, displayName: { ModelNameCatalog.empty.displayName(for: $0) })
            #expect(groups.first?.models == ["gpt-6-astra"])
        }
    }

    @Test func invalidCatalogIsRejectedCompletely() throws {
        let invalidObjects: [[String: Any]] = [
            ["version": 2, "revision": "test", "models": ["gpt-6-astra": "Wrong"]],
            ["version": 1, "revision": "test", "models": ["gpt-6-astra": ""]],
            ["version": 1, "revision": "test", "models": ["gpt-6-astra": "Bad\nlabel"]],
            ["version": 1, "revision": "test", "models": ["gpt-6-astra": String(repeating: "a", count: 101)]],
            ["version": true, "revision": "test", "models": [:]],
        ]
        for object in invalidObjects {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try ModelNameCatalog.decode(data) }
        }
    }

    @Test func refreshPublishesAndPersistsLabelsWithoutChangingModelIDs() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("names.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let data = catalogData("Astra Friendly")
        let store = ModelNameCatalogStore(cacheURL: cache, bundledData: catalogData(), loader: { data })
        #expect(store.displayName(for: "gpt-6-astra") == "GPT-6 Astra")
        await store.refresh()
        #expect(store.displayName(for: "gpt-6-astra") == "Astra Friendly")
        #expect(store.isRefreshing == false)
        let restored = ModelNameCatalogStore(cacheURL: cache, bundledData: catalogData(), loader: { throw URLError(.notConnectedToInternet) })
        #expect(restored.displayName(for: "gpt-6-astra") == "Astra Friendly")
        await restored.refresh()
        #expect(restored.displayName(for: "gpt-6-astra") == "Astra Friendly")
        #expect(restored.statusMessage != nil)
    }

    @Test func invalidRefreshRetainsBundledLabels() async {
        let store = ModelNameCatalogStore(cacheURL: nil, bundledData: catalogData(), loader: { Data("not-json".utf8) })
        await store.refresh()
        #expect(store.displayName(for: "gpt-6-astra") == "GPT-6 Astra")
        #expect(!store.isRefreshing)
        #expect(store.statusMessage != nil)
    }
}
