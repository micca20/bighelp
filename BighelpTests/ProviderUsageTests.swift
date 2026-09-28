import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ProviderUsageTests {
    /// The plugin contract's sample, plus things an older or newer plugin might send.
    private let sample: [String: BighelpJSONValue] = [
        "agentId": .string("default"),
        "fetchedAt": .string("2026-09-27T20:00:00Z"),
        "cached": .boolean(true),
        "futureField": .string("ignored"),
        "providers": .array([
            .object([
                "id": .string("claude"), "name": .string("Claude"), "status": .string("ok"),
                "plan": .string("Pro"), "detectedVia": .array([.string("cli")]), "activeInHermes": .boolean(false),
                "windows": .array([.object(["label": .string("Session (5 hours)"), "usedPercent": .number(142),
                                            "resetsAt": .string("2026-09-27T23:00:00Z"), "detail": .null])]),
                "facts": .array([]), "manageUrl": .string("https://claude.ai/settings/usage"), "approximate": .boolean(false),
            ]),
            .object([
                "id": .string("openrouter"), "name": .string("OpenRouter"), "status": .string("ok"),
                "activeInHermes": .boolean(true),
                "facts": .array([.object(["label": .string("Balance"), "value": .string("$25.00")])]),
                "manageUrl": .string("http://not-https.example.com"),
            ]),
            .object(["id": .string("hermes-xai"), "name": .string("xAI"), "status": .string("somethingNew"),
                     "message": .string("New status")]),
            .object(["name": .string("No id")]),
        ]),
    ]

    @Test func decodesTolerantlyAndClampsPercentages() throws {
        let report = try ProviderUsageReport(json: sample)
        #expect(report.agentID == "default" && report.cached)
        #expect(report.fetchedAt == ISO8601DateFormatter().date(from: "2026-09-27T20:00:00Z"))
        #expect(report.providers.map(\.id) == ["claude", "openrouter", "hermes-xai"], "A row without an id is skipped")
        let claude = report.providers[0]
        #expect(claude.windows.first?.usedPercent == 100)
        #expect(claude.windows.first?.leftPercent == 0)
        #expect(claude.windows.first?.detail == nil)
        #expect(claude.manageURL?.absoluteString == "https://claude.ai/settings/usage")
        #expect(report.providers[1].manageURL == nil, "Only https links open")
        #expect(report.providers[1].facts == [.init(label: "Balance", value: "$25.00")])
        #expect(report.providers[2].status == .error, "Unknown statuses read as errors with their message")
        #expect(report.providers[2].message == "New status")
        #expect(throws: WorkspaceClientError.self) { try ProviderUsageReport(json: ["providers": .string("nope")]) }
    }

    @Test func activeProviderComesFirstAndHiddenOnesAreLeftOut() throws {
        let providers = try ProviderUsageReport(json: sample).providers
        #expect(ProviderUsagePresentation.visible(providers, hidden: []).map(\.id) == ["openrouter", "claude", "hermes-xai"])
        #expect(ProviderUsagePresentation.visible(providers, hidden: ["claude"]).map(\.id) == ["openrouter", "hermes-xai"])
        let hidden: Set<String> = ["b", "a"]
        #expect(ProviderUsagePreferences.hidden(ProviderUsagePreferences.raw(hidden)) == hidden)
        #expect(ProviderUsagePreferences.hidden("").isEmpty, "Nothing saved shows every provider")
    }

    @Test func resetAndUpdatedTimesReadNaturally() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(3 * 3_600 + 12 * 60), now: now) == "Resets in 3 h 12 min")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(2 * 3_600), now: now) == "Resets in 2 h")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(20), now: now) == "Resets in 1 min")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(3 * 86_400), now: now) == "Resets in 3 days")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(-5), now: now) == "Resets soon")
        #expect(ProviderUsagePresentation.resetText(nil, now: now) == nil)
        #expect(ProviderUsagePresentation.updatedText(now.addingTimeInterval(-20), now: now) == "Updated just now")
        #expect(ProviderUsagePresentation.updatedText(now.addingTimeInterval(-180), now: now) == "Updated 3 min ago")
    }

    @Test func pluginIDsMapToTheirBrandLogos() {
        #expect(ProviderUsagePresentation.logoProviderID("codex-hermes") == "codex")
        #expect(ProviderUsagePresentation.logoProviderID("hermes-xai") == "xai")
        #expect(AIProviderBrandRegistry.resolve(id: "claude", name: "Claude") == .claude)
        #expect(AIProviderBrandRegistry.resolve(id: "codex", name: "Codex") == .codex)
        #expect(AIProviderBrandRegistry.resolve(id: "copilot", name: "GitHub Copilot") == .githubCopilot)
        #expect(AIProviderBrandRegistry.resolve(id: "gemini", name: "Google AI Studio") == .google)
    }

    @Test func olderPluginAskForAnUpdateAndFailuresKeepTheLastResult() async throws {
        let client = ScriptedUsageClient()
        let store = ProviderUsageStore()
        store.configure(client: client)
        #expect(store.isAvailable)

        client.result = .failure(WorkspaceClientError.unavailable(.unsupportedOperation))
        await store.load(refresh: false)
        #expect(store.state == .needsPluginUpdate)

        client.result = .success(try ProviderUsageReport(json: sample))
        await store.load(refresh: false)
        #expect(store.state == .loaded && store.report?.providers.count == 3)

        client.result = .failure(WorkspaceClientError.transportUnavailable)
        await store.load(refresh: true)
        #expect(store.report?.providers.count == 3, "The last result stays on screen")
        #expect(store.state == .unavailable("Couldn't refresh. Showing the last result."))
        #expect(!store.isRefreshing)
        #expect(client.refreshes == [false, false, true])

        store.configure(client: nil)
        #expect(!store.isAvailable && store.report == nil)
    }
}

@MainActor
private final class ScriptedUsageClient: ProviderUsageClient {
    var result: Result<ProviderUsageReport, any Error> = .failure(WorkspaceClientError.invalidResponse)
    var refreshes: [Bool] = []
    func usage(agentID: String, refresh: Bool) async throws -> ProviderUsageReport {
        refreshes.append(refresh)
        return try result.get()
    }
}
