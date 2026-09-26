import Foundation
import Testing
@testable import Loopdy

@MainActor
struct PluginUpdateWorkspaceClientTests {
    @Test func updateOperationsRequireNegotiatedHostSupport() throws {
        for raw in ["plugin_update.start", "plugin_update.status"] {
            let operation = try #require(LoopdyLinkWorkspaceOperation(rawValue: raw))
            #expect(operation.requiresHostCapability)
        }
    }

    @Test func startSendsOnlyOperationIdentityAndExplicitRestartConsent() async throws {
        let messaging = UpdateWorkspaceFixture()
        let client = LoopdyPluginUpdateClient(workspace: LoopdyLinkWorkspaceClient(messaging: messaging))
        let result = try await client.start(operationID: "update_0123456789abcdef")
        #expect(result.phase == .accepted)
        #expect(messaging.requests.count == 1)
        #expect(messaging.requests.first?.operation.rawValue == "plugin_update.start")
        #expect(messaging.requests.first?.payload == ["operation_id": .string("update_0123456789abcdef"), "confirm_restart": .boolean(true)])
    }

    @Test func malformedCompleteResponseIsRejected() throws {
        #expect(throws: (any Error).self) {
            try PluginUpdateStatus.decode([
                "operation_id": .string("update_0123456789abcdef"), "phase": .string("complete"),
                "target_revision": .string(String(repeating: "a", count: 40)),
                "active_revision": .string(String(repeating: "b", count: 40)),
                "runtime_id": .string("runtime_fresh"), "message": .string("Complete"),
            ])
        }
    }
}

@MainActor
private final class UpdateWorkspaceFixture: LoopdyLinkWorkspaceMessaging {
    var requests: [LoopdyLinkWorkspaceRequest] = []
    func performWorkspaceRequest(_ request: LoopdyLinkWorkspaceRequest) async throws -> LoopdyLinkWorkspaceResult {
        requests.append(request)
        let object: [String: Any] = [
            "version": 1, "type": "workspace.result", "requestId": request.requestID,
            "operation": request.operation.rawValue, "status": "completed", "sentAt": 1_788_000_001,
            "payload": ["operation_id": "update_0123456789abcdef", "phase": "accepted", "message": "Updating"],
        ]
        return try JSONDecoder().decode(LoopdyLinkWorkspaceResult.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
