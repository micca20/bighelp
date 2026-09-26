import Foundation
import Testing
@testable import Loopdy

@MainActor
struct NativeHistoryCoverageTests {
    @Test func conflictingStoredVariantsReplaceTheLiveOverlayWithoutDroppingAnyRecordedVariant() throws {
        func row(_ id: Int, _ role: String, _ text: String) -> [String: LoopdyJSONValue] {
            ["id": .integer(id), "session_id": .string("stored"), "role": .string(role), "content": .string(text)]
        }
        var request = row(2, "assistant", "")
        request["tool_calls"] = .array(["{\"command\":\"printf OK\"}", "{}"].map { arguments in
            .object(["id": .string("repeated-call"), "type": .string("function"),
                     "function": .object(["name": .string("terminal"), "arguments": .string(arguments)])])
        })
        var success = row(3, "tool", "{\"output\":\"OK\",\"exit_code\":0}")
        success["tool_call_id"] = .string("repeated-call")
        success["tool_name"] = .string("terminal")
        var failure = row(4, "tool", "{\"error\":\"Invalid command\",\"exit_code\":-1}")
        failure["tool_call_id"] = .string("repeated-call")
        failure["tool_name"] = .string("terminal")
        let rows = try [row(1, "user", "Check"), request, success, failure, row(5, "assistant", "OK")]
            .map { try DirectHermesHistoryRow(.object($0), sessionID: "stored") }
        let projection = try DirectHermesHistoryProjection(rows: rows, appID: "chat", profileID: "default", source: "tui", sourceOrderBase: -5)
        let canonical = projection.activityEvents(sessionID: "chat")
        #expect(canonical.count == 4)
        #expect(canonical.allSatisfy { $0.toolCallID == nil })
        let live = ChatActivityEvent(eventID: "live-call", sessionID: "chat", turnID: "live-turn", kind: .tool,
            lifecycle: .succeeded, title: "terminal", summary: nil, detail: nil, occurredAt: 1, toolCallID: "repeated-call")
        var source = SessionRecord(id: "chat", kind: .direct, agentIDs: ["default"], title: "Chat",
            remoteStoredID: "stored", remoteSource: "tui", activityEvents: [live])
        let client = NativeHistoryCoverageFixture(ids: Set(projection.tools.compactMap(\.toolCallID)))
        let catalog = SessionCatalogStore(client: client, records: [source])
        let original = source
        source.items = projection.messages
        source.activityEvents = canonical
        let restored = try catalog.installSessionStateSnapshot(.init(record: source, nextOffset: nil), source: original)
        #expect(restored.activityEvents == canonical)
        #expect(!restored.activityEvents.contains { $0.eventID == live.eventID })
        #expect(projection.rows.count == 5)
        #expect(restored.activityEvents.compactMap(\.result).contains("{\"error\":\"Invalid command\",\"exit_code\":-1}"))
        let repeated = try catalog.installSessionStateSnapshot(.init(record: source, nextOffset: nil), source: restored)
        #expect(repeated.activityEvents == canonical)
    }
}

@MainActor
private final class NativeHistoryCoverageFixture: SessionCatalogClient {
    let ids: Set<String>
    init(ids: Set<String>) { self.ids = ids }
    var canDeleteConversation: Bool { false }
    func list() async throws -> [SessionRecord] { [] }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord { throw CancellationError() }
    func delete(_ record: SessionRecord) async throws {}
    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String> { ids }
}
