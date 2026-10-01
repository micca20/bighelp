import Foundation
import Testing
@testable import Bighelp

/// Deleting an agent should be smooth: Hermes can take longer than the usual
/// wait, and an answer lost on the way back mustn't read as a failed delete.
@MainActor
struct ProfileDeletionTests {
    @Test func deleteWaitsForHermesToStopTheAgent() async throws {
        let host = ProfileHost(deleteOutcome: .deletes)
        let client = try makeClient(host)
        let review = try await client.prepareDelete(profileID: "sage")
        let result = try await client.delete(reviewed: review) { _ in }
        #expect(result.change == .deleted(profileID: "sage"))
        let delete = try #require(host.requests.first { $0.method == .delete })
        #expect(delete.path == "/api/profiles/sage")
        #expect(delete.timeout >= 60, "Hermes may spend 10 s stopping the gateway before it removes anything")
    }

    /// The wait ran out (or the connection dropped) but Hermes finished: done.
    @Test func aLostAnswerStillCountsWhenTheAgentIsGone() async throws {
        let host = ProfileHost(deleteOutcome: .deletesButAnswerIsLost)
        let client = try makeClient(host)
        let review = try await client.prepareDelete(profileID: "sage")
        let result = try await client.delete(reviewed: review) { _ in }
        #expect(result.change == .deleted(profileID: "sage"))
        #expect(!result.catalog.profiles.contains { $0.id == "sage" })
    }

    /// Nothing happened on the host: still an error, and nothing claims success.
    @Test func aFailedDeleteStaysAnErrorWhileTheAgentExists() async throws {
        let host = ProfileHost(deleteOutcome: .fails)
        let client = try makeClient(host)
        let review = try await client.prepareDelete(profileID: "sage")
        await #expect(throws: HermesProfileLifecycleError.outcomeUnknown) {
            _ = try await client.delete(reviewed: review) { _ in }
        }
    }

    /// Deleting an agent deletes its chats, so their drafts on this device go
    /// too; other agents' and other computers' drafts stay.
    @Test func deletingAnAgentRemovesOnlyItsDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DirectHermesDraftStore(root: root)
        func save(_ scope: String, host: String, profile: String) throws {
            var record = DirectHermesDraftStore.Record()
            record.draft = "unsent"
            record.owner = .init(hostIdentity: host, profile: profile, storedID: scope, title: "Chat")
            try store.save(record, scope: scope)
        }
        try save("a", host: "home", profile: "sage")
        try save("b", host: "home", profile: "sage")
        try save("c", host: "home", profile: "nova")
        try save("d", host: "office", profile: "sage")

        try store.removeRecords(hostIdentity: "home", profile: "sage")

        #expect(try store.recoveryRecords(hostIdentity: "home", profile: "sage").isEmpty)
        #expect(try store.recoveryRecords(hostIdentity: "home", profile: "nova").count == 1)
        #expect(try store.recoveryRecords(hostIdentity: "office", profile: "sage").count == 1)
    }

    private func makeClient(_ host: ProfileHost) throws -> DirectHermesProfileLifecycleClient {
        let owner = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        return DirectHermesProfileLifecycleClient(rpc: NoRPC(), http: host, owner: owner, currentOwner: { owner })
    }
}

@MainActor
private final class ProfileHost: DirectHermesAuthenticatedHTTP {
    enum DeleteOutcome { case deletes, deletesButAnswerIsLost, fails }
    struct TimedOut: Error {}

    let deleteOutcome: DeleteOutcome
    private var profiles = ["default", "sage"]
    private(set) var requests: [DirectHermesHTTPRequest] = []

    init(deleteOutcome: DeleteOutcome) { self.deleteOutcome = deleteOutcome }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        requests.append(request)
        switch (request.method, request.path) {
        case (.get, "/api/profiles"):
            return .object(["profiles": .array(profiles.map(Self.row))])
        case (.get, "/api/profiles/active"):
            return .object(["active": .string("default"), "current": .string("default")])
        case (.delete, "/api/profiles/sage"):
            switch deleteOutcome {
            case .deletes:
                profiles.removeAll { $0 == "sage" }
                return .object(["ok": .boolean(true), "path": .string("/hermes/profiles/sage")])
            case .deletesButAnswerIsLost:
                profiles.removeAll { $0 == "sage" }
                throw TimedOut()
            case .fails:
                throw TimedOut()
            }
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private static func row(_ name: String) -> BighelpJSONValue {
        .object([
            "name": .string(name), "is_default": .boolean(name == "default"), "skill_count": .integer(3),
            "has_env": .boolean(true), "has_alias": .boolean(false), "gateway_running": .boolean(true),
            "description_auto": .boolean(false), "description": .string(""), "display_name": .null,
            "provider": .null, "model": .null,
        ])
    }
}

private final class NoRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw WorkspaceClientError.unavailable(.policyRestricted)
    }
    func disconnect() async {}
}
