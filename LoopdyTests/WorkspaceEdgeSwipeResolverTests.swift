import CoreGraphics
import Foundation
import Testing
@testable import Loopdy

struct WorkspaceEdgeSwipeResolverTests {
    @Test func resolvesOnlyDeliberateHorizontalGesturesFromTheLeftEdge() {
        let action = WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 12, y: 220),
            translation: CGSize(width: 88, height: 14),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        )

        #expect(action == .quickWorkspace)
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 42, y: 220),
            translation: CGSize(width: 88, height: 14),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 12, y: 220),
            translation: CGSize(width: 32, height: 120),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
    }

    @Test func resolvesTheConfiguredRightEdgeActionAndHonorsDisabledActions() {
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 382, y: 220),
            translation: CGSize(width: -90, height: 8),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .sessions
        ) == .sessions)

        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 382, y: 220),
            translation: CGSize(width: -90, height: 8),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
    }
}

struct QuickWorkspaceContentTests {
    @Test func keepsExactlyTheFiveMostRecentSessionsInCatalogOrder() {
        let sessions = (0..<7).map { index in
            SessionSummary(
                id: "session-\(index)",
                kind: .direct,
                agentIDs: ["agent"],
                title: "Session \(index)",
                preview: "Preview",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }

        let content = QuickWorkspaceContent(recentSessions: sessions)

        #expect(content.recentSessions.map(\.id) == (0..<5).map { "session-\($0)" })
    }

    @Test func groupsTheBoundedRecentChatsByProjectWithUnassignedLast() {
        let sessions = [
            SessionSummary(
                id: "loopdy-new", kind: .direct, agentIDs: ["agent"], title: "Loopdy new",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 100),
                workspaceID: "project-loopdy", workspaceName: "Loopdy iOS"
            ),
            SessionSummary(
                id: "infra", kind: .direct, agentIDs: ["agent"], title: "Infrastructure",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 90),
                workspaceID: "project-infra", workspaceName: "Hermes Infrastructure"
            ),
            SessionSummary(
                id: "loopdy-old", kind: .direct, agentIDs: ["agent"], title: "Loopdy old",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 80),
                workspaceID: "project-loopdy", workspaceName: "Loopdy iOS"
            ),
            SessionSummary(
                id: "unassigned", kind: .direct, agentIDs: ["agent"], title: "Unassigned",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 70)
            ),
            SessionSummary(
                id: "personal", kind: .direct, agentIDs: ["agent"], title: "Personal",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 60),
                workspaceID: "project-personal", workspaceName: "Personal"
            ),
            SessionSummary(
                id: "excluded", kind: .direct, agentIDs: ["agent"], title: "Excluded",
                preview: "Preview", updatedAt: Date(timeIntervalSince1970: 50),
                workspaceID: "project-excluded", workspaceName: "Excluded"
            ),
        ]

        let content = QuickWorkspaceContent(
            recentSessions: sessions,
            organizeByProjects: true
        )

        #expect(content.sessionGroups.map(\.title) == [
            "Loopdy iOS", "Hermes Infrastructure", "Personal", "Unassigned",
        ])
        #expect(content.sessionGroups.map { $0.sessions.map(\.id) } == [
            ["loopdy-new", "loopdy-old"], ["infra"], ["personal"], ["unassigned"],
        ])
    }

    @Test func activityAndToolsPrecedeRecentChatsAndPinnedAgents() {
        #expect(
            QuickWorkspaceSectionPresentation.contentOrder
                == [.home, .secondaryRoutes, .sessions, .agents]
        )
        #expect(QuickWorkspaceSectionPresentation.buttonMinimumHeight == 44)
    }
}

struct WorkspaceMenuOwnershipTests {
    @Test func rootOverlayIsTheOnlyOwnerAtTheRoot() {
        #expect(WorkspaceMenuOwnership.shouldPresentRootOverlay(
            isPresented: true,
            path: []
        ))
        #expect(!WorkspaceMenuOwnership.shouldPresentRootOverlay(
            isPresented: false,
            path: []
        ))
    }

    @Test func pushedRoutesLeaveDrawerOwnershipToTheirRouteCover() {
        #expect(!WorkspaceMenuOwnership.shouldPresentRootOverlay(
            isPresented: true,
            path: [.sessions]
        ))
        #expect(!WorkspaceMenuOwnership.shouldPresentRootOverlay(
            isPresented: true,
            path: [.chat(conversationID: "current")]
        ))
    }
}
