import SwiftUI

struct AgentSelectionView: View {
    let title: String
    let detail: String
    let agents: [AgentProfile]
    var avatarURL: @MainActor (AgentProfile) -> URL? = { _ in nil }
    let select: (AgentProfile) -> Void

    var body: some View {
        List {
            Section {
                ForEach(agents) { agent in
                    Button { select(agent) } label: {
                        HStack(spacing: LoopdyTokens.space12) {
                            AvatarView(
                                stableID: agent.id,
                                displayName: agent.name,
                                imageURL: avatarURL(agent),
                                size: 44
                            )
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(theme.primaryText)
                                if !agent.role.isEmpty {
                                    Text(agent.role)
                                        .font(.footnote)
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, LoopdyTokens.space4)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                    .accessibilityLabel("Choose \(agent.name)")
                    .accessibilityIdentifier("scheduled-tasks.choose-agent.\(agent.id)")
                }
            } header: {
                Text(detail)
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, LoopdyTokens.space8)
            }
            if agents.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Add an agent first, then give it a task.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @LoopdyThemeReader private var theme
}
