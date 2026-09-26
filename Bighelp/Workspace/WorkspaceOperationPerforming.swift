import Foundation

@MainActor
protocol WorkspaceOperationPerforming: AnyObject {
    var owner: WorkspaceOwner? { get }
    var capabilities: WorkspaceCapabilities { get }

    func perform(
        _ operation: WorkspaceOperation,
        payload: [String: BighelpJSONValue],
        owner: WorkspaceOwner
    ) async throws -> [String: BighelpJSONValue]
}

enum WorkspaceMutationOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case committed(Value)
    case partial(value: Value, unappliedFields: [String])
    case unconfirmed
}
