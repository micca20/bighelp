import Observation
import SwiftUI

@MainActor
@Observable
final class SubagentStreamAcceptanceFixtureController {
    static let launchArgument = "-test-subagent-stream-fixture"
    static let parentSessionID = "demo-finance"
    static let childSessionID = "fixture-child-session"
    static let initialEventID = "fixture-initial-live"
    static let secondEventID = "fixture-second-live"
    static let terminalEventID = "fixture-canonical-terminal"

    private static let turnID = "fixture-child-turn"
    private static let initialToolCallID = "fixture-tool-initial"
    private static let canonicalToolCallID = "fixture-tool-canonical"

    private let appState: AppState
    private let sessionCatalog: SessionCatalogStore
    private let featureStore: ShellFeatureStore

    private(set) var observedDetailSessionID: String?
    private(set) var didEmitSecondEvent = false
    private(set) var didEmitTerminalEvent = false

    init(
        appState: AppState,
        sessionCatalog: SessionCatalogStore,
        featureStore: ShellFeatureStore
    ) {
        self.appState = appState
        self.sessionCatalog = sessionCatalog
        self.featureStore = featureStore
    }

    @discardableResult
    func installBeforePresentingParentRoute() -> Bool {
        let parentRoute = AppRoute.chat(conversationID: Self.parentSessionID)
        guard sessionCatalog.session(id: Self.parentSessionID)?.id == Self.parentSessionID,
              featureStore.prepare(parentRoute)
        else { return false }

        featureStore.acceptSessionSubagents(Self.parentRoster)
        featureStore.acceptExternalActivity(Self.initialActivity)

        guard let child = sessionCatalog.session(id: Self.childSessionID),
              child.id == Self.childSessionID,
              child.activityEvents.count(where: { $0.eventID == Self.initialEventID }) == 1,
              parentModel?.sessionSubagents == Self.parentRoster.subagents
        else { return false }

        appState.activateConversation(id: Self.parentSessionID, source: .newChat)
        return true
    }

    func readinessValue(displayedSubagents: [SessionSubagentSnapshot]) -> String {
        let parentRouteIsActive = appState.activeConversationID == Self.parentSessionID
            && appState.path.last.map { route in
                if case .chat(let conversationID) = route {
                    return conversationID == Self.parentSessionID
                }
                return false
            } == true
        let child = sessionCatalog.session(id: Self.childSessionID)
        let hasExactlyOneInitialEvent = child?.activityEvents.count(where: {
            $0.eventID == Self.initialEventID && $0.sessionID == Self.childSessionID
        }) == 1
        let rosterMatches = parentModel?.sessionSubagents == Self.parentRoster.subagents
            && displayedSubagents == Self.parentRoster.subagents
            && displayedSubagents.count(where: {
                $0.id == Self.childSnapshot.id && $0.sessionID == Self.childSessionID
            }) == 1

        return parentRouteIsActive
            && child?.id == Self.childSessionID
            && hasExactlyOneInitialEvent
            && rosterMatches
            ? "Ready"
            : "Not ready"
    }

    func observeDetail(sessionID: String) {
        guard sessionID == Self.childSessionID else { return }
        observedDetailSessionID = sessionID
    }

    func emitSecondLiveEvent() {
        guard observedDetailSessionID == Self.childSessionID,
              !didEmitSecondEvent
        else { return }
        featureStore.acceptExternalActivity(Self.secondActivity)
        didEmitSecondEvent = true
    }

    func emitCanonicalTerminalCatchUp() {
        guard observedDetailSessionID == Self.childSessionID,
              didEmitSecondEvent,
              !didEmitTerminalEvent
        else { return }
        featureStore.acceptExternalActivity(Self.terminalActivity)
        sessionCatalog.markInactiveAfterAuthoritativeTerminal(id: Self.childSessionID)
        didEmitTerminalEvent = true
    }

    func isControlling(sessionID: String) -> Bool {
        sessionID == Self.childSessionID
    }

    private var parentModel: ChatModel? {
        guard case .chat(let model)? = featureStore.preparedModel(
            for: .chat(conversationID: Self.parentSessionID)
        ) else { return nil }
        return model
    }

    private static let childSnapshot = SessionSubagentSnapshot(
        id: "fixture-subagent",
        sessionID: childSessionID,
        parentID: parentSessionID,
        role: "Acceptance verifier",
        goal: "Prove live child activity and canonical terminal reconciliation.",
        startedAt: 1_788_300_000
    )

    private static let parentRoster = SessionSubagentRosterSnapshot(
        sessionID: parentSessionID,
        subagents: [childSnapshot],
        updatedAt: 1_788_300_000
    )

    private static let initialActivity = ChatActivityEvent(
        eventID: initialEventID,
        sessionID: childSessionID,
        turnID: turnID,
        kind: .tool,
        lifecycle: .running,
        title: "Running initial production-path check",
        summary: nil,
        detail: "Initial live child activity accepted through ShellFeatureStore.",
        occurredAt: 1_788_300_001,
        durationMilliseconds: nil,
        toolCallID: initialToolCallID,
        toolName: "terminal",
        arguments: #"{"command":"swift test --filter initial"}"#,
        result: nil,
        subagentID: nil,
        botRunID: nil,
        memberID: nil,
        sourceOrder: 1
    )

    private static let secondActivity = ChatActivityEvent(
        eventID: secondEventID,
        sessionID: childSessionID,
        turnID: turnID,
        kind: .tool,
        lifecycle: .running,
        title: "Running follow-up production-path check",
        summary: nil,
        detail: "Second live event delivered while the detail route is already open.",
        occurredAt: 1_788_300_002,
        durationMilliseconds: nil,
        toolCallID: canonicalToolCallID,
        toolName: "terminal",
        arguments: #"{"command":"python3 verify_stream.py"}"#,
        result: nil,
        subagentID: nil,
        botRunID: nil,
        memberID: nil,
        sourceOrder: 2
    )

    private static let terminalActivity = ChatActivityEvent(
        eventID: terminalEventID,
        sessionID: childSessionID,
        turnID: turnID,
        kind: .tool,
        lifecycle: .failed,
        title: "Follow-up production-path check failed",
        summary: "Exited with status 1",
        detail: "Canonical terminal catch-up replaced the matching live tool call.",
        occurredAt: 1_788_300_003,
        durationMilliseconds: 240,
        toolCallID: canonicalToolCallID,
        toolName: "terminal",
        arguments: #"{"command":"python3 verify_stream.py"}"#,
        result: "fixture failure: expected terminal evidence",
        subagentID: nil,
        botRunID: nil,
        memberID: nil,
        sourceOrder: 2
    )
}

private struct SubagentStreamAcceptanceFixtureEnvironmentKey: EnvironmentKey {
    static let defaultValue: SubagentStreamAcceptanceFixtureController? = nil
}

extension EnvironmentValues {
    var subagentStreamAcceptanceFixture: SubagentStreamAcceptanceFixtureController? {
        get { self[SubagentStreamAcceptanceFixtureEnvironmentKey.self] }
        set { self[SubagentStreamAcceptanceFixtureEnvironmentKey.self] = newValue }
    }
}
