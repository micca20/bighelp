import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesReactionHistoryTests {
    @Test func stockHTTPEnvelopeRestoresExactRowReactions() async throws {
        let http = ReactionHistoryHTTP(pages: [0: page([row(4, metadata: .object(["reactions": .array([
            .object(["emoji": .string("👍"), "author": .string("user")])
        ])]))], offset: 0)])
        let result = try await load(http)
        #expect(result?.reactionsByRowID[4]?.reactions.first?.emoji == "👍")
        #expect(http.requests.count == 1)
        #expect(http.requests[0].path == "/api/sessions/stored/messages")
    }

    @Test func explicitEmptyMetadataClearsButMissingMetadataCannot() throws {
        var explicit = DirectHermesReactionHistoryDecoder.HTTPAccumulator()
        try explicit.consume([row(1, metadata: .null)])
        #expect(explicit.snapshot()?.reactionsByRowID.isEmpty == true)
        var absent = DirectHermesReactionHistoryDecoder.HTTPAccumulator()
        try absent.consume([.object(["id": .integer(1), "role": .string("assistant")])])
        #expect(absent.snapshot() == nil)
    }

    @Test func pagedHistoryMayExceedSocketLimitWithoutOneLargeResponse() async throws {
        var pages: [Int: BighelpJSONValue] = [:]
        let pageCount = DirectHermesWire.maximumMessageBytes / (4_000 * 100) + 2
        for pageIndex in 0..<pageCount {
            let offset = pageIndex * 100
            let rows = (offset..<(offset + 100)).map { id in
                BighelpJSONValue.object(["id": .integer(id + 1), "role": .string("assistant"),
                    "content": .string(String(repeating: "x", count: 4_000)), "display_metadata": .null])
            }
            pages[offset] = page(rows, offset: offset)
        }
        pages[pageCount * 100] = page([], offset: pageCount * 100)
        let sizes = try pages.values.map { try JSONEncoder().encode($0).count }
        #expect(sizes.reduce(0, +) > DirectHermesWire.maximumMessageBytes)
        #expect(sizes.allSatisfy { $0 < DirectHermesReactionHistoryLoader.maximumPageResponseBytes })
        let http = ReactionHistoryHTTP(pages: pages)
        let result = try await load(http)
        #expect(result?.reactionsByRowID.isEmpty == true)
        #expect(http.requests.count == pageCount + 1)
        #expect(http.requests.allSatisfy { $0.maximumResponseBytes == 512 * 1_024 })
    }

    @Test func foreignProfileOrOwnerLossCannotPublish() async throws {
        let wrong = ReactionHistoryHTTP(pages: [0: page([], offset: 0, profile: "other")])
        await #expect(throws: (any Error).self) { _ = try await load(wrong) }
        let stale = ReactionHistoryHTTP(pages: [0: page([], offset: 0)])
        var owns = true
        stale.onRequest = { owns = false }
        await #expect(throws: (any Error).self) {
            _ = try await DirectHermesReactionHistoryLoader.load(http: stale, storedSessionID: "stored", profileID: "default", remainsOwned: { owns })
        }
    }

    @Test func productionLeaseForwardsHTTPWithOwnerFencing() async throws {
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "fixture", userID: "fixture"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        var current: WorkspaceOwner? = owner
        let base = ReactionHistoryHTTP(pages: [0: page([], offset: 0)])
        let lease = try DirectHermesOwnedRPC(base: base, owner: owner, currentOwner: { current })
        let snapshot = try await DirectHermesReactionHistoryLoader.load(http: lease, storedSessionID: "stored", profileID: "default", remainsOwned: { true })
        #expect(snapshot?.reactionsByRowID.isEmpty == true)
        base.onRequest = { current = nil }
        await #expect(throws: (any Error).self) {
            _ = try await DirectHermesReactionHistoryLoader.load(http: lease, storedSessionID: "stored", profileID: "default", remainsOwned: { true })
        }
        await lease.disconnect()
        #expect(base.disconnectCount == 0)
    }

    private func load(_ http: ReactionHistoryHTTP) async throws -> DirectHermesDurableReactionSnapshot? {
        try await DirectHermesReactionHistoryLoader.load(http: http, storedSessionID: "stored", profileID: "default", remainsOwned: { true })
    }
    private func row(_ id: Int, metadata: BighelpJSONValue) -> BighelpJSONValue {
        .object(["id": .integer(id), "role": .string("assistant"), "display_metadata": metadata])
    }
    private func page(_ rows: [BighelpJSONValue], offset: Int, profile: String = "default") -> BighelpJSONValue {
        .object(["session_id": .string("stored"), "profile": .string(profile), "messages": .array(rows),
            "pagination": .object(["limit": .integer(100), "offset": .integer(offset), "order": .string("oldest"), "returned": .integer(rows.count)])])
    }
}

@MainActor
private final class ReactionHistoryHTTP: DirectHermesAuthenticatedHTTP, DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var disconnectCount = 0
    let pages: [Int: BighelpJSONValue]
    var requests: [DirectHermesHTTPRequest] = []
    var onRequest: (() -> Void)?
    init(pages: [Int: BighelpJSONValue]) { self.pages = pages }
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw DirectHermesError.invalidResponse
    }
    func disconnect() async { disconnectCount += 1 }
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        requests.append(request)
        onRequest?()
        let offset = Int(request.query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        return try #require(pages[offset])
    }
}
