import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentMediaTests {
    @Test func mediaLoadsNewestFirstAndSaysWhenTheHostCannotShareIt() async {
        let client = FixtureMediaClient()
        client.items = [
            AgentMediaItem(id: "a1", fileName: "clip.mp4", mimeType: "video/mp4", byteCount: 10, createdAt: nil),
            AgentMediaItem(id: "a2", fileName: "chart.png", mimeType: "image/png", byteCount: 10, createdAt: nil),
        ]
        let store = AgentMediaStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.state == .loaded)
        #expect(store.items.map(\.fileName) == ["clip.mp4", "chart.png"])

        client.error = WorkspaceClientError.unavailable(.unsupportedOperation)
        await store.load(agentID: "default")
        #expect(store.state == .unavailable)

        store.configure(client: nil)
        #expect(store.items.isEmpty)
        #expect(store.state == .unavailable)
    }

    @Test func switchingAgentsClearsTheOldAgentsMedia() async {
        let client = FixtureMediaClient()
        client.items = [AgentMediaItem(id: "a1", fileName: "a.png", mimeType: "image/png", byteCount: 10, createdAt: nil)]
        let store = AgentMediaStore()
        store.configure(client: client)
        await store.load(agentID: "juno")
        client.items = []
        await store.load(agentID: "juniper")
        #expect(store.items.isEmpty)
        #expect(client.requestedAgents == ["juno", "juniper"])
    }
}

@MainActor
private final class FixtureMediaClient: AgentMediaClient {
    var items: [AgentMediaItem] = []
    var error: Error?
    var requestedAgents: [String] = []

    func recent(agentID: String) async throws -> [AgentMediaItem] {
        requestedAgents.append(agentID)
        if let error { throw error }
        return items
    }

    func data(agentID: String, item: AgentMediaItem) async throws -> Data { Data() }
}
