import Foundation
import Observation

struct LoopdyFoundationEvent: Identifiable, Equatable, Sendable {
    let id: String
    let role: Role
    let text: String
    let sourceOrder: Int

    enum Role: Equatable, Sendable {
        case user
        case assistant
    }
}

struct LoopdyFoundationSession: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    let agentName: String
    let updatedAt: Date
    var draft: String
    var events: [LoopdyFoundationEvent]

    init(
        id: String,
        title: String,
        agentName: String,
        updatedAt: Date,
        draft: String = "",
        events: [LoopdyFoundationEvent] = []
    ) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.updatedAt = updatedAt
        self.draft = draft
        self.events = events
    }

    var orderedEvents: [LoopdyFoundationEvent] {
        events.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.sourceOrder != rhs.element.sourceOrder {
                    return lhs.element.sourceOrder < rhs.element.sourceOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

struct LoopdyPlatformCapabilities: Equatable, Sendable {
    let supportsSessionBrowsing: Bool
    let supportsConversationComposition: Bool
    let supportsInspector: Bool
    let supportsKeyboardCommands: Bool
    let supportsNativeAgentRuntime: Bool

    static let macOSFoundation = LoopdyPlatformCapabilities(
        supportsSessionBrowsing: true,
        supportsConversationComposition: true,
        supportsInspector: true,
        supportsKeyboardCommands: true,
        supportsNativeAgentRuntime: false
    )
}

enum LoopdyFoundationRoute: Equatable, Sendable {
    case conversation(String)
    case settings
}

@MainActor
@Observable
final class LoopdyFoundationWorkspace {
    private(set) var sessions: [LoopdyFoundationSession]
    private(set) var selectedSessionID: String?
    private(set) var route: LoopdyFoundationRoute
    private(set) var isResponding = false
    var searchQuery = ""

    var filteredSessions: [LoopdyFoundationSession] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedStandardContains(query)
                || session.agentName.localizedStandardContains(query)
                || session.events.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var selectedSession: LoopdyFoundationSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    init(sessions: [LoopdyFoundationSession]) {
        self.sessions = sessions
        selectedSessionID = sessions.first?.id
        route = sessions.first.map { .conversation($0.id) } ?? .settings
    }

    func open(_ route: LoopdyFoundationRoute) {
        switch route {
        case .conversation(let id):
            selectSession(id: id)
            guard selectedSessionID == id else { return }
            self.route = route
        case .settings:
            self.route = route
        }
    }

    func selectSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
    }

    func updateDraft(_ draft: String) {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID })
        else { return }
        sessions[index].draft = draft
    }

    func sendDraft() {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID })
        else { return }
        let message = sessions[index].draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let nextOrder = (sessions[index].events.map(\.sourceOrder).max() ?? 0) + 1
        sessions[index].events.append(LoopdyFoundationEvent(
            id: "local-\(selectedSessionID)-\(nextOrder)",
            role: .user,
            text: message,
            sourceOrder: nextOrder
        ))
        sessions[index].draft = ""
        isResponding = true
    }

    func cancelResponse() {
        isResponding = false
    }

    static func fixture() -> LoopdyFoundationWorkspace {
        let referenceDate = Date(timeIntervalSince1970: 1_788_459_600)
        return LoopdyFoundationWorkspace(sessions: [
            LoopdyFoundationSession(
                id: "loopdy-foundation",
                title: "Native Mac foundation",
                agentName: "Loopdy",
                updatedAt: referenceDate,
                events: [
                    .init(
                        id: "foundation-user",
                        role: .user,
                        text: "Trace the native macOS foundation without changing the iOS experience.",
                        sourceOrder: 1
                    ),
                    .init(
                        id: "foundation-assistant",
                        role: .assistant,
                        text: "The desktop shell now uses a harness-neutral session identity and ordered conversation projection shared by both Apple app targets.",
                        sourceOrder: 2
                    ),
                ]
            ),
            LoopdyFoundationSession(
                id: "loopdy-release",
                title: "Release readiness",
                agentName: "Avery Park",
                updatedAt: referenceDate.addingTimeInterval(-3_600),
                events: [
                    .init(
                        id: "release-assistant",
                        role: .assistant,
                        text: "The release checklist is staged. Native harness work remains explicitly deferred.",
                        sourceOrder: 1
                    ),
                ]
            ),
            LoopdyFoundationSession(
                id: "loopdy-design",
                title: "Desktop design review",
                agentName: "Mina Shah",
                updatedAt: referenceDate.addingTimeInterval(-7_200),
                events: [
                    .init(
                        id: "design-assistant",
                        role: .assistant,
                        text: "Wide windows keep context visible; compact windows collapse the inspector before primary actions clip.",
                        sourceOrder: 1
                    ),
                ]
            ),
        ])
    }
}
