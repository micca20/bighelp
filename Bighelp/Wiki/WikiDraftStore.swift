import Foundation
import Observation

/// Owns unsaved file-bound source only. WikiStore owns remote transactions.
/// Construction (including owner:nil) performs no storage or network work.
@MainActor
@Observable
final class WikiDraftStore {
    private(set) var owner: WikiOwner?
    private(set) var drafts: [WikiDraft] = []
    private(set) var sessionID = UUID()
    private(set) var persistenceFailure: String?
    private(set) var hasUnflushedChanges = false

    @ObservationIgnored private let persistence: any WikiDraftPersistence
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var checkpoint: Task<Void, Never>?
    @ObservationIgnored private var checkpointID = UUID()
    @ObservationIgnored private var invalidations: [UUID: () -> Void] = [:]
    // Failed context-transition flushes stay hidden in bounded process memory.
    // Only explicit restoration of that complete owner may expose them again.
    @ObservationIgnored private var suspended: [WikiOwner: [WikiDraft]] = [:]
    @ObservationIgnored private var deletedAccounts: Set<String> = []

    init(owner: WikiOwner?, persistence: (any WikiDraftPersistence)? = nil,
         availability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()) {
        self.owner = owner?.isValid == true ? owner : nil
        self.persistence = persistence ?? WikiDraftLocalPersistence(availability: availability)
    }

    func restoreLocalState() throws {
        guard !restored, let owner else { return }
        try requireOwner(owner)
        let values: [WikiDraft]
        if let retained = suspended[owner] { values = retained }
        else {
            let state = try persistence.load(owner: owner)
            guard state == nil || state?.owner == owner else { throw WikiError.ownerChanged }
            values = state?.drafts ?? []
        }
        try WikiDraftLimits.validate(WikiDraftState(owner: owner, drafts: values))
        try requireMemoryBudget(values, replacing: owner)
        drafts = values
        hasUnflushedChanges = suspended.removeValue(forKey: owner) != nil
        restored = true
    }

    /// Flush BEFORE publishing a different file; a failed flush leaves the old
    /// draft intact and aborts navigation. A retained same-file draft always wins.
    @discardableResult
    func open(document: WikiDocument) throws -> WikiDraft {
        try requireOwner(document.owner)
        try WikiDraftLimits.validateDocument(document, owner: document.owner)
        try restoreLocalState()
        try flush()
        if let index = drafts.firstIndex(where: { WikiDraft.sameFile($0.document, document) }) {
            let prior = drafts[index].document
            if prior.baseRevision != document.baseRevision || prior.originalBytes != document.originalBytes
                || prior.connection != document.connection {
                var candidate = drafts
                candidate[index].currentDocument = document
                try persistReplacement(candidate, owner: document.owner)
            }
            let opened = drafts[index]
            invalidate() // A new open invalidates the previous editor lease.
            return opened
        }
        guard drafts.count < WikiDraftLimits.draftsPerOwner else { throw WikiError.quota }
        let draft = WikiDraft(document: document)
        let candidate = drafts + [draft]
        try requireMemoryBudget(candidate, replacing: document.owner)
        // Admission is durable before a new editor is presented.
        try persistence.save(WikiDraftState(owner: document.owner, drafts: candidate))
        drafts = candidate
        invalidate()
        return draft
    }

    /// Explicit journal-to-editor restoration. Existing same-file work wins;
    /// the submitted snapshot is archived rather than overwriting newer edits.
    @discardableResult
    func restoreRecovery(operation: WikiPendingSave) throws -> WikiDraft {
        try requireOwner(operation.document.owner)
        guard operation.bytes.count <= WikiLimits.editBytes,
              WikiLimits.digest(operation.bytes) == operation.sha256 else { throw WikiError.invalidResponse }
        try restoreLocalState()
        try flush()
        if let existing = drafts.first(where: { WikiDraft.sameFile($0.document, operation.document) }) {
            let alreadyRetained = Data(existing.workingSource.utf8) == operation.bytes
                || (operation.verifiedCommitted && existing.document.originalBytes == operation.bytes
                    && existing.document.baseRevision == operation.currentDocument?.baseRevision)
            if !alreadyRetained { try retainRecovery(id: existing.id, operation: operation) }
            guard let retained = draft(id: existing.id) else { throw WikiDraftError.inactive }
            invalidate()
            return retained
        }
        let opened = try open(document: operation.document)
        try update(id: opened.id, workingSource: operation.workingSource)
        try flush()
        guard let restored = draft(id: opened.id) else { throw WikiDraftError.inactive }
        return restored
    }

    func draft(id: UUID) -> WikiDraft? { drafts.first { $0.id == id } }

    /// Exact source mutation, without encoding or filesystem work per keystroke.
    /// Rejected proposals are not truncated. The editor must reset its external
    /// revision on rejection so native focused text cannot diverge from the draft.
    func update(id: UUID, workingSource: String) throws {
        guard let owner else { throw WikiDraftError.inactive }
        try requireOwner(owner)
        guard workingSource.utf8.count <= WikiLimits.editBytes else { throw WikiDraftError.editLimit }
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { throw WikiDraftError.inactive }
        guard Data(workingSource.utf8) != Data(drafts[index].workingSource.utf8) else { return }
        var candidate = drafts
        candidate[index].workingSource = workingSource
        candidate[index].updatedAt = .now
        try requireMemoryBudget(candidate, replacing: owner)
        drafts = candidate
        hasUnflushedChanges = true
        scheduleCheckpoint()
    }

    /// Synchronous Close/background/pre-transition checkpoint. A thrown error
    /// means callers MUST NOT dismiss claiming that this draft was preserved.
    func flush() throws {
        cancelCheckpoint()
        guard hasUnflushedChanges, let owner else { return }
        try requireOwner(owner)
        do {
            try persistence.save(WikiDraftState(owner: owner, drafts: drafts))
            hasUnflushedChanges = false
            persistenceFailure = nil
        } catch {
            persistenceFailure = WikiDraftError.message(error)
            throw error
        }
    }

    /// Security transition always clears visible state, even if flushing fails.
    /// Failed bytes remain owner-quarantined in memory, not silently discarded.
    /// Parent must also invalidate WikiStore and dismiss the old root editor.
    func setContext(owner newOwner: WikiOwner?) throws {
        var failure: Error?
        do { try flush() } catch { failure = error }
        if hasUnflushedChanges, let owner { suspended[owner] = drafts }
        invalidate()
        drafts = []
        owner = newOwner?.isValid == true && !deletedAccounts.contains(newOwner?.accountID ?? "") ? newOwner : nil
        restored = false
        hasUnflushedChanges = false
        persistenceFailure = nil
        if let failure { throw failure }
    }

    /// Local-only explicit discard. A failed delete keeps the entire live draft.
    func discard(id: UUID) throws {
        guard let owner, drafts.contains(where: { $0.id == id }) else { throw WikiDraftError.inactive }
        try requireOwner(owner)
        cancelCheckpoint()
        let candidate = drafts.filter { $0.id != id }
        try persistence.save(WikiDraftState(owner: owner, drafts: candidate))
        drafts = candidate
        hasUnflushedChanges = false
        persistenceFailure = nil
    }

    /// Only verified committed readback can automatically advance the base. The
    /// working source is deliberately NOT replaced: it may have changed in-flight.
    func applyVerifiedCommit(id: UUID, outcome: WikiPendingSave) throws {
        guard outcome.verifiedCommitted, let current = outcome.currentDocument,
              let index = drafts.firstIndex(where: { $0.id == id }),
              WikiDraft.sameFile(drafts[index].document, outcome.document),
              drafts[index].document.baseRevision == outcome.document.baseRevision,
              drafts[index].document.originalBytes == outcome.document.originalBytes else { return }
        try requireOwner(current.owner)
        var candidate = drafts
        candidate[index].document = current
        if let observed = candidate[index].currentDocument,
           observed.baseRevision == current.baseRevision && observed.originalBytes == current.originalBytes
            && observed.connection == current.connection {
            candidate[index].currentDocument = nil
        }
        // A newer host version discovered when reopening remains a conflict;
        // an old verified journal cannot erase that observation.
        // Persist before advancing the live base. Otherwise a failed write makes
        // the old-base guard above skip this same verified outcome on retry.
        // The candidate retains all working text, including in-flight edits.
        do {
            try persistReplacement(candidate, owner: current.owner)
        } catch {
            persistenceFailure = WikiDraftError.message(error)
            throw error
        }
    }

    /// Explicitly confirmed fresh-base acceptance retains the previous base AND
    /// current edits. It never overwrites working text or performs a remote save.
    func acceptFreshBase(id: UUID, current: WikiDocument, operation: WikiPendingSave? = nil) throws {
        guard let owner, let index = drafts.firstIndex(where: { $0.id == id }),
              WikiDraft.sameFile(drafts[index].document, current) else { throw WikiDraftError.inactive }
        try requireOwner(owner)
        try WikiDraftLimits.validateDocument(current, owner: owner)
        var candidate = drafts
        let previous = candidate[index]
        try appendRecovery(to: &candidate[index], document: previous.document,
                           source: previous.workingSource, operationID: nil)
        if let operation {
            guard operation.phase == .conflict || (operation.phase == .committed && operation.hasLaterExternalChange),
                  WikiDraft.sameFile(operation.document, current) else {
                throw WikiError.recoveryRequired
            }
            try appendRecovery(to: &candidate[index], document: operation.document,
                               source: operation.workingSource, operationID: operation.id)
        }
        try appendRecovery(to: &candidate[index], document: current,
                           source: current.originalSource, operationID: nil)
        candidate[index].document = current
        candidate[index].currentDocument = nil
        try persistReplacement(candidate, owner: owner)
    }

    /// Archive immutable save material before an explicitly confirmed retirement
    /// of WikiStore's operation. If that retirement fails, the journal still wins.
    func retainRecovery(id: UUID, operation: WikiPendingSave) throws {
        guard let owner, let index = drafts.firstIndex(where: { $0.id == id }),
              WikiDraft.sameFile(drafts[index].document, operation.document) else { throw WikiDraftError.inactive }
        try requireOwner(owner)
        var candidate = drafts
        try appendRecovery(to: &candidate[index], document: operation.document,
                           source: operation.workingSource, operationID: operation.id)
        try persistReplacement(candidate, owner: owner)
    }

    func removeRecoveryCopy(draftID: UUID, copyID: UUID) throws {
        guard let owner, let index = drafts.firstIndex(where: { $0.id == draftID }) else { throw WikiDraftError.inactive }
        try requireOwner(owner)
        var candidate = drafts
        candidate[index].recoveryCopies.removeAll { $0.id == copyID }
        try persistReplacement(candidate, owner: owner)
    }

    /// Tombstone first, then remove ALL persisted owner epochs. Even a deletion
    /// failure denies late callbacks/reopening in this instance; retry this API.
    /// Successful account recreation requires a newly constructed store.
    func deleteAccountData(accountID: String) throws {
        deletedAccounts.insert(accountID)
        suspended = suspended.filter { $0.key.accountID != accountID }
        if owner?.accountID == accountID {
            invalidate() // Never flush after the erasure boundary.
            owner = nil
            drafts = []
            restored = false
            hasUnflushedChanges = false
            persistenceFailure = nil
        }
        try persistence.deleteAccount(accountID: accountID)
    }

    func onInvalidation(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        invalidations[id] = action
        return id
    }

    func removeInvalidation(_ id: UUID) { invalidations[id] = nil }

    private func requireOwner(_ expected: WikiOwner) throws {
        guard expected.isValid, owner == expected, !deletedAccounts.contains(expected.accountID) else {
            throw WikiDraftError.inactive
        }
    }

    private func persistReplacement(_ candidate: [WikiDraft], owner: WikiOwner) throws {
        try requireMemoryBudget(candidate, replacing: owner)
        try persistence.save(WikiDraftState(owner: owner, drafts: candidate))
        cancelCheckpoint()
        drafts = candidate
        hasUnflushedChanges = false
        persistenceFailure = nil
    }

    private func appendRecovery(to draft: inout WikiDraft, document: WikiDocument,
                                source: String, operationID: String?) throws {
        if draft.recoveryCopies.contains(where: {
            $0.operationID == operationID && $0.document.baseRevision == document.baseRevision
                && $0.document.originalBytes == document.originalBytes && Data($0.workingSource.utf8) == Data(source.utf8)
        }) { return }
        guard draft.recoveryCopies.count < WikiDraftLimits.recoveryCopiesPerDraft else { throw WikiDraftError.copiesFull }
        draft.recoveryCopies.append(WikiDraftRecoveryCopy(id: UUID(), document: document, workingSource: source,
                                                         operationID: operationID, retainedAt: .now))
    }

    private func requireMemoryBudget(_ candidate: [WikiDraft], replacing owner: WikiOwner) throws {
        let all = suspended.filter { $0.key != owner }.values.flatMap { $0 } + candidate
        guard all.count <= WikiDraftLimits.memoryDrafts else { throw WikiError.quota }
        var bytes = 0
        for draft in all {
            bytes += draft.document.originalBytes.count + draft.document.originalSource.utf8.count
                + draft.workingSource.utf8.count + (draft.currentDocument?.originalBytes.count ?? 0)
                + (draft.currentDocument?.originalSource.utf8.count ?? 0)
            for copy in draft.recoveryCopies {
                bytes += copy.document.originalBytes.count + copy.document.originalSource.utf8.count + copy.workingSource.utf8.count
            }
            guard bytes <= WikiDraftLimits.accountBytes else { throw WikiError.quota }
        }
    }

    private func scheduleCheckpoint() {
        cancelCheckpoint()
        let epoch = sessionID
        let ticket = checkpointID
        checkpoint = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.sessionID == epoch, self.checkpointID == ticket, !Task.isCancelled else { return }
            do { try self.flush() } catch { /* Observable error; dirty bytes remain in memory. */ }
        }
    }

    private func cancelCheckpoint() {
        checkpoint?.cancel()
        checkpoint = nil
        checkpointID = UUID()
    }

    private func invalidate() {
        cancelCheckpoint()
        sessionID = UUID()
        let callbacks = Array(invalidations.values)
        invalidations.removeAll()
        for callback in callbacks { callback() }
    }
}
