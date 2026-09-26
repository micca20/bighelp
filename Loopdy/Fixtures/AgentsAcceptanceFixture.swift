#if DEBUG && targetEnvironment(simulator)
import Foundation

enum AgentsAcceptanceFixture {
    static let launchArgument = "-test-agents-directory"

    static let profiles: [AgentProfile] = [
        profile("studio", name: "Studio", role: "Everyday planning",
                summary: "A steady hand for ideas, decisions, and the day ahead.", isDefault: true),
        profile("build", name: "Build", role: "Software specialist",
                summary: "Turns small experiments into dependable software."),
        profile("field", name: "Field Notes", role: "Research partner",
                summary: "Finds sources and keeps facts separate from assumptions."),
        profile("garden", name: "Garden", role: "Growing and making",
                summary: "Helps plan practical projects for a small outdoor space."),
        profile("ledger", name: "Ledger", role: "Budget planning",
                summary: "Organizes estimates and explains the choices behind them."),
        profile("trail", name: "Trail", role: "Trip planning",
                summary: "Keeps the route, weather, and packing list together."),
        profile("library", name: "Library", role: "Reading companion",
                summary: "Connects notes and makes room for new perspectives."),
        profile("long-name", name: "The Workshop for Thoughtful Experiments",
                role: "An agent with a deliberately long display name",
                summary: "A synthetic accessibility fixture whose description must remain readable without covering its actions.")
    ]

    private static func profile(
        _ id: String, name: String, role: String, summary: String, isDefault: Bool = false
    ) -> AgentProfile {
        AgentProfile(
            id: id, name: name, role: role, summary: summary,
            instructions: "Use only synthetic information in this demonstration.",
            isDefault: isDefault
        )
    }
}
#endif
