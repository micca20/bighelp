import Foundation
import Testing
@testable import LoopdyMac

@MainActor
struct LoopdyMacFoundationTests {
    @Test("fixture selection preserves one canonical session identity")
    func fixtureSelectionPreservesCanonicalIdentity() {
        let workspace = LoopdyFoundationWorkspace.fixture()
        let expectedID = try! #require(workspace.sessions.first?.id)

        workspace.selectSession(id: expectedID)
        workspace.updateDraft("Follow up from the Mac")

        #expect(workspace.selectedSessionID == expectedID)
        #expect(workspace.selectedSession?.id == expectedID)
        #expect(workspace.sessions.first(where: { $0.id == expectedID })?.draft == "Follow up from the Mac")
    }

    @Test("routes select sessions and settings without duplicating state")
    func routesSelectCanonicalState() {
        let workspace = LoopdyFoundationWorkspace.fixture()
        let expectedID = try! #require(workspace.sessions.last?.id)

        workspace.open(.settings)
        #expect(workspace.route == .settings)

        workspace.open(.conversation(expectedID))
        #expect(workspace.route == .conversation(expectedID))
        #expect(workspace.selectedSessionID == expectedID)
        #expect(workspace.selectedSession?.id == expectedID)
    }

    @Test("macOS foundation declares only implemented platform capabilities")
    func macOSFoundationCapabilitiesAreHonest() {
        let capabilities = LoopdyPlatformCapabilities.macOSFoundation

        #expect(capabilities.supportsSessionBrowsing)
        #expect(capabilities.supportsConversationComposition)
        #expect(capabilities.supportsInspector)
        #expect(capabilities.supportsKeyboardCommands)
        #expect(!capabilities.supportsNativeAgentRuntime)
    }

    @Test("conversation events retain canonical identity and source ordering")
    func timelineOrderingIsStable() {
        let session = LoopdyFoundationSession(
            id: "session-ordering",
            title: "Ordering",
            agentName: "Loopdy",
            updatedAt: .distantPast,
            events: [
                .init(id: "third", role: .assistant, text: "Third", sourceOrder: 3),
                .init(id: "first", role: .assistant, text: "First", sourceOrder: 1),
                .init(id: "second", role: .user, text: "Second", sourceOrder: 2),
            ]
        )

        #expect(session.orderedEvents.map(\.id) == ["first", "second", "third"])
        #expect(session.orderedEvents.map(\.sourceOrder) == [1, 2, 3])
    }

    @Test("send and cancel mutate the selected canonical conversation")
    func sendAndCancelUseSelectedConversation() {
        let workspace = LoopdyFoundationWorkspace.fixture()
        let sessionID = try! #require(workspace.selectedSessionID)
        workspace.updateDraft("Build the Mac tracer")

        workspace.sendDraft()

        #expect(workspace.selectedSessionID == sessionID)
        #expect(workspace.selectedSession?.events.last?.role == .user)
        #expect(workspace.selectedSession?.events.last?.text == "Build the Mac tracer")
        #expect(workspace.selectedSession?.draft.isEmpty == true)
        #expect(workspace.isResponding)

        workspace.cancelResponse()
        #expect(!workspace.isResponding)
    }

    @Test("session search filters shared fixture records")
    func sessionSearchFiltersFixtureRecords() {
        let workspace = LoopdyFoundationWorkspace.fixture()

        workspace.searchQuery = "release"

        #expect(workspace.filteredSessions.map(\.id) == ["loopdy-release"])
        #expect(workspace.sessions.count > workspace.filteredSessions.count)
    }

    @Test("sidebar toggle preserves the conversation column")
    func sidebarTogglePreservesConversationColumn() {
        #expect(LoopdyMacColumnVisibility.toggled(from: .all) == .doubleColumn)
        #expect(LoopdyMacColumnVisibility.toggled(from: .doubleColumn) == .all)
    }

    @Test("compact windows collapse the inspector before primary content clips")
    func compactLayoutCollapsesInspector() {
        #expect(LoopdyMacLayoutPolicy.mode(for: 760) == .compact)
        #expect(LoopdyMacLayoutPolicy.mode(for: 899) == .compact)
        #expect(LoopdyMacLayoutPolicy.mode(for: 900) == .expanded)
        #expect(LoopdyMacLayoutPolicy.mode(for: 1_440) == .expanded)
        #expect(LoopdyMacColumnVisibility.toggled(from: .all, mode: .compact) == .detailOnly)
        #expect(LoopdyMacColumnVisibility.toggled(from: .detailOnly, mode: .compact) == .all)
    }
}
