import SwiftUI

struct AgentActionSheet: View {
    let agent: AgentProfile
    var imageURL: URL? = nil
    let actions: [AgentActionItem]
    let onAction: (AgentRowMenuAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: LoopdyTokens.space16,
                                          bottom: LoopdyTokens.space8, trailing: LoopdyTokens.space16))

                // Like a contact card: the two everyday actions sit under the
                // agent, then history, then setup, with rarely used actions last.
                if !primaryActions.isEmpty {
                    Section { primaryButtons }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: LoopdyTokens.space16,
                                                  bottom: 0, trailing: LoopdyTokens.space16))
                }
                actionSection("Activity", conversationActions)
                actionSection("Setup", preferenceActions)
                actionSection("More", technicalActions)
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("agent.actions.list")
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Agent Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.action)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
            }
        }
        .accessibilityIdentifier("agent.actions")
    }

    private var header: some View {
        VStack(spacing: LoopdyTokens.space8) {
            AvatarView(stableID: agent.id, displayName: agent.name,
                       imageURL: imageURL, size: 72)
                .accessibilityHidden(true)
            Text(agent.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            if !agent.role.isEmpty {
                Text(agent.role)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if !agent.summary.isEmpty {
                Text(agent.summary)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LoopdyTokens.space8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [agent.name, agent.role, agent.summary]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        )
    }

    private var primaryActions: [AgentActionItem] {
        actions.filter { [.openChat, .edit].contains($0.action) }
    }

    private var conversationActions: [AgentActionItem] {
        actions.filter { [.viewSessions, .scheduledTasks, .groups].contains($0.action) }
    }

    private var preferenceActions: [AgentActionItem] {
        actions.filter { [.setPrimary, .togglePin].contains($0.action) }
    }

    private var technicalActions: [AgentActionItem] {
        actions.filter { [.shortcuts, .duplicate].contains($0.action) }
    }

    /// Message and Edit as two large tiles, filled accent for the primary one.
    private var primaryButtons: some View {
        HStack(spacing: LoopdyTokens.space12) {
            ForEach(primaryActions) { item in
                let isMessage = item.action == .openChat
                Button { onAction(item.action) } label: {
                    VStack(spacing: LoopdyTokens.space4) {
                        Image(systemName: isMessage ? "message.fill" : item.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(isMessage ? theme.actionForeground : theme.action)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(isMessage ? theme.action : theme.surface,
                                in: .rect(cornerRadius: LoopdyTokens.radius16, style: .continuous))
                    .opacity(item.isEnabled ? 1 : 0.45)
                    .contentShape(.rect)
                }
                .buttonStyle(.loopdyTilePress)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.detail ?? "")
                .accessibilityIdentifier("agent.\(agent.id).\(item.action.rawValue)")
            }
        }
        .padding(.vertical, LoopdyTokens.space4)
    }

    @ViewBuilder
    private func actionSection(_ title: String, _ items: [AgentActionItem]) -> some View {
        if !items.isEmpty {
            Section {
                actionRows(items)
            } header: {
                AgentStudioCaption(title)
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func actionRows(_ items: [AgentActionItem]) -> some View {
        ForEach(items) { item in
            Button { onAction(item.action) } label: {
                HStack(spacing: LoopdyTokens.space12) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.isSelected ? theme.actionForeground
                                         : item.isEnabled ? theme.action : theme.tertiaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: LoopdyTokens.radius8, style: .continuous)
                                .fill(item.isSelected ? theme.action : theme.incomingMessageBackground)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(item.isEnabled ? theme.primaryText : theme.secondaryText)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
            .accessibilityLabel(item.title)
            .accessibilityValue(item.detail ?? "")
            .accessibilityIdentifier("agent.\(agent.id).\(item.action.rawValue)")
        }
    }

    @LoopdyThemeReader private var theme
}

enum AgentActionPresentation {
    static let pinnedAgentLimit = 5
    static let setPrimaryHint = "New chats start with this agent."
    static let alreadyPrimaryHint = "New chats already start with this agent."
    static let pinHint = "Keeps this agent at the top of Agents."
    static let unpinHint = "Removes this agent from the top of Agents."
    static let pinLimitHint =
        "You can pin \(pinnedAgentLimit) agents. Unpin one to make room."
}
