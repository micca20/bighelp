import Foundation

/// Local picker identity, never a Link wire coordinate.
struct NativeSessionRuntimePickerCoordinate: Equatable, Sendable {
    let workspace: WorkspaceSessionCoordinate

    init(_ coordinate: WorkspaceSessionCoordinate) throws {
        let identity = try DirectHermesSessionIdentity.decode(coordinate.sessionID, owner: coordinate.owner)
        guard DirectHermesSessionValidation.same(identity.profileID, coordinate.profileID),
              coordinate.runtimeSessionID != nil, coordinate.storedSessionID != nil else {
            throw WorkspaceClientError.invalidRequest
        }
        workspace = coordinate
    }
}

struct SessionRuntimeControlSupport: Equatable, Sendable {
    var modelUnavailableReason: String?
    var reasoningUnavailableReason: String?

    static let available = SessionRuntimeControlSupport()
    static let nativeReasoningReadOnly =
        "This Hermes host does not expose a safe current-chat reasoning change or reset. The current value is read-only."
}

struct SessionRuntimeModelConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let selection: LoopdyLinkPickerSelection
    let coordinate: WorkspaceSessionCoordinate
    let message: String
}

struct SessionRuntimeModelConfirmationRequired: Error, Equatable, Sendable {
    let confirmation: SessionRuntimeModelConfirmation
}

struct SessionRuntimeModelDeferred: Error, Equatable, Sendable {
    let selection: LoopdyLinkPickerSelection
    let coordinate: WorkspaceSessionCoordinate
    let message: String
}

@MainActor
protocol SessionRuntimeControlSupporting: AnyObject {
    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport
    func cachedModelProviders(agentID: String) -> [LoopdyLinkModelProvider]
}

extension SessionRuntimeControlSupporting {
    func cachedModelProviders(agentID: String) -> [LoopdyLinkModelProvider] { [] }
}

@MainActor
protocol SessionRuntimeControlConfirming: LoopdyLinkSessionControlMessaging {
    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> LoopdyLinkPickerResult
    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation)
}
