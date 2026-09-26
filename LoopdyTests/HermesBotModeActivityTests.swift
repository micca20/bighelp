import Foundation
import Testing
@testable import Loopdy

@MainActor
struct HermesBotModeActivityTests {
    @Test func clientUsesFixedRoutesAndDoesNotMistakeSourceSequenceGapsForLoss() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "activity-owner"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        var operations: [HermesBotModeActivityOperation] = []
        let client = NativeHermesBotModeActivityClient(owner: owner, currentOwner: { owner }) { operation, payload in
            operations.append(operation)
            #expect(payload["roomId"] == .string("room"))
            switch operation {
            case .open: return Self.page()
            case .poll:
                #expect(payload["after"] == .integer(0))
                return Self.page(events: [
                    Self.event(sequence: 1, sourceSequence: 2),
                    Self.event(sequence: 2, sourceSequence: 90, kind: "tool.completed"),
                ])
            case .close:
                return ["schemaVersion": .integer(1), "roomId": .string("room"),
                        "streamId": .string("stream"), "closed": .boolean(true)]
            }
        }
        let opened = try await client.open(roomID: "room")
        let page = try await client.poll(roomID: "room", streamID: opened.streamId, after: 0, limit: 8)
        #expect(page.upstreamLoss == "unobservable")
        #expect(page.droppedTotal == 0)
        #expect(page.events.last?.kind == .completed)
        #expect(page.events.last?.result.state == .unavailable)
        try await client.close(roomID: "room", streamID: page.streamId)
        #expect(operations == [.open, .poll, .close])
        #expect(HermesBotModeActivityOperation.poll.path == "/api/plugins/loopdy/native/groups/activity/poll")
    }

    @Test func activityDecoderRejectsUnknownFieldsAndMismatchedCoordinates() throws {
        var wrongRoom = Self.page(events: [Self.event(sequence: 1)])
        wrongRoom["roomId"] = .string("other")
        var extra = Self.page(events: [Self.event(sequence: 1)])
        extra["success"] = .boolean(true)
        let gap = Self.page(events: [Self.event(sequence: 2)])
        var detail = try #require(Self.event(sequence: 1).object)
        detail["arguments"] = .object(["state": .string("omitted_sensitive"), "text": .string("must not arrive")])
        for value in [wrongRoom, extra, gap, Self.page(events: [.object(detail)])] {
            #expect(throws: WorkspaceClientError.invalidResponse) {
                try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream", after: 0, limit: 8)
            }
        }
    }

    @Test func authenticatedOwnerChangeRejectsLateActivityResponse() async throws {
        let original = WorkspaceOwner(authority: try .fixture(id: "activity-owner"),
                                      authenticationGeneration: UUID(), connectionGeneration: UUID())
        let box = ActivityOwnerBox(owner: original)
        let client = NativeHermesBotModeActivityClient(owner: original, currentOwner: { box.owner }) { _, _ in
            box.owner = nil
            return Self.page()
        }
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await client.open(roomID: "room")
        }
    }

    @Test func transientStoreClearsRowsAndModelOwnedDisclosureOnReset() async throws {
        let opened = try NativeHermesBotModeActivityClient.decodePage(Self.page(), roomID: "room", streamID: nil, after: 0, limit: 8)
        let first = try NativeHermesBotModeActivityClient.decodePage(
            Self.page(events: [Self.event(sequence: 1)]), roomID: "room", streamID: "stream", after: 0, limit: 8
        )
        let client = ActivityTestClient(opened: opened, pages: [first])
        let store = BotModeActivityStore()
        store.configure(client)
        let viewer = UUID()
        store.begin(roomID: "room", viewerID: viewer, memberIDs: ["member"],
                    isRetired: { _ in false }, reconcile: {})
        for _ in 0..<100 where store.snapshots["room"]?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = try #require(store.snapshots["room"]?.tools.first?.id)
        store.toggleTool(id)
        #expect(store.expandedToolIDs.contains(id))
        store.configure(nil)
        #expect(store.snapshots.isEmpty)
        #expect(store.expandedToolIDs.isEmpty)
        for _ in 0..<100 where client.closed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.closed == ["stream"])
    }

    @Test func bufferResetClearsOnlyTransientRowsAndRequestsCanonicalReconciliation() async throws {
        let opened = try NativeHermesBotModeActivityClient.decodePage(Self.page(), roomID: "room", streamID: nil, after: 0, limit: 8)
        let first = try NativeHermesBotModeActivityClient.decodePage(
            Self.page(events: [Self.event(sequence: 1)]), roomID: "room", streamID: "stream", after: 0, limit: 8
        )
        var value = Self.page()
        value["cursor"] = .integer(3)
        value["highWater"] = .integer(3)
        value["resetRequired"] = .boolean(true)
        value["resetReason"] = .string("buffer_loss")
        value["droppedTotal"] = .integer(2)
        let reset = try NativeHermesBotModeActivityClient.decodePage(value, roomID: "room", streamID: "stream", after: 1, limit: 8)
        let client = ActivityTestClient(opened: opened, pages: [first, reset])
        let store = BotModeActivityStore(pollInterval: .zero)
        store.configure(client)
        var reconciliations = 0
        let viewer = UUID()
        store.begin(roomID: "room", viewerID: viewer, memberIDs: ["member"],
                    isRetired: { _ in false }, reconcile: { reconciliations += 1 })
        for _ in 0..<100 where reconciliations == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reconciliations == 1)
        #expect(store.snapshots["room"]?.tools.isEmpty == true)
        #expect(store.snapshots["room"]?.message.contains("interrupted") == true)
        store.end(roomID: "room", viewerID: viewer)
    }

    static func page(events: [LoopdyJSONValue] = []) -> [String: LoopdyJSONValue] {
        let cursor = events.last?.object?["observationSequence"]?.integer ?? 0
        return [
            "schemaVersion": .integer(1), "runtimeId": .string("runtime"), "roomId": .string("room"),
            "streamId": .string("stream"), "sourceState": .string(events.isEmpty ? "registered_unobserved" : "observed"),
            "upstreamLoss": .string("unobservable"), "openedAt": .integer(1_000),
            "expiresAt": .integer(61_000), "cursor": .integer(cursor), "highWater": .integer(cursor),
            "hasMore": .boolean(false), "resetRequired": .boolean(false), "resetReason": .null,
            "droppedTotal": .integer(0), "projectionDrops": .integer(0), "events": .array(events),
        ]
    }

    static func event(sequence: Int, sourceSequence: Int = 1, kind: String = "tool.started") -> LoopdyJSONValue {
        .object([
            "observationSequence": .integer(sequence), "observedAt": .integer(1_100),
            "roomId": .string("room"), "memberId": .string("member"), "threadId": .string("thread"),
            "turnId": .string("turn"), "taskId": .string("task"), "executionGeneration": .integer(1),
            "sourceSequence": .integer(sourceSequence), "kind": .string(kind),
            "tool": .object(["id": .string("tool-1"), "name": .string("calendar"), "durationMs": .null]),
            "arguments": .object(["state": .string("unavailable"), "text": .null]),
            "result": .object(["state": .string("unavailable"), "text": .null]),
        ])
    }
}

@MainActor
private final class ActivityOwnerBox {
    var owner: WorkspaceOwner?
    init(owner: WorkspaceOwner) { self.owner = owner }
}

@MainActor
private final class ActivityTestClient: HermesBotModeActivityClient {
    let opened: HermesBotModeActivityPage
    var pages: [HermesBotModeActivityPage]
    var closed: [String] = []
    init(opened: HermesBotModeActivityPage, pages: [HermesBotModeActivityPage]) {
        self.opened = opened
        self.pages = pages
    }
    func open(roomID: String) async throws -> HermesBotModeActivityPage { opened }
    func poll(roomID: String, streamID: String, after: Int, limit: Int) async throws -> HermesBotModeActivityPage {
        if !pages.isEmpty { return pages.removeFirst() }
        try await Task.sleep(for: .seconds(60))
        throw WorkspaceClientError.transportUnavailable
    }
    func close(roomID: String, streamID: String) async throws { closed.append(streamID) }
}
