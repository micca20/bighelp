import SwiftUI

struct ChatTaskDrawer: View {
    let state: ChatTaskDrawerState
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: LoopdyTokens.stateDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: LoopdyTokens.space8) {
                    Image(systemName: state.isTerminal ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.isTerminal ? theme.success : theme.primaryText)
                    Text("Tasks")
                        .loopdyFont(.label)
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: LoopdyTokens.space8)
                    Text(progressLabel)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(minHeight: LoopdyTokens.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse tasks" : "Expand tasks")

            if isExpanded {
                Divider()
                    .padding(.bottom, LoopdyTokens.space8)

                VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                    ForEach(state.items) { task in
                        HStack(alignment: .top, spacing: LoopdyTokens.space8) {
                            statusIcon(for: task.status)
                                .frame(width: 20, height: 20)
                            Text(task.content)
                                .loopdyFont(.body)
                                .foregroundStyle(task.status == .cancelled ? theme.tertiaryText : theme.primaryText)
                                .strikethrough(task.status == .cancelled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("chat.tasks.item.\(task.id)")
                    }
                }
                .padding(.bottom, LoopdyTokens.space12)
            }
        }
        .padding(.horizontal, LoopdyTokens.space16)
        .loopdySurface(.card)
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
            LoopdyThinkingOrb(scenario: .working, scale: .inline)
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

    @LoopdyThemeReader private var theme: LoopdyTheme

}
