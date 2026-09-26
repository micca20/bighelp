import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesConditionalOwnershipTests {
    @Test func retiredOwnerCannotReadHostLocalModelsOrToolBackends() async throws {
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "fixture", userID: "conditional"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = ConditionalOwnershipTransport()
        let models = DirectHermesLocalModelsClient(rpc: transport, http: transport, owner: owner, currentOwner: { nil })
        let backends = DirectHermesHostToolBackendsClient(rpc: transport, http: transport, owner: owner, currentOwner: { nil })
        await #expect(throws: (any Error).self) { _ = try await models.status() }
        await #expect(throws: (any Error).self) { _ = try await backends.terminalBackends(profileID: "default") }
        await #expect(throws: (any Error).self) { _ = try await backends.computerUseStatus(profileID: "default") }
        #expect(transport.calls == 0)
    }
}

@MainActor
private final class ConditionalOwnershipTransport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
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
