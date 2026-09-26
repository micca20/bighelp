import Observation

/// Owned by the exact draft model, so reconstructing an editor cannot lose a
/// native proposal that has not yet been represented safely as Markdown.
@MainActor
@Observable
final class RichDraftRecoveryStore {
    private(set) var hasUnexportedChanges = false
    @ObservationIgnored private var retainedState: Any?

    @available(iOS 26.0, *)
    var state: RichDraftRecoveryState? { retainedState as? RichDraftRecoveryState }

    @available(iOS 26.0, *)
    func update(_ state: RichDraftRecoveryState) {
        retainedState = state.hasUnexportedChanges ? state : nil
        hasUnexportedChanges = state.hasUnexportedChanges
    }

    func discard() {
        retainedState = nil
        hasUnexportedChanges = false
    }
}
