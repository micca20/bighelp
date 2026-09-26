import SwiftUI

/// The Chat tab's ☰: new chats, the rest of the app that no longer sits in
/// the bottom bar (agents, scheduled tasks, settings), then recent chats.
struct AgentHomeDrawer: View {
    let agentName: String
    let chats: [SessionSummary]
    let agent: (String) -> (name: String, imageURL: URL?)?
    let showsWorkspace: Bool
    let onNewChat: () -> Void
    let onNewGroup: (() -> Void)?
    let onOpen: (SessionSummary) -> Void
    let onAllChats: () -> Void
    let onAgents: () -> Void
    let onScheduledTasks: () -> Void
    let onWorkspace: () -> Void
    let onSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("New chat with \(agentName)", systemImage: "square.and.pencil", id: "home.drawer.new-chat",
                        action: onNewChat)
                    if let onNewGroup {
                        row("New group chat", systemImage: "person.3", id: "home.drawer.new-group", action: onNewGroup)
                    }
                }
                Section {
                    row("Agents", systemImage: "person.2", id: "home.drawer.agents", action: onAgents)
                    row("Scheduled tasks", systemImage: "calendar.badge.clock", id: "home.drawer.scheduled",
                        action: onScheduledTasks)
                    if showsWorkspace {
                        row("Workspace", systemImage: "square.grid.2x2", id: "home.drawer.workspace", action: onWorkspace)
                    }
                    row("Settings", systemImage: "gearshape", id: "home.drawer.settings", action: onSettings)
                }
                Section("Recent") {
                    if chats.isEmpty {
                        Text("Your chats show up here.")
                            .foregroundStyle(theme.secondaryText)
                    }
                    ForEach(chats) { chat in
                        Button {
                            dismiss()
                            onOpen(chat)
                        } label: {
                            chatRow(chat)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.drawer.chat.\(chat.id)")
                    }
                    row("All chats", systemImage: "bubble.left.and.bubble.right", id: "home.drawer.all-chats",
                        action: onAllChats)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("home.drawer.done")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.drawer")
    }

    private func row(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(theme.primaryText)
        }
        .accessibilityIdentifier(id)
    }

    private func chatRow(_ chat: SessionSummary) -> some View {
        let lead = chat.kind == .direct ? chat.agentIDs.first.flatMap(agent) : nil
        return HStack(spacing: LoopdyTokens.space12) {
            if let lead, let id = chat.agentIDs.first {
                AvatarView(stableID: id, displayName: lead.name, imageURL: lead.imageURL, size: 36)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.subheadline)
                    .foregroundStyle(theme.action)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.action.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "New chat" : chat.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(lead?.name ?? "Group chat")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: LoopdyTokens.space8)
            if chat.isActive {
                Circle().fill(theme.action).frame(width: 8, height: 8)
                    .accessibilityLabel("Working")
            }
            Text(chat.updatedAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @LoopdyThemeReader private var theme
}
