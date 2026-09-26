import Foundation
import Observation

struct ProjectGitTarget: Equatable, Sendable {
    let agentID: String
    let sessionID: String
    let workspaceID: String
    let workspaceName: String?

    init(
        agentID: String,
        sessionID: String,
        workspaceID: String,
        workspaceName: String? = nil
    ) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

@MainActor
@Observable
final class ProjectChangesStore {
    private let client: any ProjectGitClient
    private let refreshDebounce: Duration

    private(set) var target: ProjectGitTarget?
    private(set) var capabilities: ProjectGitCapabilities?
    private(set) var status: ProjectGitStatus?
    private(set) var diff: ProjectGitDiffPage?
    private(set) var preparedOperation: ProjectGitPreparedOperation?
    private(set) var pendingMutation: ProjectGitMutationRequest?
    private(set) var isLoading = false
    private(set) var isLoadingDiff = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var isNotRepository = false

    private var generation = 0
    private var diffGeneration = 0
    private var scheduledRefresh: Task<Void, Never>?
    private var refreshRequestedWhileLoading = false
    private var isRefreshPending = false

    init(
        client: any ProjectGitClient,
        refreshDebounce: Duration = .milliseconds(250)
    ) {
        self.client = client
        self.refreshDebounce = refreshDebounce
    }

    var railSummary: ProjectChangesRailSummary? {
        guard target != nil else { return nil }
        guard let status else {
            return ProjectChangesRailSummary(
                state: railState,
                fileCount: 0,
                insertions: 0,
                deletions: 0,
                workspaceName: target?.workspaceName,
                isRefreshing: isLoading || isRefreshPending
            )
        }
        return ProjectChangesRailSummary(
            state: railState,
            fileCount: status.changes.files,
            insertions: status.changes.insertions,
            deletions: status.changes.deletions,
            workspaceName: target?.workspaceName,
            branch: status.head.branch,
            isRefreshing: isLoading || isRefreshPending
        )
    }

    func bind(target nextTarget: ProjectGitTarget?, enabled: Bool) async {
        guard enabled, let nextTarget else {
            generation += 1
            reset(target: nil)
            return
        }
        if target != nextTarget {
            generation += 1
            reset(target: nextTarget)
        }
        if isNotRepository { return }
        guard status == nil else { return }
        if isLoading {
            requestRefresh()
            return
        }
        await refresh()
    }

    func refresh() async {
        guard let target else { return }
        generation += 1
        diffGeneration += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
                if refreshRequestedWhileLoading {
                    refreshRequestedWhileLoading = false
                    requestRefresh()
                }
            }
        }
        do {
            let loadedCapabilities = try await client.capabilities(
                agentID: target.agentID,
                sessionID: target.sessionID,
                workspaceID: target.workspaceID
            )
            guard owns(requestGeneration, target) else { return }
            let loadedStatus = try await client.status(
                agentID: target.agentID,
                sessionID: target.sessionID,
                workspaceID: target.workspaceID
            )
            guard owns(requestGeneration, target) else { return }
            capabilities = loadedCapabilities
            status = loadedStatus
            diff = nil
            preparedOperation = nil
            pendingMutation = nil
            isNotRepository = false
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard owns(requestGeneration, target) else { return }
            if isProjectNotRepository(error) {
                capabilities = nil
                status = nil
                diff = nil
                preparedOperation = nil
                pendingMutation = nil
                isNotRepository = true
                errorMessage = nil
            } else {
                isNotRepository = false
                errorMessage = "Project changes could not be loaded from Hermes."
            }
        }
    }

    func requestRefresh() {
        guard target != nil else { return }
        if isLoading {
            refreshRequestedWhileLoading = true
            return
        }
        scheduledRefresh?.cancel()
        isRefreshPending = true
        scheduledRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: refreshDebounce)
            } catch {
                return
            }
            scheduledRefresh = nil
            isRefreshPending = false
            await refresh()
        }
    }

    func loadDiff(
        path: String,
        side: ProjectGitDiffSide,
        offset: Int = 0,
        limit: Int = 300
    ) async {
        guard let target, let status else { return }
        if offset == 0 {
            diffGeneration += 1
        } else {
            guard let existing = diff,
                  existing.path == path,
                  existing.side == side,
                  existing.nextOffset == offset
            else { return }
        }
        let requestGeneration = generation
        let requestDiffGeneration = diffGeneration
        isLoadingDiff = true
        errorMessage = nil
        defer {
            if requestGeneration == generation,
               requestDiffGeneration == diffGeneration {
                isLoadingDiff = false
            }
        }
        do {
            let requestPage: (ProjectGitStatus, Int) async throws -> ProjectGitDiffPage = { snapshot, requestOffset in
                try await self.client.diff(
                    agentID: target.agentID,
                    sessionID: target.sessionID,
                    workspaceID: target.workspaceID,
                    path: path,
                    side: side,
                    statusToken: snapshot.statusToken,
                    offset: requestOffset,
                    limit: limit
                )
            }
            var requestStatus = status
            let page: ProjectGitDiffPage
            do {
                page = try await requestPage(requestStatus, offset)
            } catch {
                guard isStatusChanged(error) else { throw error }
                let refreshedStatus = try await client.status(
                    agentID: target.agentID,
                    sessionID: target.sessionID,
                    workspaceID: target.workspaceID
                )
                guard owns(requestGeneration, target),
                      requestDiffGeneration == diffGeneration
                else { return }
                self.status = refreshedStatus
                if refreshedStatus.statusToken != status.statusToken {
                    preparedOperation = nil
                    pendingMutation = nil
                }
                guard let file = refreshedStatus.files.first(where: { $0.path == path }),
                      file.availableDiffSides.contains(side)
                else {
                    diff = nil
                    errorMessage = "That diff could not be loaded. Refresh the project and try again."
                    return
                }
                requestStatus = refreshedStatus
                page = try await requestPage(requestStatus, 0)
            }
            guard owns(requestGeneration, target),
                  requestDiffGeneration == diffGeneration,
                  self.status?.statusToken == requestStatus.statusToken
            else { return }
            if page.offset > 0,
               let existing = diff,
               existing.path == page.path,
               existing.side == page.side,
               existing.nextOffset == page.offset {
                diff = ProjectGitDiffPage(
                    path: page.path,
                    side: page.side,
                    availability: page.availability,
                    offset: existing.offset,
                    lines: existing.lines + page.lines,
                    nextOffset: page.nextOffset,
                    previewContent: existing.previewContent ?? page.previewContent
                )
            } else {
                diff = page
            }
        } catch is CancellationError {
            return
        } catch {
            guard owns(requestGeneration, target) else { return }
            errorMessage = "That diff could not be loaded. Refresh the project and try again."
        }
    }

    func prepare(_ mutation: ProjectGitMutation) async {
        guard let target, let status, !isMutating else { return }
        let request = ProjectGitMutationRequest(
            agentID: target.agentID,
            sessionID: target.sessionID,
            workspaceID: target.workspaceID,
            statusToken: status.statusToken,
            mutation: mutation
        )
        let requestGeneration = generation
        isMutating = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isMutating = false
            }
        }
        do {
            let prepared = try await client.prepare(request)
            guard owns(requestGeneration, target),
                  self.status?.statusToken == status.statusToken
            else { return }
            pendingMutation = request
            preparedOperation = prepared
        } catch is CancellationError {
            return
        } catch {
            guard owns(requestGeneration, target) else { return }
            errorMessage = "That Git operation could not be prepared. Refresh and try again."
        }
    }

    func executePrepared() async {
        guard let target,
              let pendingMutation,
              let preparedOperation,
              pendingMutation.workspaceID == target.workspaceID,
              !isMutating
        else { return }
        let requestGeneration = generation
        isMutating = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isMutating = false
            }
        }
        do {
            let result = try await client.execute(ProjectGitExecutionRequest(
                mutation: pendingMutation,
                confirmationToken: preparedOperation.confirmationToken,
                idempotencyKey: UUID().uuidString.lowercased()
            ))
            guard owns(requestGeneration, target) else { return }
            status = result.status
            diffGeneration += 1
            diff = nil
            self.pendingMutation = nil
            self.preparedOperation = nil
        } catch is CancellationError {
            return
        } catch {
            guard owns(requestGeneration, target) else { return }
            self.pendingMutation = nil
            self.preparedOperation = nil
            errorMessage = "Hermes could not complete that Git operation. Review the latest status and try again."
        }
    }

    func cancelPreparedOperation() {
        preparedOperation = nil
        pendingMutation = nil
    }

    private func isStatusChanged(_ error: Error) -> Bool {
        guard case .remote(.conflict, let code, _) = error as? BighelpLinkWorkspaceClientError else {
            return false
        }
        return code == "status_changed"
    }

    private var railState: ProjectChangesRailSummary.State {
        if errorMessage != nil { return .failed }
        if isNotRepository { return .unavailable }
        guard let status else { return .loading }
        return status.isDirty ? .dirty : .clean
    }

    private func isProjectNotRepository(_ error: Error) -> Bool {
        guard let workspaceError = error as? BighelpLinkWorkspaceClientError,
              case .remote(_, let code, _) = workspaceError
        else { return false }
        return code == "project_not_repository"
    }

    private func owns(_ requestGeneration: Int, _ requestTarget: ProjectGitTarget) -> Bool {
        requestGeneration == generation && target == requestTarget
    }

    private func reset(target: ProjectGitTarget?) {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        refreshRequestedWhileLoading = false
        isRefreshPending = false
        diffGeneration += 1
        self.target = target
        capabilities = nil
        status = nil
        diff = nil
        preparedOperation = nil
        pendingMutation = nil
        isLoading = false
        isLoadingDiff = false
        isMutating = false
        errorMessage = nil
        isNotRepository = false
    }
}
