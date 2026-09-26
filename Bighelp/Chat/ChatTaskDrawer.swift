import SwiftUI

struct ChatTaskDrawer: View {
    let state: ChatTaskDrawerState
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: BighelpTokens.stateDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: state.isTerminal ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.isTerminal ? theme.success : theme.primaryText)
                    Text("Tasks")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: BighelpTokens.space8)
                    Text(progressLabel)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse tasks" : "Expand tasks")

            if isExpanded {
                Divider()
                    .padding(.bottom, BighelpTokens.space8)

                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(state.items) { task in
                        HStack(alignment: .top, spacing: BighelpTokens.space8) {
                            statusIcon(for: task.status)
                                .frame(width: 20, height: 20)
                            Text(task.content)
                                .bighelpFont(.body)
                                .foregroundStyle(task.status == .cancelled ? theme.tertiaryText : theme.primaryText)
                                .strikethrough(task.status == .cancelled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("chat.tasks.item.\(task.id)")
                    }
                }
                .padding(.bottom, BighelpTokens.space12)
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .bighelpSurface(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.tasks")
    }

    @ViewBuilder
    private func statusIcon(for status: ChatTaskStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(theme.tertiaryText)
        case .inProgress:
            BighelpThinkingOrb(scenario: .working, scale: .inline)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.success)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(theme.tertiaryText)
        }
    }

    private var progressLabel: String {
        state.totalCount == 0 ? "All cancelled" : "\(state.completedCount)/\(state.totalCount)"
    }

    @BighelpThemeReader private var theme: BighelpTheme

}
