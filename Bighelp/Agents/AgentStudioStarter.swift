import SwiftUI

/// A local starting point for a new agent. Applying one only prefills the
/// editor draft; nothing reaches Hermes until the user taps Create.
struct AgentStudioStarter: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let name: String
    let role: String
    let summary: String
    let instructions: String

    static let blank = AgentStudioStarter(
        id: "blank", title: "Blank", systemImage: "square.dashed",
        name: "", role: "", summary: "", instructions: ""
    )

    static let all: [AgentStudioStarter] = [
        AgentStudioStarter(
            id: "assistant", title: "Personal assistant", systemImage: "sparkles",
            name: "Juniper", role: "Personal assistant",
            summary: "Keeps your day organized and your to-dos moving.",
            instructions: """
            Help me plan my day, remember what matters, and get small tasks done. \
            Be warm and brief. Ask one clear question when something is ambiguous, \
            and suggest a next step when you finish.
            """
        ),
        AgentStudioStarter(
            id: "researcher", title: "Researcher", systemImage: "magnifyingglass",
            name: "Sage", role: "Researcher",
            summary: "Digs into questions and brings back clear, sourced answers.",
            instructions: """
            Research the questions I bring you. Compare sources, say how confident you are, \
            and link or name where facts came from. Lead with a short answer, then the details.
            """
        ),
        AgentStudioStarter(
            id: "travel", title: "Travel planner", systemImage: "airplane",
            name: "Pip", role: "Travel planner",
            summary: "Finds flights, stays, and easy itineraries.",
            instructions: """
            Help me plan trips: flights, places to stay, and day-by-day ideas. \
            Keep my budget and dates in mind, offer two or three good options, \
            and be upbeat and practical.
            """
        ),
        AgentStudioStarter(
            id: "budget", title: "Budget buddy", systemImage: "chart.pie",
            name: "Miso", role: "Budget buddy",
            summary: "Helps you track spending and stick to a plan.",
            instructions: """
            Help me understand my spending and plan a realistic budget. \
            Be encouraging, never judgmental. Show simple numbers and explain your math.
            """
        ),
        AgentStudioStarter(
            id: "writing", title: "Writing coach", systemImage: "pencil.and.scribble",
            name: "Wren", role: "Writing coach",
            summary: "Polishes drafts and helps you find the right words.",
            instructions: """
            Help me write and edit. Keep my voice, suggest clearer wording, \
            and explain changes briefly. Offer a tightened version when I share a draft.
            """
        ),
        .blank,
    ]
}

/// 11pt bold, letterspaced, uppercase section caption used across the Agent Studio.
struct AgentStudioCaption: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}

/// Horizontal "Start from" chips for new agents.
struct AgentStudioStarterRow: View {
    let selectedID: String?
    let onSelect: (AgentStudioStarter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            AgentStudioCaption("Start from")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BighelpTokens.space8) {
                    ForEach(AgentStudioStarter.all) { starter in
                        chip(starter)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ starter: AgentStudioStarter) -> some View {
        let isSelected = starter.id == selectedID
        return Button {
            onSelect(starter)
        } label: {
            Label(starter.title, systemImage: starter.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: 36)
                .background(
                    Capsule().fill(isSelected ? theme.action : theme.incomingMessageBackground)
                )
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1))
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start from \(starter.title)")
        .accessibilityHint(starter.id == AgentStudioStarter.blank.id
                           ? "Clears the suggested details."
                           : "Fills in a suggested name, role, and instructions you can edit.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.editor.starter.\(starter.id)")
    }

    @BighelpThemeReader private var theme
}
