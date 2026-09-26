import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyWidgetSnapshotTests {
    @Test func widgetDeepLinksRouteToTheirDestinations() throws {
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.newChatURL(agentID: "default")) == .newChat(agentID: "default"))
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.newChatURL(agentID: nil)) == .newChat(agentID: nil))
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.tasksURL) == .scheduledTasks)
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.sessionsURL) == .sessions)
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.chatURL("abc_123")) == .chat(sessionID: "abc_123"))
        #expect(LoopdyIncomingURLRoute.parse(LoopdyWidgetSnapshot.taskURL("job_42")) == .scheduledTask(id: "job_42"))
    }

    @Test func externalSessionOpensAreConsumedExactlyOnce() {
        let center = LoopdyExternalSessionOpenCenter()
        center.request(profileID: "default", storedSessionID: "20260923_101500_abc")
        let first = try! #require(center.pending)
        #expect(first.target == .stored(profileID: "default", storedSessionID: "20260923_101500_abc"))
        center.request(catalogSessionID: "session-1")
        #expect(!center.consume(first))
        let second = try! #require(center.pending)
        #expect(center.consume(second))
        #expect(center.pending == nil)
        #expect(!center.consume(second))
    }

    @Test func snapshotRoundTripsAndOrdersRunningSessionsFirst() throws {
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = LoopdyWidgetSnapshot(defaultAgentID: "default", defaultAgentName: "Juno", sessions: [
            .init(id: "idle-new", title: "Idle", agentName: "Juno", status: "Replied", preview: "Done",
                  isRunning: false, updatedAt: old.addingTimeInterval(600)),
            .init(id: "running-old", title: "Running", agentName: "Juno", status: "Working", preview: nil,
                  isRunning: true, updatedAt: old),
        ], tasks: [], generatedAt: old)
        let data = try JSONEncoder.loopdyWidget.encode(snapshot)
        let decoded = try JSONDecoder.loopdyWidget.decode(LoopdyWidgetSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.feedSessions.map(\.id) == ["running-old", "idle-new"])
        #expect(decoded.runningSessions.map(\.id) == ["running-old"])
    }

    @Test func retiringThePublisherClearsTheHomeScreen() async throws {
        var writes: [LoopdyWidgetSnapshot] = []
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [])
        let tasks = ScheduledTasksStore(client: ScheduledTasksFixtureClient(), initialAgentID: "finance")
        let publisher = LoopdyWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: tasks,
            agents: agents, interval: .milliseconds(1), write: { writes.append($0) })
        publisher.publishNow()
        #expect(writes.last?.defaultAgentID == AgentProfile.financeFixture.id)
        publisher.retire()
        #expect(writes.last == .empty)
    }
}
