import Foundation
import Testing
@testable import Loopdy

@MainActor
struct HermesLogsTests {
    @Test func queryBoundsMatchStockTailContract() throws {
        #expect(try HermesLogQuery(lineLimit: 500).lineLimit == 500)
        #expect(throws: HermesLogsClientError.self) { try HermesLogQuery(lineLimit: 501) }
        #expect(throws: HermesLogsClientError.self) { try HermesLogQuery(lineLimit: 0) }
        #expect(throws: HermesLogsClientError.self) { try HermesLogQuery(search: String(repeating: "x", count: 201)) }
        #expect(throws: HermesLogsClientError.self) { try HermesLogQuery(search: "one\u{0}two") }
    }

    @Test func headersAndContinuationLinesRemainUseful() throws {
        let parsed = try HermesLogCodec.entry("2026-09-15 12:34:56,789 WARNING [session] agent.example: ordinary diagnostic\n", id: 0)
        #expect(parsed.timestampText == "2026-09-15 12:34:56,789")
        #expect(parsed.severity == .warning)
        #expect(parsed.logger == "agent.example")
        #expect(parsed.message == "ordinary diagnostic")
        let continuation = try HermesLogCodec.entry("  retrying /srv/work/file.txt", id: 1)
        #expect(continuation.severity == .unclassified)
        #expect(continuation.message == "  retrying /srv/work/file.txt")
        #expect(throws: HermesLogsClientError.self) { try HermesLogCodec.entry("bad\u{0}row", id: 2) }
    }

    @Test func credentialHeaderRedactsBeforeLoggerSplitting() throws {
        let marker = "synthetic-fixture-credential"
        let parsed = try HermesLogCodec.entry("2026-09-15 12:34:56 INFO Authorization: Bearer " + marker, id: 0)
        #expect(!parsed.message.contains(marker))
        #expect(parsed.message.contains("redacted-secret"))
    }

    @Test func supersededFailureCannotReplaceFreshLogState() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "logs-test"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        let client = LogsReaderFixture(owner: owner)
        client.holdFirst = true
        let store = HermesLogsStore(hostName: "Fixture", owner: owner, client: client)
        defer { client.releaseFailure(); store.retire() }
        let old = Task { await store.refresh() }
        for _ in 0..<500 where client.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        try #require(client.pending != nil)
        store.searchText = "current"
        await store.applyFilters()
        client.releaseFailure()
        await old.value
        #expect(store.appliedQuery?.search == "current")
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test func tailExpansionIsBoundedAndRetirementClearsMemory() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "logs-window"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        let client = LogsReaderFixture(owner: owner)
        let store = HermesLogsStore(hostName: "Fixture", owner: owner, client: client)
        await store.refresh()
        for _ in 0..<5 { await store.loadEarlier() }
        #expect(client.limits == [100, 200, 300, 400, 500])
        #expect(!store.canLoadEarlier)
        store.retire()
        #expect(store.entries.isEmpty)
        #expect(store.appliedQuery == nil)
        #expect(store.searchText.isEmpty)
    }
}

@MainActor
private final class LogsReaderFixture: HermesLogsReading {
    var owner: WorkspaceOwner?
    var limits: [Int] = []
    var holdFirst = false
    var pending: CheckedContinuation<HermesLogPage, any Error>?
    init(owner: WorkspaceOwner) { self.owner = owner }
    func read(_ query: HermesLogQuery) async throws -> HermesLogPage {
        limits.append(query.lineLimit)
        if holdFirst && limits.count == 1 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return .init(query: query, entries: try (0..<query.lineLimit).map { try HermesLogCodec.entry("fixture diagnostic \($0)", id: $0) })
    }
    func releaseFailure() {
        let value = pending
        pending = nil
        value?.resume(throwing: HermesLogsClientError.invalidResponse)
    }
}
