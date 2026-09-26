import Foundation

/// The small, privacy-bounded view of Loopdy the Home Screen and Lock Screen
/// widgets render. The app writes it to the shared App Group; the widget
/// extension only reads it. No message bodies beyond a short preview line.
struct LoopdyWidgetSnapshot: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let agentName: String
        let status: String
        let preview: String?
        let isRunning: Bool
        let updatedAt: Date
        var agentID: String? = nil
        /// What the agent is doing (a `LoopdyActivityPose` raw value), while running.
        var activity: String? = nil
    }

    /// A Feed post or Goal from the default agent's board.
    struct BoardItem: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let icon: String
        var note: String? = nil
        var isDone = false
        let date: Date
    }

    /// The app's chosen colors (bubble color, Cream/Paper, Graphite/Black).
    struct Palette: Codable, Equatable, Sendable {
        let canvasHex: String
        let surfaceHex: String
        let primaryTextHex: String
        let secondaryTextHex: String
        let accentHex: String
        let accentForegroundHex: String
    }

    struct Task: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let agentName: String
        let schedule: String
        let nextRun: Date?
        let lastResult: String?
    }

    var defaultAgentID: String?
    var defaultAgentName: String?
    var sessions: [Session]
    var tasks: [Task]
    var generatedAt: Date
    var feed: [BoardItem]? = nil
    var goals: [BoardItem]? = nil
    var lightPalette: Palette? = nil
    var darkPalette: Palette? = nil

    static let empty = LoopdyWidgetSnapshot(defaultAgentID: nil, defaultAgentName: nil,
                                            sessions: [], tasks: [], generatedAt: .distantPast)

    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let fileName = "loopdy-widget-snapshot-v1.json"
    static let widgetKinds = ["LoopdyAgentWidget", "LoopdyActiveSessionsWidget", "LoopdyScheduledTasksWidget",
                              "LoopdyNewChatWidget", "LoopdyActivityFeedWidget"]

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> LoopdyWidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              data.count <= 262_144,
              let value = try? JSONDecoder.loopdyWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        let data = try JSONEncoder.loopdyWidget.encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var runningSessions: [Session] { sessions.filter(\.isRunning) }

    /// Running sessions first, then the most recently active.
    var feedSessions: [Session] {
        sessions.sorted { ($0.isRunning ? 1 : 0, $0.updatedAt) > ($1.isRunning ? 1 : 0, $1.updatedAt) }
    }

    static func chatURL(_ sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "chat"; components.path = "/" + sessionID
        return components.url ?? URL(string: "loopdy://home")!
    }

    static func newChatURL(agentID: String?) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "new-chat"
        if let agentID { components.queryItems = [URLQueryItem(name: "agent", value: agentID)] }
        return components.url ?? URL(string: "loopdy://new-chat")!
    }

    static let tasksURL = URL(string: "loopdy://tasks")!

    static func taskURL(_ taskID: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "tasks"; components.path = "/" + taskID
        return components.url ?? tasksURL
    }
    static let sessionsURL = URL(string: "loopdy://sessions")!

    /// The agent home: "chat", "feed", "ideas", "goals" or "apps".
    static func agentURL(_ tab: String = "chat") -> URL {
        URL(string: "loopdy://agent/\(tab)") ?? URL(string: "loopdy://home")!
    }
}

extension JSONEncoder {
    static var loopdyWidget: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}

extension JSONDecoder {
    static var loopdyWidget: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder
    }
}
