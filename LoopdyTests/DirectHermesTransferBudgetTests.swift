import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesTransferBudgetTests {
    @Test func largerSessionBudgetsDoNotWidenOrdinaryRequests() {
        #expect(DirectHermesHTTP.requestBodyLimit(route: "/api/sessions/import", method: "POST") == 25 * 1_024 * 1_024)
        #expect(DirectHermesHTTP.requestBodyLimit(route: "/api/config", method: "POST") == 1_024 * 1_024)
        #expect(DirectHermesHTTP.requestBodyLimit(route: "/api/sessions/import", method: "PUT") == 1_024 * 1_024)
        #expect(DirectHermesHTTP.responseLimit(route: "/api/sessions/saved/export", method: "GET", query: []) == 25 * 1_024 * 1_024)
        #expect(DirectHermesHTTP.responseLimit(route: "/api/sessions/a/b/export", method: "GET", query: []) == DirectHermesWire.maximumMessageBytes)
        #expect(DirectHermesHTTP.responseLimit(route: "/api/files", method: "GET", query: []) >= DirectHermesManagedFilesClient.maximumListingResponseBytes)
    }

    @Test func sessionImportAboveOldLimitIsPreparedWithoutDispatch() throws {
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "transfer"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = TransferBudgetTransport()
        let client = DirectHermesSessionMaintenanceClient(rpc: transport, http: transport, owner: owner,
            currentOwner: { owner },
            resolveClosableRuntime: { _ in throw DirectHermesError.invalidResponse },
            reconcileClosedRuntime: { _ in throw DirectHermesError.invalidResponse })
        let value: LoopdyJSONValue = .object(["sessions": .array([
            .object(["id": .string("saved"), "messages": .array([
                .object(["role": .string("assistant"), "content": .string(String(repeating: "x", count: 2 * 1_024 * 1_024))])
            ])])
        ])])
        let bytes = try JSONEncoder().encode(value)
        let review = try client.prepareImport(profileID: "default", data: bytes)
        #expect(review.sessionIDs == ["saved"])
        #expect(review.byteCount == bytes.count)
        #expect(transport.calls == 0)
        let tooLarge = Data(repeating: 32, count: 25 * 1_024 * 1_024 + 1)
        #expect(throws: HermesSessionMaintenanceError.self) { try client.prepareImport(profileID: "default", data: tooLarge) }
        #expect(transport.calls == 0)
    }
}

@MainActor
private final class TransferBudgetTransport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var calls = 0
    func request(_ method: String, params: [String: LoopdyJSONValue]) async throws -> LoopdyJSONValue {
        calls += 1
        throw DirectHermesError.invalidResponse
    }
    func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        calls += 1
        throw DirectHermesError.invalidResponse
    }
    func disconnect() async {}
}
