import Foundation
import Observation

/// In-memory display observations shared by every chat using the selected credential.
/// The connection store invalidates this entire cache at its account/credential boundary.
/// These pages never authorize a preview or send. There is no timer or offscreen polling.
@MainActor @Observable
final class GitHubDiscoveryCache {
    enum Key: Hashable {
        case catalog
        case search(GitHubResourceKind, String, [String]?)
    }
    private struct Entry {
        let page: GitHubResourcePage?
        let failure: GitHubError?
        let checkedAt: Date
        let nextRefreshAt: Date
    }
    private(set) var lastCheckedAt: Date?
    private(set) var revision = 0
    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var flights: [Key: Task<GitHubResourcePage, any Error>] = [:]
    @ObservationIgnored private var generation = UUID()

    func invalidate() {
        generation = UUID()
        for task in flights.values { task.cancel() }
        flights.removeAll()
        entries.removeAll()
        lastCheckedAt = nil
        revision &+= 1
    }

    func page(for key: Key, clock: any GitHubClock, staleWhileRevalidate: Bool = true,
              load: @escaping @MainActor @Sendable () async throws -> GitHubResourcePage) async throws -> GitHubResourcePage {
        try Task.checkCancellation()
        let lease = generation
        let now = clock.now()
        let entry = entries[key]
        let cached = entry?.page.flatMap { page in
            (0..<900).contains(now.timeIntervalSince(page.fetchedAt)) ? page : nil
        }
        if let entry, now < entry.nextRefreshAt {
            if let cached { return cached.discoveryCopy(retryAfter: entry.failure?.retryDate, failed: entry.failure != nil) }
            throw entry.failure ?? GitHubError.networkUnavailable
        }
        let task: Task<GitHubResourcePage, any Error>
        if let running = flights[key] { task = running }
        else {
            // Bound both retained queries and outstanding work, independently of drawer lifetime.
            guard flights.count < 8 else { throw GitHubError.throttled(until: now.addingTimeInterval(60)) }
            task = Task { [self] in
                defer { if generation == lease { flights[key] = nil } }
                do {
                    let result = try await load()
                    try Task.checkCancellation()
                    guard generation == lease else { throw GitHubError.cancelled }
                    let checkedAt = result.isCached ? result.fetchedAt : clock.now()
                    // A throttled empty response is not evidence that previous rows disappeared.
                    let retained = result.retryAfter != nil && result.resources.isEmpty ? (cached ?? result) : result
                    publish(Entry(page: retained, failure: result.retryAfter.map { .throttled(until: $0) },
                                  checkedAt: checkedAt,
                                  // A derived snapshot keeps its observation age, but a completed
                                  // load always gets a minimum attempt cooldown. Cache hits above
                                  // neither publish nor move this deadline (or the catalog's).
                                  nextRefreshAt: max(clock.now().addingTimeInterval(60), result.retryAfter ?? .distantPast)), for: key)
                    return result
                } catch {
                    guard generation == lease, !Task.isCancelled else { throw GitHubError.cancelled }
                    let failure = GitHubError.safe(error)
                    if failure == .cancelled { throw failure }
                    let checkedAt = clock.now()
                    let mayRetain = failure == .networkUnavailable || failure.retryDate != nil
                    publish(Entry(page: mayRetain ? cached : nil, failure: failure, checkedAt: checkedAt,
                                  nextRefreshAt: max(checkedAt.addingTimeInterval(60), failure.retryDate ?? .distantPast)), for: key)
                    throw failure
                }
            }
            flights[key] = task
        }
        // Only a bounded display snapshot may outlive its freshness window. A waiter
        // cancelling does not cancel shared work; invalidating its credential always does.
        if staleWhileRevalidate, let cached {
            return cached.discoveryCopy(retryAfter: entry?.failure?.retryDate, failed: entry?.failure != nil)
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard generation == lease else { throw GitHubError.cancelled }
        return result
    }

    private func publish(_ entry: Entry, for key: Key) {
        entries[key] = entry
        if entries.count > 64, let oldest = entries.filter({ $0.key != key && flights[$0.key] == nil })
            .min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key { entries[oldest] = nil }
        lastCheckedAt = max(lastCheckedAt ?? .distantPast, entry.checkedAt)
        revision &+= 1
    }
}

private extension GitHubError {
    var retryDate: Date? {
        if case .throttled(let until) = self { return until }
        return nil
    }
}

private extension GitHubResourcePage {
    func discoveryCopy(retryAfter: Date?, failed: Bool) -> GitHubResourcePage {
        let deadline = [self.retryAfter, retryAfter].compactMap { $0 }.max()
        return GitHubResourcePage(resources: resources, isPartial: isPartial || failed || deadline != nil,
                                  retryAfter: deadline, fetchedAt: fetchedAt, isCached: true)
    }
}

extension GitHubConnectionStore {
    /// Explicit discovery only. Device credentials use installation selection; PATs
    /// use /user/repos and GitHub’s actual token/resource-owner/policy boundary.
    func repositories(userID: Int, forceRefresh: Bool = false) async throws -> GitHubResourcePage {
        let lease = try discoveryLease(userID: userID)
        let result = try await discoveryCache.page(for: .catalog, clock: clock, staleWhileRevalidate: !forceRefresh) {
            try await self.read(userID: userID) { lease in try await self.fetchCatalog(lease: lease) }
        }
        try check(lease)
        return result
    }

    /// Separate issue/PR title searches; an empty term lists recently updated items.
    /// repositoryNames=nil means the authorized catalog, bounded to 20 repositories;
    /// callers should pass a narrower explicit scope for large accounts.
    func search(
        kind: GitHubResourceKind, query: String, userID: Int,
        repositoryNames: [String]? = nil
    ) async throws -> GitHubResourcePage {
        let lease = try discoveryLease(userID: userID)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateDiscoveryInput(term: term, repositoryNames: repositoryNames)
        // Normalize the key only after validation, before any cache hit can return.
        let scope = repositoryNames.map { Array(Set($0.map { $0.lowercased() })).sorted() }
        let result = try await discoveryCache.page(for: .search(kind, term, scope), clock: clock) {
            try await self.read(userID: userID) { lease in
                try await self.searchUncached(kind: kind, query: query, repositoryNames: repositoryNames, lease: lease)
            }
        }
        try check(lease)
        return result
    }

    /// One-shot warming on authentication/service availability, never a repeating poll.
    func warmReferences() async {
        guard let userID = selectedCredential?.identity.id else { return }
        let lease = generation
        for kind in GitHubResourceKind.allCases {
            guard generation == lease, !Task.isCancelled else { return }
            _ = try? await search(kind: kind, query: "", userID: userID)
        }
    }

    private func discoveryLease(userID: Int) throws -> UUID {
        try check(generation)
        guard case .connected = state, selectedIdentity?.id == userID, selectedCredential != nil else {
            throw GitHubError.accountNotConfirmed
        }
        return generation
    }

    private func validateDiscoveryInput(term: String, repositoryNames: [String]?) throws {
        guard term.utf8.count <= 120, GitHubContent.safe(term) == term, !term.contains("\""), !term.contains("\\"),
              !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GitHubError.invalidInput }
        if let repositoryNames {
            guard repositoryNames.count <= 100, repositoryNames.allSatisfy(GitHubURLPolicy.repositoryName) else {
                throw GitHubError.invalidInput
            }
        }
    }

    private func searchUncached(kind: GitHubResourceKind, query: String, repositoryNames: [String]?,
                                lease: UUID) async throws -> GitHubResourcePage {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = try await self.catalog(lease: lease, forceRefresh: false)
        let requested = repositoryNames.map { Set($0.map { $0.lowercased() }) }
        let scoped = catalog.resources.filter { requested?.contains($0.repository.lowercased()) ?? true }
        var partial = catalog.isPartial || (requested.map { $0.count != scoped.count } ?? false)
        if kind == .repository {
            let matches = scoped.filter { term.isEmpty || $0.repository.localizedCaseInsensitiveContains(term) }
            return GitHubResourcePage(resources: Array(matches.prefix(100)), isPartial: partial || matches.count > 100,
                                      retryAfter: catalog.retryAfter, fetchedAt: catalog.fetchedAt, isCached: catalog.isCached)
        }
        partial = partial || scoped.count > 20
        // Favor active repositories instead of the first twenty alphabetically. One
        // repo-qualified search per kind avoids exhausting Search's separate budget.
        let repositories = Array(scoped.sorted {
            $0.revision == $1.revision ? $0.repository < $1.repository : $0.revision > $1.revision
        }.prefix(20))
        guard !repositories.isEmpty else {
            return GitHubResourcePage(resources: [], isPartial: partial, retryAfter: catalog.retryAfter,
                                      fetchedAt: catalog.fetchedAt, isCached: catalog.isCached)
        }
        let searchQuery = repositories.map { "repo:\($0.repository)" }.joined(separator: " ")
            + " is:\(kind == .issue ? "issue" : "pr")"
            + (term.isEmpty ? "" : " in:title \"\(term)\"")
        var results: [GitHubResource] = []
        var seen = Set<String>()
        var retryAfter = catalog.retryAfter
        do {
            let response = try await authorizedGET(path: "/search/issues", query: [
                URLQueryItem(name: "q", value: searchQuery), URLQueryItem(name: "per_page", value: "20"),
                URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
            ], lease: lease)
            let object = try GitHubJSON.parse(response.data).object()
            let total = try object.required("total_count").integer()
            let items = try object.required("items").array()
            let incomplete = try object.required("incomplete_results").boolean()
            guard items.count <= 20 else { throw GitHubError.invalidResponse }
            partial = partial || incomplete || total != items.count
            for item in items {
                let fields = try item.object()
                let number = try fields.required("number").integer(min: 1)
                let isPR = fields["pull_request"] != nil
                guard isPR == (kind == .pullRequest) else { throw GitHubError.invalidResponse }
                let rawURL = try fields.required("html_url").string(max: 1024)
                // Never trust a search result to widen the requested/authorized scope.
                guard let repository = try repositories.first(where: {
                    try GitHubURLPolicy.canonicalURL(repository: $0.repository, kind: kind, number: number).absoluteString == rawURL
                }) else { throw GitHubError.invalidResponse }
                let resource: GitHubResource
                if kind == .pullRequest {
                    // /search returns issue-shaped identity. Resolve only the PR node
                    // here; preview/send still refresh both repository and item access.
                    do {
                        let pull = try await authorizedGET(path: "/repos/\(repository.repository)/pulls/\(number)", lease: lease)
                        resource = try GitHubResourceDecoder.workItem(try GitHubJSON.parse(pull.data).object(), kind: .pullRequest,
                            repository: repository, includeDescription: false, now: clock.now(), isResolved: false)
                        guard resource.number == number else { throw GitHubError.invalidResponse }
                    } catch GitHubError.accessUnavailable { partial = true; continue }
                    catch GitHubError.notFound { partial = true; continue }
                } else {
                    resource = try GitHubResourceDecoder.workItem(fields, kind: .issue, repository: repository,
                        includeDescription: false, now: clock.now(), isResolved: false)
                }
                if seen.insert(resource.id).inserted { results.append(resource) }
                else { partial = true }
            }
        } catch GitHubError.throttled(let until) { partial = true; retryAfter = until }
        catch GitHubError.accessUnavailable { partial = true }
        catch GitHubError.notFound { partial = true }
        try check(lease)
        return GitHubResourcePage(resources: results, isPartial: partial, retryAfter: retryAfter, fetchedAt: clock.now())
    }

    /// Exact fresh access check. No permission decision is made from the cached catalog.
    /// Description sharing is always off unless the caller explicitly opts in.
    func lookup(
        kind: GitHubResourceKind, repository: String, number: Int? = nil,
        userID: Int, includeDescription: Bool = false
    ) async throws -> GitHubResource {
        guard GitHubURLPolicy.repositoryName(repository),
              (kind == .repository ? number == nil : (number ?? 0) > 0)
        else { throw GitHubError.invalidInput }
        return try await read(userID: userID) { lease in
            let catalog = try await self.catalog(lease: lease, forceRefresh: true)
            guard let authorized = catalog.resources.first(where: { $0.repository.lowercased() == repository.lowercased() }) else {
                // Partial discovery is not proof that a missing repository has no access.
                if let retry = catalog.retryAfter { throw GitHubError.throttled(until: retry) }
                throw catalog.isPartial ? GitHubError.accessUnavailable : GitHubError.notFound
            }
            return try await self.lookupAuthorized(kind: kind, repository: authorized, number: number,
                                                  includeDescription: includeDescription, lease: lease)
        }
    }

    func revalidate(_ resource: GitHubResource, userID: Int, includeDescription: Bool = false) async throws -> GitHubResource {
        let fresh = try await lookup(kind: resource.kind, repository: resource.repository, number: resource.number,
                                     userID: userID, includeDescription: includeDescription)
        guard fresh.nodeID == resource.nodeID, fresh.repositoryID == resource.repositoryID,
              fresh.resourceID == resource.resourceID else { throw GitHubError.identityChanged }
        return fresh
    }

    private func catalog(lease: UUID, forceRefresh: Bool) async throws -> GitHubResourcePage {
        try check(lease)
        // Forced catalog reads belong only to exact preview/send authorization. They
        // neither consult nor replace display cache entries (including in-flight ones).
        if forceRefresh { return try await fetchCatalog(lease: lease) }
        return try await discoveryCache.page(for: .catalog, clock: clock, staleWhileRevalidate: false) {
            try await self.fetchCatalog(lease: lease)
        }
    }

    private func fetchCatalog(lease: UUID) async throws -> GitHubResourcePage {
        try check(lease)
        if selectedCredential?.origin == .personalAccessToken { return try await personalTokenCatalog(lease: lease) }
        guard let configuration else { throw GitHubError.notConfigured }
        var installationIDs: [Int] = []
        var seenInstallations = Set<Int>()
        var partial = false
        var requestCount = 0
        var installationTotal: Int?
        var retryAfter: Date?
        var repositories: [String: GitHubResource] = [:]
        do {
            for page in 1...10 {
                let response = try await authorizedGET(path: "/user/installations", query: pagination(page), lease: lease)
                requestCount += 1
                let object = try GitHubJSON.parse(response.data).object()
                let total = try object.required("total_count").integer()
                if let installationTotal, installationTotal != total { partial = true }
                installationTotal = total
                let items = try object.required("installations").array()
                guard items.count <= 100 else { throw GitHubError.invalidResponse }
                for item in items {
                    let installation = try item.object()
                    let id = try installation.required("id").integer(min: 1)
                    guard seenInstallations.insert(id).inserted else { partial = true; continue }
                    guard try installation.required("app_slug").string(max: 100) == configuration.appSlug else {
                        throw GitHubError.invalidResponse
                    }
                    let permissions = try installation.required("permissions").object()
                    // Catalog visibility needs metadata only. Issue/PR reads enforce
                    // their own permissions at GitHub, independently of each other.
                    let required = Set(["metadata"])
                    // User-to-server access is the intersection of this App installation
                    // and the user's permissions. Extra grants do not remove read access;
                    // transport still permits only GET regardless of granted write rights.
                    let readable = try required.allSatisfy { permission in
                        guard let value = permissions[permission] else { return false }
                        return ["read", "write"].contains(try value.string(max: 20))
                    }
                    let suspended = try installation.optionalString("suspended_at", max: 40) != nil
                    guard readable, !suspended else { partial = true; continue }
                    installationIDs.append(id)
                }
                if items.count < 100 { break }
                if page == 10 { partial = true }
            }
            partial = partial || seenInstallations.count != installationTotal
            installationLoop: for installationID in installationIDs {
                var seen = Set<String>()
                var repositoryTotal: Int?
                for page in 1...50 {
                    guard requestCount < 50, repositories.count < 5000 else { partial = true; break installationLoop }
                    let response: GitHubHTTPResponse
                    do {
                        response = try await authorizedGET(path: "/user/installations/\(installationID)/repositories",
                                                           query: pagination(page), lease: lease)
                    } catch GitHubError.notFound { partial = true; continue installationLoop }
                    catch GitHubError.accessUnavailable { partial = true; continue installationLoop }
                    requestCount += 1
                    let object = try GitHubJSON.parse(response.data).object()
                    let total = try object.required("total_count").integer()
                    if let repositoryTotal, repositoryTotal != total { partial = true }
                    repositoryTotal = total
                    let items = try object.required("repositories").array()
                    guard items.count <= 100 else { throw GitHubError.invalidResponse }
                    for item in items {
                        let resource = try GitHubResourceDecoder.repository(try item.object(), includeDescription: false, now: clock.now(), isResolved: false)
                        guard seen.insert(resource.nodeID).inserted else { partial = true; continue }
                        repositories[resource.nodeID] = resource
                    }
                    if items.count < 100 { break }
                    if page == 50 { partial = true }
                }
                partial = partial || seen.count != repositoryTotal
            }
        } catch GitHubError.throttled(let until) {
            partial = true
            retryAfter = until
        }
        try check(lease)
        let result = GitHubResourcePage(resources: repositories.values.sorted { $0.repository < $1.repository },
                                        isPartial: partial, retryAfter: retryAfter, fetchedAt: clock.now())
        return result
    }

    private func personalTokenCatalog(lease: UUID) async throws -> GitHubResourcePage {
        var resources: [String: GitHubResource] = [:]
        var partial = false
        var retryAfter: Date?
        do {
            for page in 1...50 {
                // PAT-compatible; neither a product client ID nor an App installation is consulted.
                let response = try await authorizedGET(path: "/user/repos", query: pagination(page), lease: lease)
                let items = try GitHubJSON.parse(response.data).array()
                guard items.count <= 100 else { throw GitHubError.invalidResponse }
                for item in items {
                    let resource = try GitHubResourceDecoder.repository(try item.object(), includeDescription: false,
                                                                        now: clock.now(), isResolved: false)
                    if resources.updateValue(resource, forKey: resource.repositoryID) != nil { partial = true }
                }
                if items.count < 100 { break }
                if page == 50 { partial = true }
            }
        } catch GitHubError.throttled(let until) {
            partial = true
            retryAfter = until
        }
        try check(lease)
        let result = GitHubResourcePage(resources: resources.values.sorted { $0.repository < $1.repository },
                                        isPartial: partial, retryAfter: retryAfter, fetchedAt: clock.now())
        return result
    }

    private func pagination(_ page: Int) -> [URLQueryItem] {
        // Construct each same-origin URL; never follow provider-controlled Link headers.
        [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
    }

    private func lookupAuthorized(
        kind: GitHubResourceKind, repository: GitHubResource, number: Int?, includeDescription: Bool, lease: UUID
    ) async throws -> GitHubResource {
        // Refresh repo privacy/identity as well as item metadata; public -> private matters.
        let repoResponse = try await authorizedGET(path: "/repos/\(repository.repository)", lease: lease)
        let currentRepository = try GitHubResourceDecoder.repository(try GitHubJSON.parse(repoResponse.data).object(),
                                                                    includeDescription: includeDescription && kind == .repository,
                                                                    now: clock.now())
        guard currentRepository.nodeID == repository.nodeID,
              currentRepository.repositoryID == repository.repositoryID,
              currentRepository.repository.lowercased() == repository.repository.lowercased()
        else { throw GitHubError.identityChanged }
        if kind == .repository { return currentRepository }
        guard let number, number > 0 else { throw GitHubError.invalidInput }
        let path = "/repos/\(currentRepository.repository)/\(kind == .issue ? "issues" : "pulls")/\(number)"
        let response = try await authorizedGET(path: path, lease: lease)
        let result = try GitHubResourceDecoder.workItem(try GitHubJSON.parse(response.data).object(), kind: kind,
                                                       repository: currentRepository, includeDescription: includeDescription, now: clock.now())
        guard result.number == number else { throw GitHubError.invalidResponse }
        return result
    }
}

enum GitHubResourceDecoder {
    static func repository(_ fields: [String: GitHubJSON], includeDescription: Bool, now: Date, isResolved: Bool = true) throws -> GitHubResource {
        let fullName = try fields.required("full_name").string(max: 201)
        guard GitHubURLPolicy.repositoryName(fullName) else { throw GitHubError.invalidResponse }
        let nodeID = try node(fields)
        let repositoryID = try fields.required("id").decimalID()
        let url = try GitHubURLPolicy.canonicalURL(repository: fullName, kind: .repository, number: nil)
        try checkURL(fields, expected: url)
        let isPrivate = try fields.required("private").boolean()
        let archived = try fields.required("archived").boolean()
        let disabled = try fields.required("disabled").boolean()
        let (description, truncated) = try includedDescription(fields, key: "description", include: includeDescription)
        return GitHubResource(kind: .repository, nodeID: nodeID, repositoryID: repositoryID, resourceID: repositoryID,
                              isResolved: isResolved, isDraft: false, repository: fullName, number: nil,
                              title: GitHubContent.safe(fullName), url: url,
                              state: disabled ? "disabled" : archived ? "archived" : "active", isPrivate: isPrivate,
                              description: description, descriptionTruncated: truncated,
                              revision: try revision(fields), fetchedAt: now)
    }

    static func workItem(
        _ fields: [String: GitHubJSON], kind: GitHubResourceKind, repository: GitHubResource,
        includeDescription: Bool, now: Date, isResolved: Bool = true
    ) throws -> GitHubResource {
        guard kind != .repository else { throw GitHubError.invalidResponse }
        if kind == .issue, fields["pull_request"] != nil { throw GitHubError.invalidResponse }
        if kind == .pullRequest {
            // Actual /pulls response, not an issue-shaped search result.
            let base = try fields.required("base").object()
            let repo = try base.required("repo").object()
            guard try node(repo) == repository.nodeID,
                  try repo.required("id").decimalID() == repository.repositoryID,
                  try repo.required("full_name").string(max: 201).lowercased() == repository.repository.lowercased()
            else { throw GitHubError.invalidResponse }
            _ = try fields.required("merged").boolean()
        }
        let number = try fields.required("number").integer(min: 1)
        let url = try GitHubURLPolicy.canonicalURL(repository: repository.repository, kind: kind, number: number)
        try checkURL(fields, expected: url)
        let state = try fields.required("state").string(max: 20)
        guard ["open", "closed"].contains(state) else { throw GitHubError.invalidResponse }
        var resolvedState = state
        var isDraft = false
        if kind == .pullRequest {
            let merged = try fields.required("merged").boolean()
            isDraft = try fields.required("draft").boolean()
            if merged { resolvedState = "merged" }
        }
        let (description, truncated) = try includedDescription(fields, key: "body", include: includeDescription)
        return GitHubResource(kind: kind, nodeID: try node(fields), repositoryID: repository.repositoryID,
                              resourceID: try fields.required("id").decimalID(), isResolved: isResolved, isDraft: isDraft,
                              repository: repository.repository, number: number,
                              title: GitHubContent.safe(try fields.required("title").string(max: 4096)), url: url,
                              state: resolvedState, isPrivate: repository.isPrivate,
                              description: description, descriptionTruncated: truncated,
                              revision: try revision(fields), fetchedAt: now)
    }

    private static func checkURL(_ fields: [String: GitHubJSON], expected: URL) throws {
        let raw = try fields.required("html_url").string(max: 1024)
        guard raw == expected.absoluteString else { throw GitHubError.invalidResponse }
    }

    private static func node(_ fields: [String: GitHubJSON]) throws -> String {
        let id = try fields.required("node_id").string(max: 200)
        guard GitHubContent.safe(id) == id,
              id.range(of: #"^[A-Za-z0-9_+/=-]+$"#, options: .regularExpression) != nil else {
            throw GitHubError.invalidResponse
        }
        return id
    }

    private static func revision(_ fields: [String: GitHubJSON]) throws -> String {
        let value = try fields.required("updated_at").string(max: 40)
        guard ISO8601DateFormatter().date(from: value) != nil else { throw GitHubError.invalidResponse }
        return value
    }

    private static func includedDescription(_ fields: [String: GitHubJSON], key: String, include: Bool) throws -> (String?, Bool) {
        guard include, let raw = try fields.optionalString(key, max: 524_288) else { return (nil, false) }
        let safe = GitHubContent.safe(raw)
        let maximum = 8192
        if safe.utf8.count <= maximum { return (safe, false) }
        var bounded = ""
        var bytes = 0
        for character in safe {
            let size = String(character).utf8.count
            if bytes + size > maximum { break }
            bounded.append(character)
            bytes += size
        }
        return (bounded, true)
    }
}
