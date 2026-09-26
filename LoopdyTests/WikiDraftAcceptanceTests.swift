import Foundation
import Testing
@testable import Loopdy

@MainActor
struct WikiDraftAcceptanceTests {
    private let owner = WikiOwner(accountID: "fixture-account", hostID: "fixture-host",
                                  profileID: "default", deviceID: "fixture-device", authorizationEpoch: "3")
    private func document(_ source: String, path: String = "notes.md", owner: WikiOwner? = nil) throws -> WikiDocument {
        let root = WikiRoot(wikiId: "fixture-root", name: "Fixture Wiki", writable: true,
                            sourceKind: "files", generation: String(repeating: "a", count: 32))
        let connection = WikiConnection(owner: owner ?? self.owner, name: "Fixture Wiki", root: root, readOnly: false)
        let bytes = Data(source.utf8)
        return try WikiDocument(connection: connection, path: path,
            bytes: WikiBytes(data: bytes, revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(bytes))"))
    }

    @Test func constructionIsInertAndColdRestorationPreservesExactBytes() throws {
        let persistence = WikiDraftMemoryProbe()
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        #expect(persistence.calls == 0)
        let source = "\u{feff}# Cafe\u{301}\r\n\r\n- item  \r\n"
        let draft = try store.open(document: document(source))
        let edited = source + "A 🐈\r\n"
        try store.update(id: draft.id, workingSource: edited)
        try store.flush()
        let reopened = WikiDraftStore(owner: owner, persistence: persistence)
        #expect(reopened.drafts.isEmpty)
        try reopened.restoreLocalState()
        #expect(Data(reopened.drafts.first!.workingSource.utf8) == Data(edited.utf8))
        #expect(reopened.drafts.first?.document.originalBytes == Data(source.utf8))
        try reopened.setContext(owner: nil)
        try store.setContext(owner: nil)
    }

    @Test func differentFilesAndChangedBasesNeverOverwriteDirtyWork() throws {
        let store = WikiDraftStore(owner: owner, persistence: WikiDraftMemoryProbe())
        let first = try store.open(document: document("original"))
        try store.update(id: first.id, workingSource: "my edits")
        _ = try store.open(document: document("other", path: "other.md"))
        let reopened = try store.open(document: document("external edit"))
        #expect(reopened.id == first.id)
        #expect(reopened.workingSource == "my edits")
        #expect(reopened.document.originalSource == "original")
        #expect(reopened.currentDocument?.originalSource == "external edit")
        #expect(reopened.needsFreshBase)
        #expect(store.drafts.count == 2)
        try store.setContext(owner: nil)
    }

    @Test func failedCheckpointRevokesOldBindingsButKeepsExactOwnerRecovery() throws {
        let persistence = WikiDraftMemoryProbe()
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        let draft = try store.open(document: document("original"))
        try store.update(id: draft.id, workingSource: "unsaved")
        persistence.fail = true
        #expect(throws: (any Error).self) { try store.setContext(owner: nil) }
        #expect(store.owner == nil)
        #expect(store.drafts.isEmpty)
        persistence.fail = false
        try store.setContext(owner: owner)
        try store.restoreLocalState()
        #expect(store.drafts.first?.workingSource == "unsaved")
        try store.flush()
        try store.setContext(owner: nil)
    }

    @Test func contextSwitchDeniesStaleEditorAndDeletionPreventsResurrection() throws {
        let persistence = WikiDraftMemoryProbe()
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        let wiki = WikiStore(owner: owner, client: nil, persistence: WikiJournalMemoryProbe())
        let draft = try store.open(document: document("original"))
        let context = try WikiScratchpadContext(drafts: store, wiki: wiki, draftID: draft.id)
        #expect(context.isValid)
        _ = try store.open(document: document("second", path: "second.md"))
        #expect(!context.isValid)
        context.binding.wrappedValue = "stale text"
        #expect(store.draft(id: draft.id)?.workingSource == "original")
        try store.deleteAccountData(accountID: owner.accountID)
        #expect(store.drafts.isEmpty)
        #expect(throws: (any Error).self) { try store.open(document: document("new")) }
    }

    @Test func failedDiscardPreservesDraftAndOversizeEditIsNotTruncated() throws {
        let persistence = WikiDraftMemoryProbe()
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        let draft = try store.open(document: document("original"))
        #expect(throws: (any Error).self) {
            try store.update(id: draft.id, workingSource: String(repeating: "x", count: WikiLimits.editBytes + 1))
        }
        #expect(store.drafts.first?.workingSource == "original")
        persistence.fail = true
        #expect(throws: (any Error).self) { try store.discard(id: draft.id) }
        #expect(store.drafts.first?.id == draft.id)
        persistence.fail = false
        try store.discard(id: draft.id)
        #expect(store.drafts.isEmpty)
    }

    @Test func verifiedAdoptionFailureRetriesWithoutLosingNewerEdits() throws {
        let persistence = WikiDraftMemoryProbe()
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        let original = try document("original")
        let draft = try store.open(document: original)
        try store.update(id: draft.id, workingSource: "saved")
        try store.flush()
        let current = try WikiDocument(connection: original.connection, path: original.path,
            bytes: WikiBytes(data: Data("saved".utf8), revision: "wiki-v1:\(original.root.generation):\(WikiLimits.digest(Data("saved".utf8)))"))
        let outcome = WikiPendingSave(operationId: "fixture-save", document: original,
            workingSource: "saved", sha256: WikiLimits.digest(Data("saved".utf8)),
            phase: .committed, nextOffset: 5, admitted: true,
            committedRevision: current.baseRevision, currentDocument: current)
        try store.update(id: draft.id, workingSource: "newer edits 🐈\r\n")
        persistence.fail = true
        #expect(throws: (any Error).self) { try store.applyVerifiedCommit(id: draft.id, outcome: outcome) }
        #expect(store.draft(id: draft.id)?.document.baseRevision == original.baseRevision)
        #expect(store.draft(id: draft.id)?.workingSource == "newer edits 🐈\r\n")
        persistence.fail = false
        try store.applyVerifiedCommit(id: draft.id, outcome: outcome)
        #expect(store.draft(id: draft.id)?.document.baseRevision == current.baseRevision)
        #expect(store.persistenceFailure == nil)
        let wiki = WikiStore(owner: owner, client: nil, persistence: WikiJournalMemoryProbe())
        let context = try WikiScratchpadContext(drafts: store, wiki: wiki, draftID: draft.id)
        #expect(context.preserveForLeaving())
        let reopened = WikiDraftStore(owner: owner, persistence: persistence)
        try reopened.restoreLocalState()
        #expect(reopened.draft(id: draft.id)?.workingSource == "newer edits 🐈\r\n")
        #expect(reopened.draft(id: draft.id)?.document.baseRevision == current.baseRevision)
    }

    @Test func realLocalPersistenceUsesPrivateProtectionAndErasesAccount() throws {
        // A sandbox/base-relative URL and its enumerated absolute URL identify
        // the same directory without being equal URL values.
        let directory = URL(fileURLWithPath: "wiki-draft-test-" + UUID().uuidString,
                            isDirectory: true, relativeTo: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiDraftLocalPersistence(directory: directory,
            protector: WikiDraftProtectionProbe(), availability: WikiDraftAvailable())
        let store = WikiDraftStore(owner: owner, persistence: persistence)
        let draft = try store.open(document: document("\u{feff}one\r\n"))
        try store.update(id: draft.id, workingSource: "\u{feff}two\r\n")
        try store.flush()
        let stored = try persistence.load(owner: owner)
        let readback = try #require(stored)
        #expect(Data(readback.drafts[0].workingSource.utf8) == Data("\u{feff}two\r\n".utf8))
        let accountDirectory = directory.appendingPathComponent(WikiLimits.digest(Data(owner.accountID.utf8)))
        let files = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: [.isExcludedFromBackupKey])
        #expect(files.count == 1)
        #expect(try files[0].resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Simulator files do not expose an iOS protection-class attribute. The
        // injected forwarding probe verifies the actual complete-protection
        // request; encryption while locked remains a hardware-only property.
        #expect(LoopdyLocalFileProtector.fileProtection(for: .privateVisual) == .complete)
        try store.deleteAccountData(accountID: owner.accountID)
        #expect(!FileManager.default.fileExists(atPath: accountDirectory.path))
    }
}

private struct WikiDraftProtectionProbe: LoopdyLocalFileProtecting {
    func prepareDirectory(_ directory: URL, protection: LoopdyLocalProtectionClass, fileManager: FileManager) throws {
        #expect(protection == .privateVisual)
        try LoopdyLocalFileProtector().prepareDirectory(directory, protection: protection, fileManager: fileManager)
    }
    func write(_ data: Data, to file: URL, protection: LoopdyLocalProtectionClass) throws {
        #expect(protection == .privateVisual)
        try LoopdyLocalFileProtector().write(data, to: file, protection: protection)
    }
    func apply(_ protection: LoopdyLocalProtectionClass, to file: URL, fileManager: FileManager) throws {
        #expect(protection == .privateVisual)
        try LoopdyLocalFileProtector().apply(protection, to: file, fileManager: fileManager)
    }
}

private struct WikiDraftAvailable: LoopdyProtectedDataAvailabilityProviding {
    var isProtectedDataAvailable: Bool { true }
}
@MainActor private final class WikiDraftMemoryProbe: WikiDraftPersistence {
    var states: [WikiOwner: WikiDraftState] = [:]
    var calls = 0
    var fail = false
    func load(owner: WikiOwner) throws -> WikiDraftState? { calls += 1; return states[owner] }
    func save(_ state: WikiDraftState) throws {
        calls += 1
        if fail { throw WikiDraftError.persistence }
        states[state.owner] = state
    }
    func deleteAccount(accountID: String) throws {
        calls += 1
        if fail { throw WikiDraftError.persistence }
        states = states.filter { $0.key.accountID != accountID }
    }
}
@MainActor private final class WikiJournalMemoryProbe: WikiPersistence {
    var folders: [WikiFolderPreference] = []
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] { folders }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws { self.folders = folders }
    func load(owner: WikiOwner) throws -> WikiLocalState? { nil }
    func save(_ state: WikiLocalState) throws { }
    func deleteAccount(accountID: String) throws { }
}
