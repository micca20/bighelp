import Foundation
import Observation

@MainActor
@Observable
final class ProjectLifecycleStore {
    let hostName: String
    let profileID: String

    private(set) var overview: HermesProjectOverview?
    private(set) var detail: HermesProjectDetail?
    private(set) var preparedAction: HermesProjectPreparedAction?
    private(set) var isLoading = false
    private(set) var isLoadingDetail = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?

    @ObservationIgnored private let client: any HermesProjectLifecycleManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        profileID: String,
        client: any HermesProjectLifecycleManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var canMutate: Bool { isCurrent() && !isLoading && !isLoadingDetail && !isSaving }

    func load() async {
        guard isCurrent(), !isSaving else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.overview(profileID: profileID)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            overview = value
            if let id = detail?.project.id, value.registeredProjects.contains(where: { $0.id == id }) {
                await loadDetail(projectID: id)
            } else {
                detail = nil
            }
        } catch is CancellationError {
        } catch {
            guard generation == request, isCurrent() else { return }
            errorMessage = message(error)
        }
    }

    func loadDetail(projectID: String) async {
        guard isCurrent(), !isSaving else { return }
        let request = generation
        isLoadingDetail = true
        errorMessage = nil
        defer { if generation == request { isLoadingDetail = false } }
        do {
            let value = try await client.detail(projectID: projectID, profileID: profileID)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            detail = value
        } catch is CancellationError {
        } catch {
            guard generation == request, isCurrent() else { return }
            errorMessage = message(error)
        }
    }

    func review(_ action: HermesProjectLifecycleAction) {
        guard canMutate else { return }
        do {
            preparedAction = try client.prepare(action, profileID: profileID)
            errorMessage = nil
        } catch {
            errorMessage = message(error)
        }
    }

    func confirmPreparedAction() async {
        guard canMutate, let preparedAction else { return }
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }
        do {
            let refreshed = try await client.execute(
                preparedAction,
                confirmationToken: preparedAction.confirmationToken
            )
            guard isCurrent(), !Task.isCancelled else { return }
            overview = refreshed
            self.preparedAction = nil
            successMessage = "Hermes confirmed the project change."
            if let projectID = detail?.project.id,
               refreshed.registeredProjects.contains(where: { $0.id == projectID }) {
                await loadDetail(projectID: projectID)
            } else {
                detail = nil
            }
        } catch is CancellationError {
            guard isCurrent() else { return }
            self.preparedAction = nil
            errorMessage = "The request was interrupted. Refresh before trying it again."
        } catch {
            guard isCurrent() else { return }
            self.preparedAction = nil
            errorMessage = message(error)
        }
    }

    func cancelPreparedAction() { preparedAction = nil }

    /// Refreshes the same authoritative Project overview used by lifecycle CRUD
    /// immediately before stock Git resolves or revalidates a target. No path is
    /// accepted from the caller; target resolution selects from this snapshot.
    func refreshStockGitAuthority() async throws {
        guard isCurrent(), !isSaving else { throw WorkspaceClientError.ownerChanged }
        let value = try await client.overview(profileID: profileID)
        try Task.checkCancellation()
        guard isCurrent(), !isSaving, same(value.profileID, profileID) else {
            throw WorkspaceClientError.ownerChanged
        }
        overview = value
        if let id = detail?.project.id,
           !value.registeredProjects.contains(where: { same($0.id, id) }) {
            detail = nil
        }
    }

    /// Resolves only the unique primary folder from the current registered
    /// Project snapshot. Automatic/Home nodes and arbitrary caller paths never
    /// enter this boundary.
    func stockGitTarget(projectID: String) -> StockGitProjectTarget? {
        guard isCurrent(), let overview, same(overview.profileID, profileID),
              let project = overview.registeredProjects.first(where: {
                  same($0.id, projectID) && !$0.isArchived
              }) else { return nil }
        let primaryFolders = project.folders.filter(\.isPrimary)
        guard primaryFolders.count == 1, let primary = primaryFolders.first else { return nil }
        return StockGitProjectTarget(
            profileID: overview.profileID,
            projectID: project.id,
            cwd: primary.path,
            projectName: project.name
        )
    }

    func ownsStockGitTarget(_ target: StockGitProjectTarget) -> Bool {
        guard same(target.profileID, profileID),
              let current = stockGitTarget(projectID: target.projectID) else { return false }
        return same(current.profileID, target.profileID)
            && same(current.projectID, target.projectID)
            && same(current.cwd, target.cwd)
            && same(current.projectName, target.projectName)
    }

    func retire() {
        generation = UUID()
        overview = nil
        detail = nil
        preparedAction = nil
        errorMessage = nil
        successMessage = nil
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private func message(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let value = localized.errorDescription { return value }
        return "Hermes could not complete that project request. Refresh to inspect the current state."
    }
}
