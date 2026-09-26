import Foundation
import Testing
@testable import Bighelp

@MainActor
@Suite(.serialized)
struct NativeHermesGroupFlowTests {
    @Test
    func directGroupsCatalogOpenAndHistoryUseStockRPCWithoutRepeatedNegotiation() async throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://groups.example")
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let transport = NativeHermesGroupRPCStub(capabilityGatewayID: "gateway-2")
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport,
            http: transport,
            owner: owner,
            capabilities: WorkspaceCapabilities(owner: owner),
            currentOwner: { owner }
        )
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false,
            nativeClient: client
        )

        await store.refreshNativeRoomCatalog()
        #expect(store.catalogRooms.map(\.roomID) == ["research-circle"])
        #expect(store.catalogRooms.first?.canRename == false)

        let room = try await store.openNativeRoom(roomID: "research-circle")
        #expect(room.hasNativeRoom)
        #expect(room.title == "Research circle")
        #expect(room.profileIDs == ["finance", "research"])
        #expect(room.visibleEvents.contains { $0.text == "Recovered from Hermes" })
        #expect(transport.rpcMethods == [
            "groups.capabilities", "groups.list", "groups.state", "groups.log",
        ])
    }

    @Test
    func directGroupSendUsesCanonicalEventAndReplaysSettledHistory() async throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://groups.example")
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let transport = NativeHermesGroupRPCStub()
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport,
            http: transport,
            owner: owner,
            capabilities: WorkspaceCapabilities(owner: owner),
            currentOwner: { owner }
        )
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false,
            nativeClient: client
        )

        _ = try await store.openNativeRoom(roomID: "research-circle")
        try await store.send(text: "Hello Hermes", roomID: "research-circle")

        #expect(transport.sentPayload == [
            "text": .string("Hello Hermes"),
            "thread_id": .string("loopdy-research-circle"),
        ])
        #expect(store.room(id: "research-circle")?.nativePendingEventID == nil)
        #expect(store.room(id: "research-circle")?.isRunning == false)
        #expect(store.room(id: "research-circle")?.nativeLogCursor == 3)
        #expect(store.room(id: "research-circle")?.visibleEvents.contains { $0.text == "Native answer" } == true)
        #expect(transport.rpcMethods.filter { $0 == "groups.state" }.count == 3)
        #expect(transport.rpcMethods.filter { $0 == "groups.log" }.count == 3)
        #expect(transport.rpcMethods.contains("groups.send"))
    }

    @Test
    func directGroupClientRejectsResultsAfterWorkspaceOwnerChanges() async throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://groups.example")
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        var currentOwner: WorkspaceOwner? = owner
        let transport = NativeHermesGroupRPCStub()
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport,
            http: transport,
            owner: owner,
            capabilities: WorkspaceCapabilities(owner: owner),
            currentOwner: { currentOwner }
        )
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)

        currentOwner = nil
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await client.groupsCapabilities()
        }
        #expect(transport.rpcMethods.isEmpty)
    }

    @Test
    func nativeRoomCatalogRemainsVisibleButCannotOpenAcrossOwnerBoundary() async throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://groups.example")
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let transport = NativeHermesGroupRPCStub()
        let workspace = DirectHermesWorkspaceClient(
            rpc: transport,
            http: transport,
            owner: owner,
            capabilities: WorkspaceCapabilities(owner: owner),
            currentOwner: { owner }
        )
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false,
            nativeClient: client
        )

        await store.refreshNativeRoomCatalog()
        store.configureNativeClient(nil, preservingCatalog: true)
        #expect(store.catalogRooms.map(\.roomID) == ["research-circle"])
        #expect(store.isCatalogStale)
        await #expect(throws: BotModeRoomError.executionUnavailable) {
            _ = try await store.openNativeRoom(roomID: "research-circle")
        }
    }
}

@MainActor
private final class NativeHermesGroupRPCStub: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?
    private(set) var rpcMethods: [String] = []
    private(set) var sentPayload: [String: BighelpJSONValue]?
    private var sentDiscussionEventID: String?

    private let capabilityGatewayID: String

    init(capabilityGatewayID: String = "gateway-1") {
        self.capabilityGatewayID = capabilityGatewayID
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        rpcMethods.append(method)
        switch method {
        case "groups.capabilities":
            return Self.capabilities(gatewayID: capabilityGatewayID)
        case "groups.list":
            return .object(["rooms": .array([Self.room]), "next_offset": .null])
        case "groups.state":
            return .object(["room": Self.room])
        case "groups.log":
            let since = params["since_seq"]?.integer ?? 0
            if since == 1, sentPayload != nil {
                return .object([
                    "events": .array([
                        Self.memberEvent(discussionEventID: sentDiscussionEventID ?? "discussion-client-event"),
                        Self.settledEvent(discussionEventID: sentDiscussionEventID ?? "discussion-client-event"),
                    ]),
                    "cursor": .integer(3),
                    "latest_seq": .integer(3),
                    "has_more": .boolean(false),
                    "authority": .object([
                        "gateway_id": .string("gateway-1"),
                        "epoch": .integer(1),
                    ]),
                ])
            }
            if since == 1 {
                return .object([
                    "events": .array([]),
                    "cursor": .integer(1),
                    "latest_seq": .integer(1),
                    "has_more": .boolean(false),
                    "authority": .object([
                        "gateway_id": .string("gateway-1"),
                        "epoch": .integer(1),
                    ]),
                ])
            }
            return .object([
                "events": .array([Self.event]),
                "cursor": .integer(1),
                "latest_seq": .integer(1),
                "has_more": .boolean(false),
                "authority": .object([
                    "gateway_id": .string("gateway-1"),
                    "epoch": .integer(1),
                ]),
            ])
        case "groups.send":
            sentPayload = params["payload"]?.object
            let payload = sentPayload ?? [:]
            let eventID = params["event_id"]?.string ?? "client-event"
            sentDiscussionEventID = "discussion-\(eventID)"
            let threadID = payload["thread_id"]?.string ?? "loopdy-research-circle"
            let text = payload["text"]?.string ?? ""
            return .object([
                "event": .object([
                    "room_id": .string("research-circle"),
                    "seq": .integer(2),
                    "event_id": .string("discussion-\(eventID)"),
                    "kind": .string("message.user"),
                    "actor": .object([
                        "kind": .string("user"),
                        "id": .string("desktop"),
                    ]),
                    "authority_epoch": .integer(1),
                    "payload": .object([
                        "text": .string(text),
                        "thread_id": .string(threadID),
                    ]),
                    "created_at": .number(1_788_000_003),
                ]),
                "client_event_id": .string(eventID),
                "accepted": .boolean(true),
                "driver_started": .boolean(true),
            ])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        throw DirectHermesError.invalidResponse
    }

    func disconnect() async {}

    private static func capabilities(gatewayID: String) -> BighelpJSONValue {
        .object([
        "protocol_version": .integer(2),
        "driver": .boolean(true),
        "persistent_process": .boolean(true),
        "authority_gateway_id": .string(gatewayID),
        "room_link": .object(["enabled": .boolean(false)]),
        "features": .array(
            HermesBotModeCapabilities.requiredFeatures.map(BighelpJSONValue.string)
        ),
        "methods": .array(
            (HermesBotModeCapabilities.requiredOperations + ["groups.list", "groups.rename"])
                .map(BighelpJSONValue.string)
        ),
        "max_log_limit": .integer(500),
        ])
    }

    private static let room: BighelpJSONValue = .object([
        "room_id": .string("research-circle"),
        "name": .string("Research circle"),
        "members": .array([
            .object([
                "member_id": .string("member-finance"),
                "profile": .string("finance"),
                "handle": .string("finance"),
                "display_name": .string("Finance"),
                "target": .object([
                    "kind": .string("local"),
                    "profile": .string("finance"),
                ]),
            ]),
            .object([
                "member_id": .string("member-research"),
                "profile": .string("research"),
                "handle": .string("research"),
                "display_name": .string("Research"),
                "target": .object([
                    "kind": .string("local"),
                    "profile": .string("research"),
                ]),
            ]),
        ]),
        "authority_gateway_id": .string("gateway-1"),
        "authority_epoch": .integer(1),
        "revision": .integer(1),
        "created_at": .number(1_788_000_000),
        "updated_at": .number(1_788_000_001),
        "latest_seq": .integer(1),
        "disbanded_at": .null,
    ])

    private static let event: BighelpJSONValue = .object([
        "room_id": .string("research-circle"),
        "seq": .integer(1),
        "event_id": .string("history-1"),
        "kind": .string("message.user"),
        "actor": .object([
            "kind": .string("user"),
            "id": .string("desktop"),
        ]),
        "authority_epoch": .integer(1),
        "payload": .object([
            "text": .string("Recovered from Hermes"),
            "thread_id": .string("loopdy-research-circle"),
        ]),
        "created_at": .number(1_788_000_002),
    ])

    private static func memberEvent(discussionEventID: String) -> BighelpJSONValue {
        .object([
        "room_id": .string("research-circle"),
        "seq": .integer(2),
        "event_id": .string("member-answer"),
        "kind": .string("message.member"),
        "actor": .object([
            "kind": .string("member"),
            "id": .string("member-finance"),
        ]),
        "authority_epoch": .integer(1),
        "payload": .object([
            "member_id": .string("member-finance"),
            "text": .string("Native answer"),
            "discussion_event_id": .string(discussionEventID),
            "thread_id": .string("loopdy-research-circle"),
        ]),
        "created_at": .number(1_788_000_004),
        ])
    }

    private static func settledEvent(discussionEventID: String) -> BighelpJSONValue {
        .object([
        "room_id": .string("research-circle"),
        "seq": .integer(3),
        "event_id": .string("activity-settled"),
        "kind": .string("room.activity"),
        "actor": .object([
            "kind": .string("gateway"),
            "id": .string("gateway-1"),
        ]),
        "authority_epoch": .integer(1),
        "payload": .object([
            "discussion_event_id": .string(discussionEventID),
            "thread_id": .string("loopdy-research-circle"),
            "status": .string("settled"),
        ]),
        "created_at": .number(1_788_000_005),
        ])
    }
}
