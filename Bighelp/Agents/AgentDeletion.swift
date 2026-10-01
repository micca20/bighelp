import SwiftUI

/// Deletes one agent's Hermes profile through the shared profile lifecycle
/// path: review, retire its chats, delete, then confirm it's gone and refresh
/// the agent list. Absent where the connection can't delete profiles.
struct AgentDeletionAction {
    let run: @MainActor (_ profileID: String) async throws -> Void
}

extension EnvironmentValues {
    @Entry var agentDeletion: AgentDeletionAction? = nil
}

enum AgentDeletionPresentation {
    /// Hermes never deletes its default profile.
    static func canDelete(_ agent: AgentProfile) -> Bool {
        !agent.isDefault && agent.id != "default"
    }

    static func title(_ agent: AgentProfile) -> String { "Delete \(agent.name)?" }

    static func message(_ agent: AgentProfile) -> String {
        "This permanently deletes \(agent.name) from your computer, including its instructions, memory, skills, settings and chats. A reply in progress is stopped and unsent drafts are removed. This can't be undone."
    }

    static func progress(_ agent: AgentProfile) -> String { "Deleting \(agent.name)…" }

    static func errorMessage(_ error: any Error) -> String {
        switch error {
        case HermesProfileLifecycleError.currentProfileProtected:
            "Hermes is running as this agent on this connection, so it can't be deleted from here."
        case HermesProfileLifecycleError.activeDefaultProtected:
            "This agent is your computer's default. Make another agent the default first, in Hermes Tools › Profiles."
        case HermesProfileLifecycleError.reviewChanged:
            "This agent changed while it was being deleted. Try again."
        case HermesProfileLifecycleError.outcomeUnknown:
            "Hermes didn't confirm the deletion. Pull down to refresh the list before trying again."
        default:
            (error as? LocalizedError)?.errorDescription ?? "The agent couldn't be deleted. Try again."
        }
    }
}
