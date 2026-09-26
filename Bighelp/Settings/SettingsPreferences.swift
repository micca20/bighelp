import Foundation

enum BighelpInterfaceVersion: String, CaseIterable, Identifiable, Sendable {
    case v1, v2, v3

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var detail: String {
        switch self {
        case .v1: "The original bighelp interface."
        case .v2: "Coordinated controls and native glass."
        case .v3: "A cleaner conversation, compact composer, and coordinated native controls."
        }
    }
}

enum VoiceSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: Self { self }

    var speechRate: Float {
        switch self {
        case .slow: 0.44
        case .normal: 0.51
        case .fast: 0.58
        }
    }

    var hermesTTSSpeed: Float {
        switch self {
        case .slow: 0.85
        case .normal: 1
        case .fast: 1.15
        }
    }
}

enum VoiceMode: String, CaseIterable, Identifiable, Sendable {
    case pressToTalk
    case walkieTalkie

    var id: Self { self }

    var title: String {
        switch self {
        case .pressToTalk: "Press to Talk"
        case .walkieTalkie: "Walkie Talkie"
        }
    }

    var detail: String {
        switch self {
        case .pressToTalk:
            "Speak naturally and bighelp sends each completed phrase."
        case .walkieTalkie:
            "Hold Speak while talking, then release to send your turn."
        }
    }
}

enum VoiceConversationMode: String, CaseIterable, Identifiable, Sendable {
    case codexLive
    case turnBased

    var id: Self { self }

    var title: String {
        switch self {
        case .codexLive: "Codex Live"
        case .turnBased: "Turn-based"
        }
    }

    var detail: String {
        switch self {
        case .codexLive: "A continuous conversation that can keep talking while Hermes works."
        case .turnBased: "Each completed phrase is sent to Hermes as a separate turn."
        }
    }
}

enum ChatBrowserPreference: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case chrome
    case firefox
    case brave

    var id: Self { self }

    var title: String {
        switch self {
        case .systemDefault: "System Default"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .brave: "Brave"
        }
    }

    var systemImage: String {
        switch self {
        case .systemDefault: "arrow.up.right.square"
        case .chrome, .firefox, .brave: "globe"
        }
    }

    var availabilityProbeURL: URL? {
        switch self {
        case .systemDefault: nil
        case .chrome: URL(string: "googlechrome://")
        case .firefox: URL(string: "firefox://")
        case .brave: URL(string: "brave://")
        }
    }

    static func available(
        canOpenURL: (URL) -> Bool
    ) -> [ChatBrowserPreference] {
        allCases.filter { browser in
            guard let probeURL = browser.availabilityProbeURL else { return true }
            return canOpenURL(probeURL)
        }
    }

    func targetURL(for originalURL: URL) -> URL? {
        guard
            let originalScheme = originalURL.scheme?.lowercased(),
            originalScheme == "http" || originalScheme == "https"
        else { return nil }

        switch self {
        case .systemDefault:
            return originalURL
        case .chrome:
            guard var components = URLComponents(
                url: originalURL,
                resolvingAgainstBaseURL: false
            ) else { return nil }
            components.scheme = originalScheme == "https" ? "googlechromes" : "googlechrome"
            return components.url
        case .firefox, .brave:
            var components = URLComponents()
            components.scheme = rawValue
            components.host = "open-url"
            components.queryItems = [
                URLQueryItem(name: "url", value: originalURL.absoluteString)
            ]
            return components.url
        }
    }
}

enum MidSessionChatBehavior: String, CaseIterable, Identifiable, Sendable {
    case steer
    case queued
    case interruptAndSend

    var id: Self { self }

    var title: String {
        switch self {
        case .steer: "Steer"
        case .queued: "Queued"
        case .interruptAndSend: "Interrupt and Send"
        }
    }

    var detail: String {
        switch self {
        case .steer:
            "Send context into the live turn so the agent can adjust its response."
        case .queued:
            "Wait for the live turn to finish, then send this as the next message."
        case .interruptAndSend:
            "Stop the live turn and immediately continue with this message."
        }
    }
}

enum WorkspaceSwipeAction: String, CaseIterable, Identifiable, Sendable {
    case quickWorkspace
    case newChat
    case sessions
    case agents
    case home
    case inbox
    case profile
    case none

    static let allCases: [WorkspaceSwipeAction] = [
        .quickWorkspace,
        .newChat,
        .sessions,
        .agents,
        .home,
        .profile,
        .none,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .quickWorkspace: "Quick Workspace"
        case .newChat: "New Chat"
        case .sessions: "Sessions"
        case .agents: "Agents"
        case .home: "Home"
        case .inbox: "Inbox"
        case .profile: "Profile & Settings"
        case .none: "Off"
        }
    }

    var systemImage: String {
        switch self {
        case .quickWorkspace: "sidebar.left"
        case .newChat: "square.and.pencil"
        case .sessions: "clock.arrow.circlepath"
        case .agents: "person.2"
        case .home: "house"
        case .inbox: "tray"
        case .profile: "person.crop.circle"
        case .none: "hand.raised.slash"
        }
    }
}
