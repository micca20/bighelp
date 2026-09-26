import Foundation

@MainActor
final class WorkspaceSessionControlProxy: SessionRuntimeControlConfirming, SessionRuntimeControlSupporting {
    private let box: WorkspaceOwnedClientBox<DirectHermesSessionControlClient>

    init(box: WorkspaceOwnedClientBox<DirectHermesSessionControlClient>) { self.box = box }

    func cachedModelProviders(agentID: String) -> [LoopdyLinkModelProvider] {
        (try? box.value().cachedModelProviders(agentID: agentID)) ?? []
    }

    func openPicker(_ request: LoopdyLinkPickerOpenRequest) async throws -> LoopdyLinkPicker {
        try await box.value().openPicker(request)
    }

    func selectPicker(_ selection: LoopdyLinkPickerSelection) async throws -> LoopdyLinkPickerResult {
        try await box.value().selectPicker(selection)
    }

    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport {
        guard box.hasCurrentCapabilities else {
            return SessionRuntimeControlSupport(
                modelUnavailableReason: "Checking what this host supports.",
                reasoningUnavailableReason: "Checking what this host supports."
            )
        }
        do { return try box.value().selectionSupport(sessionID: sessionID, agentID: agentID) }
        catch {
            return SessionRuntimeControlSupport(
                modelUnavailableReason: "Connect to this host before changing this session's model.",
                reasoningUnavailableReason: "Reconnect to this host before changing this session's reasoning level."
            )
        }
    }

    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> LoopdyLinkPickerResult {
        try await box.value().confirmPicker(confirmation)
    }

    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation) {
        // A replaced owner already fences the old token. Cancellation never
        // opens another connection or dispatches a native mutation.
        guard let client = try? box.value() else { return }
        client.cancelPickerConfirmation(confirmation)
    }
}
