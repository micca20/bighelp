import Foundation

@MainActor
final class DirectHermesCoreRequestScope {
    let workspace: any WorkspaceOperationPerforming
    let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func check() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner, workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }

    func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        try check()
        guard try JSONEncoder().encode(payload).count <= 524_288 else { throw WorkspaceClientError.capacityExceeded }
        let result = try await workspace.perform(operation, payload: payload, owner: owner)
        try check()
        guard try JSONEncoder().encode(result).count <= 2_097_152 else { throw WorkspaceClientError.capacityExceeded }
        return result
    }

    /// Check before dispatch and after both success and failure. The initial
    /// check remains outside the catch: a preflight failure is never recast as
    /// an uncertain mutation. Callers retain their exact error/cancellation
    /// policy; this helper does not add retry, capability or byte-limit rules.
    static func checkedRequest<Value>(
        check: @MainActor () throws -> Void,
        mapError: @MainActor (any Error) -> any Error = { $0 },
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try check()
        do {
            let value = try await operation()
            try check()
            return value
        } catch {
            try check()
            throw mapError(error)
        }
    }

    func require(_ capability: WorkspaceCapability, profile: String) throws {
        try check()
        guard workspace.capabilities.supports(capability, owner: owner, profileID: profile) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    nonisolated static func profile(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 128)
        guard value != "all", !value.contains("/"), !value.contains("\\"),
              value != ".", value != ".." else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    nonisolated static func identifier(_ value: String, maximum: Int = 160) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: maximum)
        guard !value.contains("/"), !value.contains("\\") else { throw WorkspaceClientError.invalidRequest }
        return value
    }
}
