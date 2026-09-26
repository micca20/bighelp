import SwiftUI

/// Hooks the Chat tab gives a chat so it can draw the agent-home look: the
/// big live avatar, the ☰ drawer, New chat, and the bottom bar under the composer.
/// Chats opened from anywhere else keep the regular header.
struct AgentHomeChrome {
    var isEnabled = false
    /// The Chat tab's first page: ☰ and the tab bar. Otherwise Back.
    var isHome = true
    var onMenu: @MainActor () -> Void = {}
    var onProfile: @MainActor (String) -> Void = { _ in }
    var onSwitchAgent: @MainActor () -> Void = {}
    var onNewChat: @MainActor (String?) -> Void = { _ in }
    var tabSelection: Binding<AppTab>?
}

private struct AgentHomeChromeKey: EnvironmentKey {
    static var defaultValue: AgentHomeChrome { AgentHomeChrome() }
}

extension EnvironmentValues {
    var agentHomeChrome: AgentHomeChrome {
        get { self[AgentHomeChromeKey.self] }
        set { self[AgentHomeChromeKey.self] = newValue }
    }
}

/// The Chat tab's header: ☰ on the left, the live avatar and name in the
/// middle, New chat and chat options on the right.
struct AgentHomeChatHeader: View {
    let agentID: String
    let displayName: String
    let imageURL: URL?
    let activity: AgentActivityKind
    var status: String? = nil
    /// Group chats show their own identity control instead of one agent.
    let groupIdentity: AnyView?
    let options: AnyView
    let chrome: AgentHomeChrome
    let beforeAction: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let groupIdentity {
                    groupIdentity
                } else {
                    AgentHeroHeader(agentID: agentID, displayName: displayName, imageURL: imageURL,
                                    activity: activity, avatarSize: 76, status: status,
                                    onAvatarTap: { beforeAction(); chrome.onProfile(agentID) },
                                    onNameTap: { beforeAction(); chrome.onSwitchAgent() })
                        // Who the chat is with, like the name chip in the iPad header.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.header-surface")
                }
            }
            .frame(maxWidth: .infinity)
            HStack(alignment: .top) {
                Button {
                    beforeAction()
                    if chrome.isHome { chrome.onMenu() } else { onBack() }
                } label: {
                    Image(systemName: chrome.isHome ? "line.3.horizontal" : "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .loopdyNavigationGlass(in: Circle(), isInteractive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chrome.isHome ? "Chats and menu" : "Back")
                .accessibilityIdentifier(chrome.isHome ? "chat.menu" : "chat.back")
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        beforeAction()
                        chrome.onNewChat(groupIdentity == nil ? agentID : nil)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                            .loopdyNavigationGlass(in: Circle(), isInteractive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New chat")
                    .accessibilityHint("Pick one agent for a chat, or several for a group chat.")
                    .accessibilityIdentifier("chat.home.new-chat")
                    options
                        .loopdyNavigationGlass(in: Circle(), isInteractive: true)
                }
            }
        }
    }
}
