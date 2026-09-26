import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesFormClientTests {
    @Test func directFormUsesExistingRouteAndOriginalCorrelation() async throws {
        let fixture = try Fixture()
        let request = try submission()
        fixture.transport.responses = [.success(response(request))]
        let result = try await fixture.client.submit(request)
        #expect(result.requestID == request.requestID)
        #expect(fixture.transport.calls.count == 1)
        let sent = try #require(fixture.transport.calls.first)
        #expect(sent.method == .post)
        #expect(sent.path == "/api/plugins/loopdy/generative-ui/v2/forms/\(request.requestID)/submit")
        #expect(sent.body?["idempotency_key"] == .string(request.idempotencyKey.uuidString.lowercased()))
        #expect(sent.body?["values"] == .object(request.values))
    }

    @Test func unknownPostReconcilesWithOneReadAndNeverResubmits() async throws {
        let fixture = try Fixture()
        let request = try submission()
        fixture.transport.responses = [.failure(.outcomeUnknown), .success(response(request))]
        _ = try await fixture.client.submit(request)
        #expect(fixture.transport.calls.map(\.method) == [.post, .get])
        #expect(fixture.transport.calls.last?.path.hasSuffix("/status") == true)
    }

    @Test func pendingReadbackKeepsUnknownOutcomeWithoutMutationRetry() async throws {
        let fixture = try Fixture()
        let request = try submission()
        fixture.transport.responses = [.failure(.outcomeUnknown), .success(response(request, state: "pending"))]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) { try await fixture.client.submit(request) }
        #expect(fixture.transport.calls.map(\.method) == [.post, .get])
    }

    private func submission() throws -> BighelpLinkGenerativeUIFormSubmission {
        try .init(requestID: String(repeating: "a", count: 32), sessionID: "session_form_fixture", profile: "default",
                  values: ["answer": .string("Keep this exact response")], submittedAt: 1_800_000_000)
    }

    private func response(_ request: BighelpLinkGenerativeUIFormSubmission, state: String = "success") -> BighelpJSONValue {
        .object(["schema": .string("loopdy.generative_ui.action_response"), "version": .integer(2),
                 "request_id": .string(request.requestID), "idempotency_key": .string(request.idempotencyKey.uuidString.lowercased()),
                 "state": .string(state), "code": .string("accepted"), "message": .string("Response accepted")])
    }

    @MainActor private final class Fixture {
        let transport = Transport()
        let client: DirectHermesFormClient
        init() throws {
            let owner = WorkspaceOwner(authority: try .dashboard(endpointIdentity: "https://fixture.invalid"),
                                       authenticationGeneration: UUID(), connectionGeneration: UUID())
            let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                capabilities: .init(owner: owner), currentOwner: { owner })
            client = DirectHermesFormClient(workspace: workspace, owner: owner)
        }
    }

    @MainActor private final class Transport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
        var onEvent: ((DirectHermesEvent) -> Void)?
        var calls: [DirectHermesHTTPRequest] = []
        var responses: [Result<BighelpJSONValue, WorkspaceClientError>] = []
        func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
            calls.append(request)
            guard !responses.isEmpty else { throw WorkspaceClientError.invalidResponse }
            return try responses.removeFirst().get()
        }
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw WorkspaceClientError.invalidRequest
        }
        func disconnect() async {}
    }
}
