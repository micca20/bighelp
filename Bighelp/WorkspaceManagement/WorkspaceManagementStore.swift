import Foundation
import Observation

@MainActor @Observable
final class WorkspaceManagementStore {
    let hostName: String
    let profileName: String
    private(set) var content: WorkspaceManagementContent?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var filePreview: WorkspaceFilePreview?
    private(set) var isPreviewing = false
    private(set) var destination: WorkspaceDestination?
    private(set) var visibleLimit = 50
    private(set) var isRetired = false
    var search = ""
    var showsArchived = false
    var review: WorkspaceManagementMutation?

    @ObservationIgnored private let client: any WorkspaceManagementClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(hostName: String, profileName: String, client: any WorkspaceManagementClient, isCurrent: @escaping @MainActor () -> Bool) {
        self.hostName = hostName
        self.profileName = profileName
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }

    var canEdit: Bool {
        guard ownsScope, !isLoading, !isSaving, errorMessage == nil, let destination else { return false }
        return client.editableDestinations.contains(destination)
    }

    func retire() {
        isRetired = true
        generation = UUID()
        content = nil
        filePreview = nil
        review = nil
        search = ""
        errorMessage = nil
        successMessage = nil
        isLoading = false
        isSaving = false
        isPreviewing = false
    }

    func load(_ destination: WorkspaceDestination, path: String? = nil, root: String? = nil) async {
        guard ownsScope, !Task.isCancelled, !isSaving else { return }
        let request = UUID()
        generation = request
        if self.destination != destination {
            content = nil
            search = ""
            review = nil
        }
        self.destination = destination
        isLoading = true
        errorMessage = nil
        successMessage = nil
        filePreview = nil
        isPreviewing = false
        visibleLimit = 50
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.load(destination, path: path, root: root)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            content = value
        } catch is CancellationError {
            // Navigation cancellation does not become a visible host failure.
        } catch {
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func refresh() async {
        guard let destination else { return }
        if case .files(let listing) = content {
            await load(destination, path: listing.path, root: listing.root)
        } else {
            await load(destination)
        }
    }

    func loadMore() { visibleLimit += 50 }

    func loadMoreFiles() async {
        guard ownsScope, !isLoading, !isSaving, case .files(let listing) = content,
              listing.nextPage != nil else { return }
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let next = try await client.nextFilePage(listing)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            content = .files(next)
            visibleLimit = next.entries.count
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func matches(_ strings: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || strings.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func confirmReview(expected: WorkspaceManagementMutation? = nil) async {
        guard canEdit, let mutation = review, mutation.destination == destination else { return }
        if let expected, mutation != expected {
            review = nil
            errorMessage = "The proposed change changed during review. Review it again before confirming."
            return
        }
        review = nil
        isSaving = true
        errorMessage = nil
        successMessage = nil
        let request = generation
        defer { if generation == request { isSaving = false } }
        do {
            try await client.apply(mutation)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            guard let destination else { return }
            let value = try await client.load(destination, path: nil, root: nil)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            content = value
            successMessage = "Hermes confirmed the change."
        } catch is CancellationError {
            guard ownsScope, generation == request else { return }
            errorMessage = "The operation was interrupted. Refresh to confirm its current state before trying again."
        } catch {
            guard ownsScope, generation == request else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func preview(_ entry: WorkspaceFileListing.Entry, root: String) async {
        guard ownsScope, !isPreviewing, !entry.isDirectory else { return }
        guard let size = entry.size, size >= 0, size <= WorkspaceManagementDecoder.maximumDocumentBytes else {
            errorMessage = WorkspaceManagementError.filePreviewUnavailable.localizedDescription
            return
        }
        let request = generation
        isPreviewing = true
        errorMessage = nil
        defer { if generation == request { isPreviewing = false } }
        do {
            let result = try await client.previewFile(path: entry.path, root: root)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            filePreview = result
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func closePreview() { filePreview = nil }

    private static func message(for error: any Error) -> String {
        if let error = error as? WorkspaceManagementError { return error.localizedDescription }
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        return "This host could not complete the workspace request. Check the connection and retry. No successful change has been confirmed."
    }
}
