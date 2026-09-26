import SwiftUI

struct SessionGoalSheet: View {
    let state: ChatGoalRailState
    let onCommand: (String) -> Void

    @State private var editedGoal: String
    @State private var showsClearConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(state: ChatGoalRailState, onCommand: @escaping (String) -> Void) {
        self.state = state
        self.onCommand = onCommand
        _editedGoal = State(initialValue: state.summary)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                goalContent
            }
            .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear this goal?",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear goal", role: .destructive) { perform("clear") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes uses Clear to remove the standing goal. This does not delete chat messages or session history; Hermes has no separate goal-delete action.")
            }
        }
    }

    private var goalContent: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space20) {
            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                Label(
                    state.lifecycle == .paused ? "Goal paused" : "Goal active",
                    systemImage: state.lifecycle == .paused ? "pause.circle.fill" : "target"
                )
                .font(.headline)
                .foregroundStyle(state.lifecycle == .paused ? theme.warning : theme.success)
                Text("Keep this session focused. Updates and completion apply to this goal only.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LoopdyTokens.space16)
            .loopdySurface(.card)
            .accessibilityIdentifier("goal.summary")

            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                Text("Current goal")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                TextField("Goal", text: $editedGoal, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(5...10)
                    .padding(LoopdyTokens.space12)
                    .loopdySurface(.input, isInteractive: true)
                    .accessibilityLabel("Goal text")
            }

            Button {
                perform(editedGoal.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Label("Save goal", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .loopdyActionStyle(.primary)
            .disabled(editedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || editedGoal.trimmingCharacters(in: .whitespacesAndNewlines) == state.summary)
            .accessibilityIdentifier("goal.save")

            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                Text("Goal status")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)

                Button {
                    perform(state.lifecycle == .paused ? "resume" : "pause")
                } label: {
                    Label(
                        state.lifecycle == .paused ? "Resume goal" : "Pause goal",
                        systemImage: state.lifecycle == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .loopdyActionStyle(.secondary)
                .accessibilityIdentifier("goal.pause-resume")

                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label("Clear goal", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .loopdyActionStyle(.secondary)
                .accessibilityHint("Removes the standing goal without deleting this chat or its history.")
                .accessibilityIdentifier("goal.clear")

                Text("Clear is Hermes’ supported delete-equivalent for a goal. There is no separate goal delete operation.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(LoopdyTokens.space20)
        .frame(maxWidth: .infinity)
    }

    private func perform(_ command: String) {
        onCommand(command)
        dismiss()
    }

    @LoopdyThemeReader private var theme

}
