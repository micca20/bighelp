import Foundation
import Observation

@MainActor
final class ReferenceGitHubAdapter {
    static let providerID = "github-reference-v1"
    private let store: GitHubConnectionStore
    private let ownerID: String
    private let expectedHubAccountID: String
    private let credentialID: String
    private let userID: Int
    private let generation: UUID
    private let ownerIsCurrent: (ReferenceHubOwner) -> Bool
    private let lease = ReferenceAdapterLease()
    private var boundOwner: ReferenceHubOwner?
    // Search observations only, never send-time authorization or inclusion scope.
    private var resources: [String: GitHubResource] = [:]
    private var order: [String] = []

    init(store: GitHubConnectionStore, ownerID: String, credentialID: String, userID: Int,
         generation: UUID, expectedHubAccountID: String? = nil,
         ownerIsCurrent: @escaping (ReferenceHubOwner) -> Bool) {
        self.store = store
        self.ownerID = ownerID
        self.expectedHubAccountID = expectedHubAccountID ?? ownerID
        self.credentialID = credentialID
        self.userID = userID
        self.generation = generation
        self.ownerIsCurrent = ownerIsCurrent
        let lease = self.lease
        withObservationTracking {
            _ = store.ownerID
            _ = store.generation
            // Credential replacement/disconnect changes generation. Token rotation
            // may republish an equal summary without changing this adapter's authority.
        } onChange: { lease.invalidate() }
    }

    var provider: ReferenceHubProvider {
        ReferenceHubProvider(id: Self.providerID, label: "GitHub", categories: [.repos, .issues, .prs],
            search: { try await self.search(owner: $0, category: $1, query: $2) },
            resolve: { try await self.resolve(owner: $0, result: $1) },
            revalidate: { try await self.revalidate(owner: $0, snapshot: $1) })
    }

    private func check(_ owner: ReferenceHubOwner) throws {
        try Task.checkCancellation()
        guard lease.isValid, ownerIsCurrent(owner), owner.accountID == expectedHubAccountID,
              store.ownerID == ownerID, store.generation == generation,
              store.selectedCredential?.id == credentialID,
              store.selectedCredential?.identity.id == userID,
              boundOwner == nil || boundOwner == owner else {
            resources.removeAll(); order.removeAll()
            throw ReferenceAdapterError.authorityChanged
        }
        boundOwner = owner
    }

    private func owned<T: Sendable>(_ owner: ReferenceHubOwner,
                                    allowPartialFailure: Bool = false,
                                    _ operation: @MainActor () async throws -> T) async throws -> T {
        try check(owner)
        do {
            let result = try await operation()
            try check(owner)
            return result
        } catch {
            try check(owner)
            if error is CancellationError { throw error }
            if allowPartialFailure,
               let githubError = error as? GitHubError, githubError == .networkUnavailable {
                throw ReferenceAdapterError.partialFailure
            }
            throw ReferenceAdapterError.unavailable
        }
    }

    private func search(owner: ReferenceHubOwner, category: ReferenceCategory,
                        query: String) async throws -> ReferenceHubSearchPage {
        try check(owner)
        let kinds: [GitHubResourceKind]
        switch category {
        case .all: kinds = [.repository, .issue, .pullRequest]
        case .repos: kinds = [.repository]
        case .issues: kinds = [.issue]
        case .prs: kinds = [.pullRequest]
        default: return ReferenceHubSearchPage(results: [], isPartial: false)
        }
        var results: [ReferenceHubResult] = []
        var partial = false
        for kind in kinds {
            let page: GitHubResourcePage
            do {
                page = try await owned(owner, allowPartialFailure: category == .all) {
                    try await self.store.search(kind: kind, query: query, userID: self.userID)
                }
            } catch ReferenceAdapterError.partialFailure {
                guard category == .all else { throw ReferenceAdapterError.partialFailure }
                partial = true
                continue
            }
            try check(owner)
            partial = partial || page.isPartial || page.retryAfter != nil
            let visibleLimit = category == .all ? 33 : 100
            for resource in page.resources.prefix(visibleLimit) {
                guard resource.kind == kind else { throw ReferenceAdapterError.invalidSource }
                remember(resource.withoutDescription)
                results.append(row(resource, cached: page.isCached))
            }
            partial = partial || page.resources.count > visibleLimit
        }
        return ReferenceHubSearchPage(results: Array(results.prefix(100)),
                                      isPartial: partial || results.count > 100)
    }

    private func remember(_ resource: GitHubResource) {
        if resources[resource.id] == nil { order.append(resource.id) }
        resources[resource.id] = resource
        while order.count > 300 { resources.removeValue(forKey: order.removeFirst()) }
    }

    private func row(_ resource: GitHubResource, cached: Bool = false) -> ReferenceHubResult {
        let category: ReferenceCategory
        switch resource.kind {
        case .repository: category = .repos
        case .issue: category = .issues
        case .pullRequest: category = .prs
        }
        let location = resource.repository + (resource.number.map { " #\($0)" } ?? "")
        return ReferenceHubResult(resourceID: resource.id, providerID: Self.providerID, category: category,
            title: resource.title, subtitle: location,
            state: resource.state + (resource.isDraft ? " · draft" : "") + (resource.isPrivate ? " · private" : ""),
            isCached: cached)
    }

    private func resolve(owner: ReferenceHubOwner, result: ReferenceHubResult) async throws -> ReferenceHubPreview {
        try check(owner)
        guard result.providerID == Self.providerID, let previous = resources[result.resourceID],
              row(previous).category == result.category else { throw ReferenceAdapterError.expiredResult }
        // One exact resolved read supplies inspectable options. Merely previewing
        // never selects the description; metadata-only remains the first choice.
        let current = try await owned(owner) {
            try await self.store.revalidate(previous, userID: self.userID, includeDescription: true)
        }
        try check(owner)
        let metadata = try ReferenceGitHubAdapterSnapshot.make(current, includesDescription: false)
        let description = try ReferenceGitHubAdapterSnapshot.make(current, includesDescription: true)
        remember(current.withoutDescription)
        return ReferenceHubPreview(result: result, sourceKindLabel: "GitHub metadata (not a checkout or diff)",
            options: [
                ReferenceContentOption(id: "metadata", label: "Metadata only — description excluded", snapshot: metadata),
                ReferenceContentOption(id: "description", label: "Metadata and description" +
                    (description.isTruncated ? " — truncated" : ""), snapshot: description)
            ])
    }

    private func revalidate(owner: ReferenceHubOwner, snapshot: ReferenceSnapshot) async throws -> ReferenceSnapshot {
        try check(owner)
        // Parse scope from the frozen content, including a cold-restored draft.
        // No ephemeral option map or cached successful check can authorize Send.
        let selected = try ReferenceGitHubAdapterSnapshot.selection(snapshot)
        let fresh = try await owned(owner) {
            try await self.store.lookup(kind: selected.kind, repository: selected.repository,
                number: selected.number, userID: self.userID, includeDescription: selected.includesDescription)
        }
        try check(owner)
        guard fresh.isResolved, fresh.nodeID == selected.nodeID,
              fresh.repositoryID == selected.repositoryID,
              fresh.resourceID == selected.resourceID,
              fresh.kind == selected.kind, fresh.number == selected.number else {
            throw ReferenceAdapterError.invalidSource
        }
        return try ReferenceGitHubAdapterSnapshot.make(fresh, includesDescription: selected.includesDescription)
    }
}
