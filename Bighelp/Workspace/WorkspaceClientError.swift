import Foundation

enum WorkspaceClientError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(WorkspaceUnavailableReason)
    case ownerChanged
    case authenticationRequired
    case invalidRequest
    case invalidResponse
    case transportUnavailable
    case rejected(code: String?)
    case conflict
    case outcomeUnknown
    case capacityExceeded

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason.message
        case .ownerChanged: "The selected host or connection changed. Reopen this screen before continuing."
        case .authenticationRequired: "Sign in to this Hermes host again."
        case .invalidRequest: "This host request is invalid."
        case .invalidResponse: "Hermes returned an unsupported or invalid response."
        case .transportUnavailable: "The host is unavailable. Check its connection and try again."
        case .rejected(let code): Self.workspaceFilesMessage(code) ?? "Hermes rejected this operation."
        case .conflict: "The host state changed. Reload it before applying your changes."
        case .outcomeUnknown: "The host did not confirm this action. Check its current state before trying again."
        case .capacityExceeded: "This operation exceeds the supported size or capacity."
        }
    }

    /// The plugin's reasons it can't share an agent's files, said plainly, each
    /// with what to fix on the computer. Nil for any other refusal.
    static func workspaceFilesMessage(_ code: String?) -> String? {
        switch code {
        case "workspace_not_configured":
            "This agent has no working folder set on its computer. Set terminal.cwd for it in Hermes, then try again."
        case "workspace_unavailable":
            "This agent's working folder is missing on its computer, or Hermes can't open it."
        case "workspace_config_invalid":
            "Hermes can't read this agent's settings (config.yaml) on its computer. Fix them there, then try again."
        case "workspace_identity_changed", "workspace_changed":
            "This agent's working folder just changed. Try again."
        case "workspace_identity_unavailable", "workspace_files_unavailable":
            "This computer's Hermes can't share an agent's files yet. Update Hermes and the bighelp plugin."
        default:
            nil
        }
    }
}
