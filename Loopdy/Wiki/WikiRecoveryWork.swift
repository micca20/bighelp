import SwiftUI
import Observation

/// Owns recovery RPCs independently of the initial-create task. Cancellation
/// retains the journal and prevents a late admission from continuing to commit.
@MainActor
@Observable
final class WikiRecoveryWork {
    var failure: String?
    private(set) var isWorking = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ticket = UUID()

    func cancel() {
        task?.cancel()
        task = nil
        ticket = UUID()
        isWorking = false
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase != .active { cancel() }
    }

    func run(store: WikiStore, _ work: @escaping @MainActor () async throws -> Void) {
        cancel()
        failure = nil
        isWorking = true
        let owner = store.owner
        let currentTicket = ticket
        task = Task { @MainActor in
            defer { if ticket == currentTicket { task = nil; isWorking = false } }
            do {
                try Task.checkCancellation()
                try await work()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, ticket == currentTicket, store.owner == owner else { return }
                failure = WikiError.saveMessage(error)
            }
        }
    }
}
