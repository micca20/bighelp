import SwiftUI

struct SessionTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: ChatTaskDrawerState

    var body: some View {
        NavigationStack {
            ScrollView {
                taskContent
            }
            .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space20) {
            VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Session progress")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: LoopdyTokens.space8)
                    Text("\(state.completedCount) of \(state.totalCount)")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                ProgressView(
                    value: Double(state.completedCount),
                    total: Double(max(1, state.totalCount))
                )
                .tint(theme.action)
                .accessibilityLabel("Session task progress")
                .accessibilityValue("\(state.completedCount) of \(state.totalCount) completed")
            }
            .padding(LoopdyTokens.space16)
            .loopdySurface(.card)
            .accessibilityIdentifier("tasks.summary")

            LazyVStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                ForEach(state.items) { task in
                    HStack(alignment: .top, spacing: LoopdyTokens.space12) {
                        taskIcon(task.status)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                            Text(task.content)
                                .font(.body)
                                .foregroundStyle(task.status == .cancelled
                                    ? theme.tertiaryText
                                    : theme.primaryText)
                                .strikethrough(task.status == .cancelled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(taskStatus(task.status))
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(LoopdyTokens.space16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .loopdySurface(.card)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task.row.\(task.id)")
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(LoopdyTokens.space20)
        .frame(maxWidth: .infinity)
    }

    private func taskStatus(_ status: ChatTaskStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    @ViewBuilder
    private func taskIcon(_ status: ChatTaskStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(theme.tertiaryText)
        case .inProgress:
            LoopdyThinkingOrb(scenario: .working, scale: .inline)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(theme.tertiaryText)
        }
    }

    @LoopdyThemeReader private var theme

}
