import Foundation

/// Parent-owned sheet input. Recreate it when the exact connection generation
/// changes, but keep `clientIdentity` as the sheet view identity so the controls
/// refresh their action facade rather than silently retaining a stale one.
struct NativeSessionControlsPresentation {
    let client: DirectHermesConversationClient
    let connectionGeneration: UUID
    let isSessionRunning: Bool
    let onReconcileHistory: NativeSessionHistoryReconciliationHandler

    var clientIdentity: ObjectIdentifier { ObjectIdentifier(client) }

    init(
        client: DirectHermesConversationClient,
        connectionGeneration: UUID,
        isSessionRunning: Bool,
        onReconcileHistory: @escaping NativeSessionHistoryReconciliationHandler
    ) {
        self.client = client
        self.connectionGeneration = connectionGeneration
        self.isSessionRunning = isSessionRunning
        self.onReconcileHistory = onReconcileHistory
    }
}
