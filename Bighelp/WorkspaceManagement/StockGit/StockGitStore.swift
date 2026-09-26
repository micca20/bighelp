import Foundation
import Observation

@MainActor
@Observable
final class StockGitStore {
    let target: StockGitProjectTarget

    private(set) var snapshot: StockGitSnapshot?
    private(set) var diff: StockGitDiff?
    private(set) var preparedAction: StockGitPreparedAction?
    private(set) var isLoading = false
    private(set) var isLoadingDiff = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var selectedPaths: Set<String> = []
    var reviewScope: StockGitReviewScope = .uncommitted

    @ObservationIgnored private let client: any StockGitManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        target: StockGitProjectTarget,
        client: any StockGitManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.target = target
        self.client = client
        self.isCurrent = isCurrent
    }

    var canAct: Bool { isCurrent() && !isLoading && !isLoadingDiff && !isSaving }

    func load() async {
        guard isCurrent(), !isSaving else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.snapshot(for: target, scope: reviewScope)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            snapshot = value
            selectedPaths.formIntersection(value.status.files.map(\.path))
            if let diff, !value.review.files.contains(where: { $0.path == diff.path }) { self.diff = nil }
        } catch is CancellationError {
        } catch {
            guard generation == request, isCurrent() else { return }
            errorMessage = message(error)
        }
    }

    func selectScope(_ scope: StockGitReviewScope) async {
        guard reviewScope != scope else { return }
        reviewScope = scope
        selectedPaths.removeAll()
        diff = nil
        await load()
    }

    func toggle(_ path: String) {
        if selectedPaths.contains(path) { selectedPaths.remove(path) }
        else { selectedPaths.insert(path) }
    }

    func clearSelection() { selectedPaths.removeAll() }

    func closeDiff() { diff = nil }

    func loadDiff(path: String, staged: Bool) async {
        guard canAct else { return }
        let request = generation
        isLoadingDiff = true
        errorMessage = nil
        defer { if generation == request { isLoadingDiff = false } }
        do {
            let value = try await client.diff(for: target, file: path, scope: reviewScope, staged: staged)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            diff = value
        } catch is CancellationError {
        } catch {
            guard generation == request, isCurrent() else { return }
            errorMessage = message(error)
        }
    }

    func review(_ action: StockGitAction) {
        guard canAct else { return }
        do {
            preparedAction = try client.prepare(action, target: target)
            errorMessage = nil
        } catch {
            errorMessage = message(error)
        }
    }

    func reviewSelectedStage() {
        review(.stage(paths: selectedPaths.sorted()))
    }

    func reviewSelectedUnstage() {
        review(.unstage(paths: selectedPaths.sorted()))
    }

    func reviewSelectedRevert() {
        review(.revert(paths: selectedPaths.sorted()))
    }

    func confirmPreparedAction() async {
        guard canAct, let preparedAction else { return }
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }
        do {
            let result = try await client.execute(preparedAction, confirmationToken: preparedAction.confirmationToken)
            guard isCurrent(), !Task.isCancelled else { return }
            snapshot = result.snapshot
            selectedPaths.removeAll()
            diff = nil
            self.preparedAction = nil
            successMessage = success(for: result)
        } catch is CancellationError {
            guard isCurrent() else { return }
            self.preparedAction = nil
            errorMessage = "The operation was interrupted. The outcome may be unknown; refresh before retrying."
        } catch {
            guard isCurrent() else { return }
            self.preparedAction = nil
            errorMessage = message(error)
        }
    }

    func cancelPreparedAction() { preparedAction = nil }

    func retire() {
        generation = UUID()
        snapshot = nil
        diff = nil
        preparedAction = nil
        selectedPaths.removeAll()
        errorMessage = nil
        successMessage = nil
    }

    private func success(for result: StockGitActionResult) -> String {
        if let url = result.pullRequestURL { return "Pull request created: \(url.absoluteString)" }
        return "Hermes confirmed the Git operation and refreshed the repository state."
    }

    private func message(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let value = localized.errorDescription { return value }
        return "Hermes could not complete that Git request. Refresh the repository before trying again."
    }
}
