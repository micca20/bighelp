import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyLinkHermesBotModeApprovalTests {
    @Test
    func pendingApprovalDecodesKnownActionAndIgnoresRetryAction() throws {
        let approvals = try HermesBotModePendingApproval.decode(
            roomID: "room-1",
            driverStatus: [
                "pending_actions": .array([
                    .object([
                        "kind": .string("retry"),
                        "task_id": .string("retry-task"),
                    ]),
                    .object([
                        "kind": .string("approval"),
                        "member_id": .string("ops"),
                        "task_id": .string("task-1"),
                        "execution_generation": .integer(4),
                        "request_id": .string("approval-1"),
                        "approval": .object([
                            "request_id": .string("approval-1"),
                            "command": .string("pytest -q tests/focused"),
                            "description": .string("Run the focused tests"),
                            "choices": .array([.string("once"), .string("deny")]),
                        ]),
                    ]),
                ]),
            ]
        )

        let approval = try #require(approvals.first)
        #expect(approvals.count == 1)
        #expect(approval.roomID == "room-1")
        #expect(approval.memberID == "ops")
        #expect(approval.taskID == "task-1")
        #expect(approval.executionGeneration == 4)
        #expect(approval.requestID == "approval-1")
        #expect(approval.command == "pytest -q tests/focused")
        #expect(approval.description == "Run the focused tests")
        #expect(approval.choices == [.once, .deny])
        #expect(approval.id == "6:room-13:ops6:task-11:410:approval-1")
        #expect(approval.decisionChoices == [
            HermesBotModeApprovalDecision(requestID: "approval-1", choice: .once),
            HermesBotModeApprovalDecision(requestID: "approval-1", choice: .deny),
        ])
    }

    @Test
    func pendingApprovalTreatsMissingOrNullCommandAsUnavailable() throws {
        let approvals = try HermesBotModePendingApproval.decode(
            roomID: "room-1",
            driverStatus: [
                "pending_actions": .array([
                    .object([
                        "kind": .string("approval"),
                        "member_id": .string("ops"),
                        "task_id": .string("task-missing"),
                        "execution_generation": .integer(4),
                        "request_id": .string("approval-missing"),
                        "approval": .object([
                            "request_id": .string("approval-missing"),
                            "choices": .array([.string("once"), .string("deny")]),
                        ]),
                    ]),
                    .object([
                        "kind": .string("approval"),
                        "member_id": .string("ops"),
                        "task_id": .string("task-null"),
                        "execution_generation": .integer(5),
                        "request_id": .string("approval-null"),
                        "approval": .object([
                            "request_id": .string("approval-null"),
                            "command": .null,
                            "choices": .array([.string("once"), .string("deny")]),
                        ]),
                    ]),
                ]),
            ]
        )

        #expect(approvals.map(\.command) == [nil, nil])
    }

    @Test
    func pendingApprovalRejectsMalformedKnownAction() throws {
        let status: [String: LoopdyJSONValue] = [
            "pending_actions": .array([
                .object([
                    "kind": .string("approval"),
                    "member_id": .string("ops"),
                    "task_id": .string("task-1"),
                    "execution_generation": .integer(4),
                    "request_id": .string("approval-1"),
                    "approval": .object([
                        "request_id": .string("approval-1"),
                        "command": .string("pytest -q tests/focused"),
                        "choices": .array([.string("always")]),
                    ]),
                ]),
            ]),
        ]

        #expect(throws: HermesBotModeApprovalError.invalidPendingAction) {
            _ = try HermesBotModePendingApproval.decode(roomID: "room-1", driverStatus: status)
        }
    }

    @Test
    func groupsApproveSendsExactPayloadAndValidatesReceipt() async throws {
        let owner = LoopdyLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = ApprovalMessagingStub { request in
            #expect(request.operation == .groupsApprove)
            #expect(request.payload == [
                "room_id": .string("room-1"),
                "member_id": .string("ops"),
                "task_id": .string("task-1"),
                "execution_generation": .integer(4),
                "request_id": .string("approval-1"),
                "choice": .string("once"),
            ])
            return try Self.result(for: request, payload: [
                "approved": .boolean(true),
                "result": .object(["resolved": .integer(1)]),
            ])
        }
        let client = LoopdyLinkHermesBotModeClient(
            workspace: LoopdyLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        let receipt = try await client.groupsApprove(
            roomID: "room-1",
            memberID: "ops",
            taskID: "task-1",
            executionGeneration: 4,
            requestID: "approval-1",
            choice: .once
        )

        #expect(receipt == HermesBotModeApprovalReceipt(
            approved: true,
            result: ["resolved": .integer(1)]
        ))
    }

    @Test
    func groupsApproveRejectsUnapprovedReceipt() async throws {
        let owner = LoopdyLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let messaging = ApprovalMessagingStub { request in
            try Self.result(for: request, payload: [
                "approved": .boolean(false),
                "result": .object(["resolved": .integer(0)]),
            ])
        }
        let client = LoopdyLinkHermesBotModeClient(
            workspace: LoopdyLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { owner }
        )

        await #expect(throws: LoopdyLinkWorkspaceClientError.invalidResponse) {
            _ = try await client.groupsApprove(
                roomID: "room-1",
                memberID: "ops",
                taskID: "task-1",
                executionGeneration: 4,
                requestID: "approval-1",
                choice: .deny
            )
        }
    }

    @Test
    func groupsApproveDiscardsResultWhenOwnerChanges() async throws {
        let owner = LoopdyLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-1",
            connectionID: "connection-1"
        )
        let replacementOwner = LoopdyLinkHermesBotModeOwner(
            accountID: "account-1",
            hostID: "host-2",
            connectionID: "connection-2"
        )
        var activeOwner = owner
        let messaging = ApprovalMessagingStub { request in
            activeOwner = replacementOwner
            return try Self.result(for: request, payload: [
                "approved": .boolean(true),
                "result": .object(["resolved": .integer(1)]),
            ])
        }
        let client = LoopdyLinkHermesBotModeClient(
            workspace: LoopdyLinkWorkspaceClient(messaging: messaging),
            owner: owner,
            currentOwner: { activeOwner }
        )

        await #expect(throws: LoopdyLinkHermesBotModeClientError.ownerChanged) {
            _ = try await client.groupsApprove(
                roomID: "room-1",
                memberID: "ops",
                taskID: "task-1",
                executionGeneration: 4,
                requestID: "approval-1",
                choice: .once
            )
        }
    }

    private static func result(
        for request: LoopdyLinkWorkspaceRequest,
        payload: [String: LoopdyJSONValue]
    ) throws -> LoopdyLinkWorkspaceResult {
        let payloadData = try JSONEncoder().encode(LoopdyJSONValue.object(payload))
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        let object: [String: Any] = [
            "version": 1,
            "type": "workspace.result",
            "requestId": request.requestID,
            "operation": request.operation.rawValue,
            "status": "completed",
            "payload": payloadObject,
            "sentAt": 1_788_000_001,
        ]
        return try JSONDecoder().decode(
            LoopdyLinkWorkspaceResult.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

@MainActor
private final class ApprovalMessagingStub: LoopdyLinkWorkspaceMessaging {
    private let handler: (LoopdyLinkWorkspaceRequest) throws -> LoopdyLinkWorkspaceResult

    init(handler: @escaping (LoopdyLinkWorkspaceRequest) throws -> LoopdyLinkWorkspaceResult) {
        self.handler = handler
    }

    func performWorkspaceRequest(
        _ request: LoopdyLinkWorkspaceRequest
    ) async throws -> LoopdyLinkWorkspaceResult {
        try handler(request)
    }
}
