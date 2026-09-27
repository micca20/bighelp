import SwiftUI

/// ☰ on iPhone: bighelp's one menu as a sheet (hosts, chats, and everywhere else).
struct AgentHomeDrawer: View {
    let chats: [SessionSummary]
    let agent: (String) -> (name: String, imageURL: URL?)?
    let hosts: BighelpMenuHosts
    let destinations: BighelpMenuDestinations
    let onOpen: (SessionSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BighelpMenu(hosts: hosts, destinations: destinations, close: { dismiss() }, hasRecent: !chats.isEmpty) {
                AnyView(recentChats)
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("menu.done")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.drawer")
    }

    @ViewBuilder
    private var recentChats: some View {
        ForEach(chats) { chat in
            Button {
                dismiss()
                onOpen(chat)
            } label: {
                BighelpMenuChatRow(chat: chat, agent: agent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu.chat.\(chat.id)")
        }
    }
}
