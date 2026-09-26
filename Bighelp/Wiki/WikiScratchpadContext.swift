import Foundation
import Observation
import SwiftUI

/// An optional accessory for the existing full-screen Scratchpad, not another
/// editor. Parent passes `markdown: context.binding` and `wikiContext: context`.
@MainActor
@Observable
final class WikiScratchpadContext: Identifiable {
    let id = UUID()
    let draftID: UUID
    let drafts: WikiDraftStore
    let wiki: WikiStore
    let requiresSourceEditing: Bool
    private(set) var failure: String?
    private(set) var isWorking = false
    private(set) var rejectedEditRevision = 0

    @ObservationIgnored private let owner: WikiOwner
    @ObservationIgnored private let sessionID: UUID
    private var invalidated = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID = UUID()
    @ObservationIgnored private var invalidationID: UUID?
    @ObservationIgnored private let onSaveResult: (WikiPendingSave) -> Void

    init(drafts: WikiDraftStore, wiki: WikiStore, draftID: UUID,
         onSaveResult: @escaping (WikiPendingSave) -> Void = { _ in }) throws {
        guard let draft = drafts.draft(id: draftID), drafts.owner == draft.document.owner,
              wiki.owner == draft.document.owner else { throw WikiDraftError.inactive }
        self.drafts = drafts
        self.wiki = wiki
        self.draftID = draftID
        owner = draft.document.owner
        sessionID = drafts.sessionID
        self.onSaveResult = onSaveResult
        requiresSourceEditing = Self.needsExactSource(draft.workingSource)
        try wiki.restoreLocalState()
        invalidationID = drafts.onInvalidation { [weak self] in self?.invalidate() }
        // Finish a previously verified save silently after reopen. No network
        // write or uncertain-operation replay occurs during editor construction.
        if let pending, pending.verifiedCommitted {
            do { try completeVerifiedSave(pending) }
            catch { failure = WikiDraftError.message(error) }
        }
    }

    /// A new remote file becomes an ordinary revision-bound editor only after
    /// exact readback. Persist the adopted editor before retiring its journal.
    static func adoptingCreation(_ outcome: WikiPendingSave, drafts: WikiDraftStore,
                                 wiki: WikiStore, workingSource: String? = nil) throws -> WikiScratchpadContext {
        guard outcome.verifiedCommitted, outcome.document.isNewFile,
              outcome.document.owner == wiki.owner, drafts.owner == wiki.owner else {
            throw WikiError.recoveryRequired
        }
        let draft = try drafts.restoreRecovery(operation: outcome)
        try drafts.applyVerifiedCommit(id: draft.id, outcome: outcome)
        if let workingSource, Data(workingSource.utf8) != outcome.bytes {
            try drafts.update(id: draft.id, workingSource: workingSource)
            try drafts.flush()
        }
        let context = try WikiScratchpadContext(drafts: drafts, wiki: wiki, draftID: draft.id)
        if wiki.pendingSaves.contains(where: { $0.id == outcome.id }) {
            try context.completeVerifiedSave(outcome)
        }
        return context
    }

    /// Carry the current free draft into the verified editor before clearing it.
    /// A recovered older create is only the base, never an implicit new upload.
    static func adoptingCreation(_ outcome: WikiPendingSave, drafts: WikiDraftStore,
                                 wiki: WikiStore, freeSource: inout String) throws -> WikiScratchpadContext {
        let context = try adoptingCreation(outcome, drafts: drafts, wiki: wiki, workingSource: freeSource)
        freeSource = ""
        return context
    }

    var isValid: Bool {
        !invalidated && drafts.sessionID == sessionID && drafts.owner == owner && wiki.owner == owner
            && drafts.draft(id: draftID) != nil
    }
    var draft: WikiDraft? { isValid ? drafts.draft(id: draftID) : nil }
    var filename: String { draft?.document.title ?? "Wiki document" }
    var location: String {
        guard let document = draft?.document else { return "Wiki" }
        return "Wiki · \(document.connection.name)/\(document.path)"
    }
    var pending: WikiPendingSave? {
        guard let draft else { return nil }
        return wiki.pendingSaves.first { WikiDraft.sameFile($0.document, draft.document) }
    }
    var currentDocument: WikiDocument? { pending?.currentDocument ?? draft?.currentDocument }
    var canSave: Bool {
        isValid && !isWorking && draft?.document.canEdit == true
    }
    var hasConflict: Bool {
        draft?.needsFreshBase == true || pending?.phase == .conflict || pending?.hasLaterExternalChange == true
    }
    /// A journal describes submitted bytes, not necessarily the text now being edited.
    var isSaved: Bool {
        guard let draft, !draft.document.isNewFile, !hasConflict else { return false }
        if let pending {
            return pending.verifiedCommitted && Data(draft.workingSource.utf8) == pending.currentDocument?.originalBytes
        }
        return !draft.isDirty
    }
    var saveTitle: String {
        if isWorking { return "Saving…" }
        if hasConflict { return "Review changes" }
        return failure != nil || (pending != nil && !isSaved) ? "Retry" : "Save"
    }
    var canAcceptCurrentBase: Bool {
        guard !isWorking, let current = currentDocument, current.canEdit else { return false }
        if let pending { return pending.phase == .conflict || (pending.phase == .committed && pending.hasLaterExternalChange) }
        return draft?.needsFreshBase == true
    }
    var shortStatus: String {
        if isWorking { return "Saving…" }
        if hasConflict { return "File changed on host" }
        if isSaved { return "Saved" }
        return "Not saved to host"
    }

    var status: String {
        guard isValid else { return WikiDraftError.inactive.localizedDescription }
        if isWorking { return "Saving to Wiki…" }
        if hasConflict { return "This file changed on the host. Review both versions before saving. Your edits are still here." }
        if isSaved { return "Saved to Wiki" }
        if let failure { return failure }
        if let message = drafts.persistenceFailure { return message }
        if pending != nil { return "Couldn’t confirm the save on your host. Retry to check it safely. Your edits are still here." }
        return "Changes not saved to Wiki"
    }

    var binding: Binding<String> {
        Binding(get: { self.draft?.workingSource ?? "" }, set: { value in
            guard self.isValid else { return }
            do { try self.drafts.update(id: self.draftID, workingSource: value) }
            catch {
                self.failure = WikiDraftError.message(error)
                self.rejectedEditRevision &+= 1
            }
        })
    }

    func clearFailure() { failure = nil }

    /// Returns false without invoking parent dismissal/staging when preservation
    /// fails. The existing parent still owns destination and recipient checks.
    @discardableResult
    func preserveForLeaving() -> Bool {
        do { try flush(); return true }
        catch { failure = WikiDraftError.message(error); return false }
    }

    func flush() throws {
        try requireValid()
        try drafts.flush()
    }

    /// Host transactions/recovery are intentionally NOT discarded with edits.
    /// They may still have affected the host file and stay in Wiki recovery.
    func discard() throws {
        try requireValid()
        guard !isWorking else { throw WikiError.recoveryRequired }
        try drafts.discard(id: draftID)
        invalidate()
    }

    func save() {
        guard canSave, !hasConflict else { return }
        do {
            try flush()
            if let pending {
                if pending.phase == .failed, Data((draft?.workingSource ?? "").utf8) == pending.bytes {
                    run(.resume(pending.id))
                    return
                } else if pending.verifiedCommitted || pending.phase == .failed {
                    try finishRecordedSave()
                } else {
                    // One explicit Retry checks/resumes the SAME immutable save.
                    // Never send a replacement while its outcome is unknown.
                    run(.resume(pending.id))
                    return
                }
            }
            guard let draft else { return }
            run(.save(draft.document, draft.workingSource))
        } catch { failure = WikiDraftError.message(error) }
    }

    func checkStatus() {
        guard let pending, !isWorking else { return }
        run(.status(pending.id))
    }

    func resumeUpload() {
        guard let pending, !isWorking,
              pending.phase == .receiving || (!pending.admitted && (pending.phase == .prepared || pending.phase == .indeterminate)) else { return }
        run(.resume(pending.id))
    }

    /// Call only after explicit confirmation. This does not immediately retry a
    /// save: Save changes remains a separate deliberate user action.
    func acceptCurrentBase() throws {
        try requireValid()
        guard canAcceptCurrentBase, let current = currentDocument else { throw WikiError.recoveryRequired }
        let operation = pending
        try drafts.acceptFreshBase(id: draftID, current: current, operation: operation)
        if let operation { try wiki.discardSave(operationID: operation.id) }
        failure = nil
    }

    /// Finish a verified save, or archive a known failed submission before a
    /// deliberate replacement with newer edits. Never retire uncertainty.
    func finishRecordedSave() throws {
        try requireValid()
        guard !isWorking, let pending, pending.verifiedCommitted || pending.phase == .failed else {
            throw WikiError.recoveryRequired
        }
        if pending.verifiedCommitted {
            try completeVerifiedSave(pending)
        } else {
            try drafts.retainRecovery(id: draftID, operation: pending)
            try wiki.discardSave(operationID: pending.id)
        }
        failure = nil
    }

    func removeRecoveryCopy(_ copyID: UUID) throws {
        try requireValid()
        try drafts.removeRecoveryCopy(draftID: draftID, copyID: copyID)
    }

    func report(_ error: Error) { if isValid { failure = WikiDraftError.message(error) } }

    /// Safe to call on disappearing/background. An in-flight transaction remains
    /// in WikiStore's journal for status reconciliation, never an automatic retry.
    func sceneChanged(_ phase: ScenePhase) {
        guard phase != .active else { return }
        cancelWork()
        if isValid { _ = preserveForLeaving() }
    }

    func cancelWork() {
        task?.cancel()
        task = nil
        taskID = UUID()
        isWorking = false
    }

    func invalidate() {
        cancelWork()
        invalidated = true
        failure = nil
        if let invalidationID { drafts.removeInvalidation(invalidationID) }
        invalidationID = nil
    }

    private static func needsExactSource(_ source: String) -> Bool {
        if source.unicodeScalars.contains(where: { $0.value == 0xFEFF || $0.value == 0x0D })
            || source.hasPrefix("---") || source.hasPrefix("+++") { return true }
        guard case .rich(let document) = RichDraftMarkdown.importSource(source),
              let exported = try? RichDraftMarkdown.export(document) else { return true }
        // File editing is stricter than free drafting: semantically equivalent
        // Markdown is insufficient if a rich edit would normalize other bytes.
        return Data(exported.utf8) != Data(source.utf8)
    }

    private func requireValid() throws {
        guard isValid else { throw WikiDraftError.inactive }
    }

    private enum Work {
        case save(WikiDocument, String), status(String), resume(String)
    }

    private func run(_ work: Work) {
        guard isValid, !isWorking else { return }
        isWorking = true
        failure = nil
        let ticket = UUID()
        taskID = ticket
        task = Task { @MainActor [weak self] in
            guard let self, self.isValid, self.taskID == ticket, !Task.isCancelled else { return }
            defer {
                if self.taskID == ticket { self.isWorking = false; self.task = nil }
            }
            do {
                let result: WikiPendingSave
                switch work {
                case .save(let document, let source): result = try await self.wiki.save(document: document, workingSource: source)
                case .status(let id): result = try await self.wiki.reconcileSave(operationID: id)
                case .resume(let id): result = try await self.wiki.retrySave(operationID: id)
                }
                guard self.isValid, self.taskID == ticket, !Task.isCancelled else { return }
                // A returned RPC is not success. Only this verified branch can
                // advance the draft base; concurrent edits remain untouched.
                if result.verifiedCommitted {
                    do { try self.completeVerifiedSave(result) }
                    catch {
                        self.failure = "Your host received this copy, but this device couldn’t finish keeping your edits. Keep the editor open and retry, or export a copy."
                    }
                } else if !self.hasConflict {
                    self.failure = "Couldn’t save to your host. Retry when it’s available. Your edits are still here."
                }
                guard self.isValid, self.taskID == ticket else { return }
                self.onSaveResult(result)
            } catch is CancellationError { }
            catch {
                guard self.isValid, self.taskID == ticket, !Task.isCancelled else { return }
                self.failure = error is WikiDraftError
                    ? WikiDraftError.message(error) : WikiError.saveMessage(error)
            }
        }
    }

    /// The host readback and current edits are durable before journal retirement.
    /// Successful saves are not an ever-growing local version history. Existing
    /// conflict/failure copies are untouched; newer edits are never replaced.
    private func completeVerifiedSave(_ outcome: WikiPendingSave) throws {
        try drafts.applyVerifiedCommit(id: draftID, outcome: outcome)
        guard let current = outcome.currentDocument, let draft,
              draft.document.baseRevision == current.baseRevision,
              draft.document.originalBytes == current.originalBytes else { throw WikiError.recoveryRequired }
        try wiki.finishVerifiedSave(operationID: outcome.id)
    }
}
