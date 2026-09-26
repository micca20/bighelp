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
        case .rejected: "Hermes rejected this operation."
        case .conflict: "The host state changed. Reload it before applying your changes."
        case .outcomeUnknown: "The host did not confirm this action. Check its current state before trying again."
        case .capacityExceeded: "This operation exceeds the supported size or capacity."
        }
    }
}
