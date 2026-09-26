import Foundation

struct SettingsConnectivityPresentation: Equatable {
    let showsDirectGatewaySetup: Bool
    let footer: String

    init(linkAccountState: LoopdyLinkAccountState) {
        showsDirectGatewaySetup = false
        footer = switch linkAccountState {
        case .ready:
            "Loopdy Link carries chats, agents, sessions, scheduled tasks, and approvals through your paired Hermes host; no separate gateway address or token is required."
        case .signedOut, .working, .failed:
            "Sign in to Loopdy Link to connect this app to your authorized Hermes hosts."
        }
    }
}

struct SettingsLinkConnectionPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let systemImage: String
    let isTransient: Bool

    init(state: LoopdyLinkLiveSocketState) {
        switch state {
        case .stopped:
            title = "Disconnected"
            detail = "Loopdy Link will reconnect when your account and paired host are available."
            systemImage = "link.slash"
            isTransient = false
        case .connecting:
            title = "Connecting"
            detail = "Loopdy Link is establishing the secure connection in the background."
            systemImage = "link"
            isTransient = true
        case .retrying:
            title = "Reconnecting"
            detail = "Loopdy Link is restoring the secure connection in the background."
            systemImage = "arrow.triangle.2.circlepath"
            isTransient = true
        case .superseded:
            title = "Connection moved"
            detail = "A newer connection owns this device. Retry only if you want this app to take it back."
            systemImage = "arrow.left.arrow.right"
            isTransient = false
        case .verified:
            title = "Connected"
            detail = "The secure connection to your paired Hermes host is ready."
            systemImage = "link.circle.fill"
            isTransient = false
        }
    }
}

enum SettingsMenuSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case accountAndDevices
    case appearance
    case workspace
    case agentsAndPersonalities
    case chat
    case notifications
    case permissions
    case connectivityAndNotifications

    var id: Self { self }

    var title: String {
        switch self {
        case .accountAndDevices: "Account & Devices"
        case .workspace: "Workspace"
        case .agentsAndPersonalities: "Agents & Personalities"
        case .chat: "Chat & Voice"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .connectivityAndNotifications: "Hermes connection"
        }
    }

    var detail: String {
        switch self {
        case .accountAndDevices: "Profile, Loopdy Link, and paired devices"
        case .workspace: "Sessions, scheduled tasks, and gestures"
        case .agentsAndPersonalities: "Manage how Hermes agents present themselves"
        case .chat: "Reasoning, tool calls, inline UI, and voice"
        case .notifications: "Optional host enrollment, iOS access, and provider topics"
        case .appearance: "Theme, color mode, and Reflective Vision"
        case .permissions: "iOS access, status, and recovery"
        case .connectivityAndNotifications: "The computer your agents run on"
        }
    }

    var systemImage: String {
        switch self {
        case .accountAndDevices: "person.crop.circle.badge.checkmark"
        case .workspace: "rectangle.3.group"
        case .agentsAndPersonalities: "theatermasks"
        case .chat: "bubble.left.and.text.bubble.right"
        case .notifications: "bell.badge"
        case .appearance: "paintpalette"
        case .permissions: "hand.raised"
        case .connectivityAndNotifications: "desktopcomputer"
        }
    }

}
