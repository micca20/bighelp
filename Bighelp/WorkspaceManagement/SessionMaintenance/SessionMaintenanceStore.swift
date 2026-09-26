import Foundation
import Observation

@MainActor @Observable
final class SessionMaintenanceStore {
    let hostName: String
    let profileID: String

    private(set) var statistics: HermesSessionStoreStats?
    private(set) var sessions: [HermesSessionMaintenanceItem] = []
    private(set) var foreignSessions: [HermesForeignSessionItem] = []
    private(set) var foreignHost: String?
    private(set) var foreignNextOffset: Int?
    private(set) var foreignUnreadable = 0
    private(set) var foreignPreview: HermesForeignSessionPreview?
    private(set) var lineage: HermesSessionLineage?
    private(set) var mostRecentLookup: HermesSessionMostRecentLookup?
    private(set) var ownerBackfillReview: HermesSessionOwnerBackfillReview?
    private(set) var bulkReview: HermesSessionBulkDeleteReview?
    private(set) var emptyReview: HermesSessionEmptyDeleteReview?
    private(set) var pruneReview: HermesSessionPruneReview?
    private(set) var importReview: HermesSessionImportReview?
    private(set) var pendingExport: HermesSessionExport?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false

    var selectedSessionIDs: Set<String> = []
    var pruneFilter = HermesSessionPruneFilter()
    var foreignSource: String?

    @ObservationIgnored private let client: any HermesSessionMaintenanceManaging
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        profileID: String,
        client: any HermesSessionMaintenanceManaging
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }
    var selectedSessions: [HermesSessionMaintenanceItem] {
        sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    func load() async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        clearReviews()
        defer { if generation == request { isLoading = false } }
        do {
            let stats = try await client.statistics(profileID: profileID)
            let rows = try await client.sessions(profileID: profileID)
            guard canPublish(request) else { return }
            statistics = stats
            sessions = rows
            selectedSessionIDs.formIntersection(Set(rows.map(\.id)))
        } catch is CancellationError {
        } catch {
            guard canPublish(request) else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async {
        guard operationTitle == nil else { return }
        isLoading = false
        await load()
    }

    func findMostRecent() async {
        guard begin("Finding the most recent session") else { return }
        mostRecentLookup = nil
        defer { finish() }
        do {
            let lookup = try await client.mostRecentSession(profileID: profileID)
            guard ownsScope else { return }
            mostRecentLookup = lookup
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func setHidden(_ session: HermesSessionMaintenanceItem, hidden: Bool) async {
        guard begin(hidden ? "Hiding session" : "Showing session") else { return }
        defer { finish() }
        do {
            let result = try await client.setHidden(
                profileID: profileID, sessionID: session.id, hidden: hidden
            )
            guard ownsScope else { return }
            successMessage = result.hidden
                ? "Hermes hid this session without archiving or deleting it."
                : "Hermes returned this session to the default list without changing its archive state."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func closeLive(_ session: HermesSessionMaintenanceItem) async {
        guard session.active, begin("Closing live runtime") else { return }
        defer { finish() }
        do {
            let result = try await client.closeLiveSession(
                profileID: profileID, sessionID: session.id
            )
            guard ownsScope else { return }
            successMessage = result.closedByRequest
                ? "Hermes closed the live runtime and preserved all \(result.preservedMessageCount) stored message(s)."
                : "The runtime was already closed; Hermes confirmed all \(result.preservedMessageCount) stored message(s) remain."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func prepareOwnerBackfill() async {
        guard begin("Preparing ownership review") else { return }
        ownerBackfillReview = nil
        defer { finish() }
        do {
            let review = try await client.prepareOwnerBackfill(profileID: profileID)
            guard ownsScope else { return }
            ownerBackfillReview = review
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func backfillReviewedOwners() async {
        guard let review = ownerBackfillReview,
              begin("Backfilling reviewed ownership") else { return }
        defer { finish() }
        do {
            let result = try await client.ownerBackfill(reviewed: review)
            guard ownsScope else { return }
            ownerBackfillReview = nil
            successMessage = "Hermes stamped \(result.stampedRows) of \(result.reviewedStoreRows) reviewed store row(s) for \(result.profileID) and confirmed \(result.remainingUnownedRows) remain."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func loadForeign(reset: Bool = true) async {
        guard begin(reset ? "Finding foreign sessions" : "Loading more sessions") else { return }
        defer { finish() }
        do {
            let offset = reset ? 0 : (foreignNextOffset ?? 0)
            let page = try await client.foreignSessions(
                profileID: profileID, source: foreignSource, offset: offset, limit: 25
            )
            guard ownsScope else { return }
            foreignHost = page.host
            foreignUnreadable = page.unreadable
            foreignNextOffset = page.nextOffset
            if reset {
                foreignSessions = page.sessions
            } else {
                let existing = Set(foreignSessions.map(\.id))
                foreignSessions.append(contentsOf: page.sessions.filter { !existing.contains($0.id) })
            }
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func previewForeign(_ item: HermesForeignSessionItem) async {
        guard begin("Loading safe preview") else { return }
        defer { finish() }
        do {
            let preview = try await client.foreignPreview(profileID: profileID, item: item)
            guard ownsScope else { return }
            foreignPreview = preview
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func importForeign() async -> HermesForeignSessionImportResult? {
        guard let review = foreignPreview, review.alreadyImportedSessionID == nil,
              begin("Importing reviewed session") else { return nil }
        defer { finish() }
        do {
            let result = try await client.importForeign(reviewed: review)
            guard ownsScope else { return nil }
            foreignPreview = nil
            successMessage = "Hermes imported the reviewed foreign history and confirmed session \(result.sessionID)."
            await reloadAfterMutation()
            return result
        } catch is CancellationError {
            return nil
        } catch {
            guard ownsScope else { return nil }
            errorMessage = Self.message(error)
            return nil
        }
    }

    func prepareBulkDelete() async {
        guard !selectedSessionIDs.isEmpty, begin("Preparing deletion review") else { return }
        defer { finish() }
        do {
            let review = try await client.prepareBulkDelete(
                profileID: profileID, sessionIDs: selectedSessionIDs.sorted()
            )
            guard ownsScope else { return }
            bulkReview = review
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func deleteReviewedBulk() async {
        guard let review = bulkReview, begin("Deleting reviewed sessions") else { return }
        defer { finish() }
        do {
            let result = try await client.deleteBulk(reviewed: review)
            guard ownsScope else { return }
            bulkReview = nil
            selectedSessionIDs.subtract(result.verifiedAbsentIDs)
            successMessage = "Hermes deleted and verified \(result.deleted) selected session(s)."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func prepareEmptyDelete() async {
        guard begin("Preparing empty-session review") else { return }
        defer { finish() }
        do {
            let review = try await client.prepareEmptyDelete(profileID: profileID)
            guard ownsScope else { return }
            emptyReview = review
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func deleteReviewedEmpty() async {
        guard let review = emptyReview, review.count > 0,
              begin("Deleting empty sessions") else { return }
        defer { finish() }
        do {
            let result = try await client.deleteEmpty(reviewed: review)
            guard ownsScope else { return }
            emptyReview = nil
            successMessage = "Hermes deleted \(result.deleted) empty ended session(s) and confirmed none remain."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func preparePrune() async {
        guard begin("Preparing prune review") else { return }
        defer { finish() }
        do {
            let review = try await client.preparePrune(profileID: profileID, filter: pruneFilter)
            guard ownsScope else { return }
            pruneReview = review
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func pruneReviewedSessions() async {
        guard let review = pruneReview, !review.sessions.isEmpty,
              begin("Pruning reviewed sessions") else { return }
        defer { finish() }
        do {
            let result = try await client.prune(reviewed: review)
            guard ownsScope else { return }
            pruneReview = nil
            selectedSessionIDs.subtract(result.verifiedAbsentIDs)
            successMessage = "Hermes pruned and verified \(result.deleted) reviewed session(s)."
            await reloadAfterMutation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func export(_ session: HermesSessionMaintenanceItem) async {
        guard begin("Preparing session export") else { return }
        defer { finish() }
        do {
            let result = try await client.exportSession(profileID: profileID, sessionID: session.id)
            guard ownsScope else { return }
            pendingExport = result
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func prepareImport(data: Data) {
        guard ownsScope, !isBusy else { return }
        errorMessage = nil
        successMessage = nil
        do {
            importReview = try client.prepareImport(profileID: profileID, data: data)
        } catch {
            errorMessage = Self.message(error)
        }
    }

    func importReviewedPackage() async -> HermesSessionImportResult? {
        guard let review = importReview, begin("Importing reviewed package") else { return nil }
        defer { finish() }
        do {
            let result = try await client.importSessions(reviewed: review)
            guard ownsScope else { return nil }
            importReview = nil
            successMessage = "Hermes imported \(result.importedIDs.count) session(s), skipped \(result.skippedIDs.count) existing session(s), and confirmed every imported ID."
            await reloadAfterMutation()
            return result
        } catch is CancellationError {
            return nil
        } catch {
            guard ownsScope else { return nil }
            errorMessage = Self.message(error)
            return nil
        }
    }

    func resolveLineage(sessionID: String) async {
        guard begin("Resolving session lineage") else { return }
        defer { finish() }
        do {
            let result = try await client.latestDescendant(profileID: profileID, sessionID: sessionID)
            guard ownsScope else { return }
            lineage = result
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func clearBulkReview() { bulkReview = nil }
    func clearOwnerBackfillReview() { ownerBackfillReview = nil }
    func clearEmptyReview() { emptyReview = nil }
    func clearPruneReview() { pruneReview = nil }
    func clearImportReview() { importReview = nil }
    func clearForeignPreview() { foreignPreview = nil }
    func clearLineage() { lineage = nil }
    func clearExport() { pendingExport = nil }
    func clearMessages() { errorMessage = nil; successMessage = nil }

    func retire() {
        isRetired = true
        generation = UUID()
        statistics = nil
        sessions = []
        foreignSessions = []
        foreignPreview = nil
        lineage = nil
        mostRecentLookup = nil
        selectedSessionIDs = []
        clearReviews()
        pendingExport = nil
        isLoading = false
        operationTitle = nil
        clearMessages()
    }

    private func reloadAfterMutation() async {
        do {
            let stats = try await client.statistics(profileID: profileID)
            let rows = try await client.sessions(profileID: profileID)
            guard ownsScope else { return }
            statistics = stats
            sessions = rows
            selectedSessionIDs.formIntersection(Set(rows.map(\.id)))
        } catch {
            guard ownsScope else { return }
            errorMessage = "The operation was confirmed, but the catalog refresh failed. Pull to refresh before another change."
        }
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() { operationTitle = nil }
    private func clearReviews() {
        ownerBackfillReview = nil
        bulkReview = nil
        emptyReview = nil
        pruneReview = nil
        importReview = nil
    }
    private func canPublish(_ request: UUID) -> Bool {
        ownsScope && generation == request && !Task.isCancelled
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this session operation. Refresh before trying it again."
    }
}
