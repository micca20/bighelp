import Foundation
import Testing
@testable import Loopdy

@MainActor
@Suite(.serialized)
struct DirectHermesDashboardDataSourceTests {
    @Test func selectedHostSessionReplyIsProjectedAndCurrentWorkUsesWorkProjection() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let completed = session(
            id: "completed-session", title: "Review the release", agentID: "reviewer",
            updatedAt: now.addingTimeInterval(-60), isActive: false,
            items: [assistantMessage(id: "reply", text: "The release checklist is ready.", at: now.addingTimeInterval(-60))]
        )
        let active = session(
            id: "active-session", title: "Prepare the build", agentID: "builder",
            updatedAt: now, isActive: true,
            items: [assistantMessage(id: "old-reply", text: "An earlier reply.", at: now.addingTimeInterval(-30))]
        )
        let source = try DirectHermesDashboardDataSource(
            authority: authority(),
            sessions: { [completed, active] },
            agents: { [profile("reviewer", name: "Reviewer"), profile("builder", name: "Builder")] },
            defaults: isolatedDefaults(), now: { now }
        )

        let snapshot = try await source.loadDashboard()

        #expect(snapshot.inbox.compactMap(\.sessionID) == ["completed-session"])
        #expect(snapshot.inbox.first?.title == "Review the release")
        #expect(snapshot.inbox.first?.detail == "The release checklist is ready.")
        #expect(snapshot.inbox.first?.agentName == "Reviewer")
        #expect(snapshot.inbox.first?.status == "1m ago")
        #expect(snapshot.attentionItems.isEmpty)
        #expect(snapshot.completedItems.isEmpty)
        #expect(snapshot.agents.map(\.id) == ["reviewer", "builder"])
    }

    @Test func nativeApprovalIsPresentedAndRespondedThroughInjectedOwner() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let approval = DirectHermesDashboardApproval.hostedRoom(
            HermesBotModePendingApproval(
                roomID: "room-1", memberID: "member-1", taskID: "task-1",
                executionGeneration: 3, requestID: "request-1", command: "terminal",
                description: "Run the checked command.", choices: [.once, .deny]
            ),
            roomName: "Release room", agentName: "Builder", createdAt: now
        )
        var submitted: (String, ApprovalDecision)?
        let source = try DirectHermesDashboardDataSource(
            authority: authority(), sessions: { [] }, agents: { [] },
            approvals: { [approval] },
            approvalResponder: { approval, decision in
                submitted = (approval.id, decision)
            },
            defaults: isolatedDefaults(), now: { now }
        )

        let snapshot = try await source.loadDashboard()
        let item = try #require(snapshot.attentionItems.first)
        #expect(item.id == "native.approval.\(approval.id)")
        #expect(item.approvalID == approval.id)
        #expect(item.sessionID == "hermes-room:room-1")
        #expect(item.interaction.isStructuredDecision)
        if case .approval(let request) = item.interaction {
            #expect(Set(request.allowedDecisions) == [.once, .deny])
            #expect(request.expiresAt == .distantFuture)
        } else {
            Issue.record("Expected a native approval interaction")
        }

        let loaded = try await source.loadApproval(id: approval.id)
        #expect(loaded.request.action == "terminal")
        #expect(loaded.request.requester == "Builder")
        _ = try await source.submit(request: loaded.request, decision: .once)
        #expect(submitted?.0 == approval.id)
        #expect(submitted?.1 == .once)
    }

    @Test func dashboardPresentationStatePersistsPerAuthorityWithoutRemoteCalls() async throws {
        let defaults = isolatedDefaults()
        let authority = try authority()
        let otherAuthority = try WorkspaceAuthority.direct(
            endpointIdentity: "https://other-native.example", providerID: "default", userID: "user"
        )
        let record = session(
            id: "session-1", title: "Persist this update", agentID: "agent",
            updatedAt: Date(timeIntervalSince1970: 29_900), isActive: false,
            items: [assistantMessage(id: "reply-1", text: "A durable update.", at: Date(timeIntervalSince1970: 29_900))]
        )
        let first = try DirectHermesDashboardDataSource(
            authority: authority, sessions: { [record] }, agents: { [profile("agent", name: "Agent")] },
            defaults: defaults, now: { Date(timeIntervalSince1970: 30_000) }
        )
        let id = try #require((await first.loadDashboard()).inbox.first?.id)
        try await first.setDashboardEventState(id: id, isRead: true, isPinned: true)

        let second = try DirectHermesDashboardDataSource(
            authority: authority, sessions: { [record] }, agents: { [profile("agent", name: "Agent")] },
            defaults: defaults, now: { Date(timeIntervalSince1970: 30_000) }
        )
        let retained = try #require((await second.loadDashboard()).inbox.first)
        #expect(retained.isRead)
        #expect(retained.isPinned)

        try await second.dismissDashboardEvents(
            types: ["channel.message"], createdBefore: Date(timeIntervalSince1970: 30_001)
        )
        #expect((try await second.loadDashboard()).inbox.isEmpty)

        let other = try DirectHermesDashboardDataSource(
            authority: otherAuthority, sessions: { [record] }, agents: { [profile("agent", name: "Agent")] },
            defaults: defaults, now: { Date(timeIntervalSince1970: 30_000) }
        )
        #expect((try await other.loadDashboard()).inbox.count == 1)
    }

    @Test func staleSelectedHostCannotReadOrMutateNativeDashboardProjection() async throws {
        var current = true
        let record = session(
            id: "owned-session", title: "Owned update", agentID: "agent", updatedAt: .now,
            isActive: false, items: [assistantMessage(id: "reply", text: "Owned", at: .now)]
        )
        let source = try DirectHermesDashboardDataSource(
            authority: authority(), sessions: { [record] }, agents: { [] },
            defaults: isolatedDefaults(), isCurrentOwner: { current }
        )
        current = false

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await source.loadDashboard()
        }
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await source.dismissDashboardEvent(id: "native.session.owned-session.reply")
        }
    }

    @Test func activityUpdateIDStaysBoundedForAnOfficialMaximumLengthSessionID() async throws {
        let sessionID = String(repeating: "s", count: 256)
        let record = session(
            id: sessionID, title: "Long native session", agentID: "agent",
            updatedAt: Date(timeIntervalSince1970: 29_900), isActive: false,
            items: [assistantMessage(id: "42", text: "A durable update.", at: Date(timeIntervalSince1970: 29_900))]
        )
        let source = try DirectHermesDashboardDataSource(
            authority: authority(), sessions: { [record] }, agents: { [self.profile("agent", name: "Agent")] },
            defaults: isolatedDefaults(), now: { Date(timeIntervalSince1970: 30_000) }
        )

        let item = try #require((await source.loadDashboard()).inbox.first)
        #expect(item.id.utf8.count <= 220)
        try await source.dismissDashboardEvent(id: item.id)
        #expect((try await source.loadDashboard()).inbox.isEmpty)
    }

    private func authority() throws -> WorkspaceAuthority {
        try .direct(endpointIdentity: "https://native.example", providerID: "default", userID: "user")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "loopdy.direct-dashboard-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func profile(_ id: String, name: String) -> AgentProfile {
        AgentProfile(id: id, name: name, role: "Hermes agent", summary: "", instructions: "",
                     avatarFileName: nil, isDefault: false)
    }

    private func session(
        id: String, title: String, agentID: String, updatedAt: Date, isActive: Bool,
        items: [TimelineItem]
    ) -> SessionRecord {
        SessionRecord(
            id: id, kind: .direct, agentIDs: [agentID], title: title,
            items: items, isActive: isActive, createdAt: updatedAt.addingTimeInterval(-300),
            updatedAt: updatedAt, hasAcceptedMessage: true
        )
    }

    private func assistantMessage(id: String, text: String, at date: Date) -> TimelineItem {
        TimelineItem(
            id: id, role: .assistant,
            sender: .agent(id: "agent", snapshot: .init(name: "Hermes")),
            content: .message(text), metadata: .init(delivery: "Complete", timestamp: date)
        )
    }
}
