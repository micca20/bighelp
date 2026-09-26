import Foundation

@MainActor
final class LoopdyPluginUpdateClient: PluginUpdateClient {
    private let workspace: LoopdyLinkWorkspaceClient
    private let isCurrent: @MainActor () -> Bool

    init(workspace: LoopdyLinkWorkspaceClient, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.workspace = workspace
        self.isCurrent = isCurrent
    }

    func start(operationID: String) async throws -> PluginUpdateStatus {
        guard Self.validOperationID(operationID) else { throw PluginUpdateClientError.invalidResponse }
        return try await perform(.pluginUpdateStart, payload: [
            "operation_id": .string(operationID), "confirm_restart": .boolean(true),
        ])
    }

    func status(operationID: String?) async throws -> PluginUpdateStatus {
        if let operationID, !Self.validOperationID(operationID) { throw PluginUpdateClientError.invalidResponse }
        return try await perform(.pluginUpdateStatus, payload: operationID.map { ["operation_id": .string($0)] } ?? [:])
    }

    private func perform(_ operation: LoopdyLinkWorkspaceOperation, payload: [String: LoopdyJSONValue]) async throws -> PluginUpdateStatus {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        do {
            let value = try await workspace.perform(operation, payload: payload)
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            return try PluginUpdateStatus.decode(value)
        } catch LoopdyLinkLiveSocketError.hostUpdateRequired {
            throw PluginUpdateClientError.unsupported
        }
    }

    private static func validOperationID(_ id: String) -> Bool {
        (16...128).contains(id.count) && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}

extension PluginUpdateStatus {
    static func decode(_ payload: [String: LoopdyJSONValue]) throws -> Self {
        func text(_ key: String, maximum: Int) throws -> String? {
            guard let value = payload[key], value != .null else { return nil }
            guard let string = value.string, !string.isEmpty, string.count <= maximum,
                  !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PluginUpdateClientError.invalidResponse
            }
            return string
        }
        guard let phaseValue = payload["phase"]?.string, let phase = Phase(rawValue: phaseValue) else {
            throw PluginUpdateClientError.invalidResponse
        }
        let operationID = try text("operation_id", maximum: 128)
        if let operationID {
            guard (16...128).contains(operationID.count), operationID.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }) else { throw PluginUpdateClientError.invalidResponse }
        } else if phase != .idle { throw PluginUpdateClientError.invalidResponse }
        let target = try text("target_revision", maximum: 40)
        let active = try text("active_revision", maximum: 40)
        for revision in [target, active].compactMap({ $0 }) {
            guard validRevision(revision) else { throw PluginUpdateClientError.invalidResponse }
        }
        let result = Self(operationID: operationID, phase: phase,
                          targetRevision: target, activeRevision: active,
                          runtimeID: try text("runtime_id", maximum: 128),
                          message: try text("message", maximum: 512) ?? phase.title)
        if phase == .complete || phase == .upToDate {
            guard result.provesCompletion else { throw PluginUpdateClientError.invalidResponse }
        }
        return result
    }
}
