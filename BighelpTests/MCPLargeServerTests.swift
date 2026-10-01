import Foundation
import Testing
@testable import Bighelp

/// A cloud provider's full API MCP server offers thousands of tools (Hermes keeps an
/// include list). After signing in, the screen read every tool and stopped at
/// 512 with "exceeded this screen's safe display limit", though sign-in worked.
@MainActor
struct MCPLargeServerTests {
    @Test func aServerWithThousandsOfToolsStillTests() async throws {
        let host = MCPHost()
        let result = try await makeClient(host).test(serverName: "big-api")
        #expect(result.succeeded)
        #expect(result.toolCount == 2_600)
        #expect(result.tools.count == MCPProbeResult.displayedToolLimit)
        #expect(result.tools[0].summary.count <= MCPProbeResult.summaryCharacterLimit + 1, "Long descriptions are shortened, not refused")
        let test = try #require(host.requests.first)
        #expect(test.maximumResponseBytes > 4 * 1_024 * 1_024)
        #expect(test.maximumResponseBytes <= DirectHermesHTTP.responseLimit(route: test.path, method: "POST", query: test.query))
    }

    @Test func anApprovedSignInWithThousandsOfToolsIsApproved() async throws {
        let host = MCPHost()
        let flow = try await makeClient(host).pollOAuth(flowID: "flow-1")
        #expect(flow.status == .approved)
        #expect(flow.tools.count == MCPProbeResult.displayedToolLimit)
        let poll = try #require(host.requests.first)
        #expect(poll.maximumResponseBytes <= DirectHermesHTTP.responseLimit(route: poll.path, method: "GET", query: poll.query))
    }

    private func makeClient(_ host: MCPHost) throws -> DirectHermesMCPClient {
        let owner = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        return DirectHermesMCPClient(http: host, rpc: nil, owner: owner, profileID: "default", currentOwner: { owner })
    }
}

@MainActor
private final class MCPHost: DirectHermesAuthenticatedHTTP {
    private(set) var requests: [DirectHermesHTTPRequest] = []

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        requests.append(request)
        let tools = BighelpJSONValue.array((0..<2_600).map { index in
            .object(["name": .string("get_accounts_item_\(index)"),
                     "description": .string(String(repeating: "Lists account items. ", count: index == 0 ? 600 : 3))])
        })
        switch request.path {
        case "/api/mcp/servers/big-api/test":
            return .object(["ok": .boolean(true), "tools": tools, "prompts": .integer(0), "resources": .integer(0)])
        case "/api/mcp/oauth/flows/flow-1":
            return .object(["status": .string("approved"), "flow_id": .string("flow-1"),
                            "server_name": .string("big-api"), "tools": tools])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }
}
