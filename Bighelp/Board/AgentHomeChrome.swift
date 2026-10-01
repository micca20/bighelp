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
    /// Opens the New chat picker (one agent, or several for a group).
    var onNewChat: @MainActor (String?) -> Void = { _ in }
    /// Starts a new chat with this agent right away.
    var onStartChat: @MainActor (String) -> Void = { _ in }
    var tabSelection: Binding<AppTab>?
    /// Board tabs with something new, for the dots on the tab bar.
    var unreadTabs: Set<AppTab> = []
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
    /// Full screen height, for the Auto avatar size.
    var screenHeight: CGFloat = 0
    let beforeAction: () -> Void
    let onBack: () -> Void
    @AppStorage(ChatLayoutPreferences.avatarSizeKey) private var avatarSize: ChatAvatarSize = .automatic
    @AppStorage(ChatLayoutPreferences.showsAgentNameKey) private var showsAgentName = true

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let groupIdentity {
                    groupIdentity
                } else {
                    AgentHeroHeader(agentID: agentID, displayName: displayName, imageURL: imageURL,
                                    activity: activity,
                                    avatarSize: avatarSize.points(screenHeight: screenHeight),
                                    status: status, showsName: showsAgentName,
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
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                        .padding(HeaderButtonMetrics.slop)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chrome.isHome ? "Chats and menu" : "Back")
                .accessibilityIdentifier(chrome.isHome ? "chat.menu" : "chat.back")
                Spacer()
                HStack(spacing: 0) {
                    newChatButton
                    options
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                        .padding(HeaderButtonMetrics.slop)
                        .contentShape(.rect)
                }
            }
        }
    }
}

extension AgentHomeChatHeader {
    /// Tap: a new chat with this agent. Touch and hold: the picker, for another
    /// agent or a group. A group chat has no one agent, so a tap opens the picker.
    var newChatButton: some View {
        let isDirect = groupIdentity == nil
        let pickAgents = {
            beforeAction()
            chrome.onNewChat(isDirect ? agentID : nil)
        }
        return Image(systemName: "square.and.pencil")
            .font(.title3.weight(.semibold))
            .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
            .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            .padding(HeaderButtonMetrics.slop)
            .contentShape(.rect)
            .onTapGesture {
                guard isDirect else { return pickAgents() }
                beforeAction()
                chrome.onStartChat(agentID)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                BighelpHaptics.tap()
                pickAgents()
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isDirect ? "New chat with \(displayName)" : "New chat")
            .accessibilityHint(isDirect
                ? "Touch and hold to pick other agents or start a group."
                : "Pick one agent for a chat, or several for a group chat.")
            .accessibilityAction {
                if isDirect { beforeAction(); chrome.onStartChat(agentID) } else { pickAgents() }
            }
            .accessibilityAction(named: "Pick agents") { pickAgents() }
            .accessibilityIdentifier("chat.home.new-chat")
    }
}

/// The chat header's round buttons: the glass circle people see, and a
/// larger square around it that still takes the tap. Taps near a circle's
/// edge used to miss and needed a second try.
enum HeaderButtonMetrics {
    #if os(visionOS)
    /// Eyes need bigger targets than fingers (60pt, per visionOS guidance).
    static let glass: CGFloat = 52
    static let slop: CGFloat = 6
    #else
    static let glass: CGFloat = 44
    static let slop: CGFloat = 5
    #endif
}
