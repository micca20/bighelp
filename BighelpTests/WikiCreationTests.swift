import Foundation
import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct WikiCreationTests {
    @Test func namedCreationUsesAbsentPreconditionAndVerifiedReadback() async throws {
        let client = WikiCreationProbe()
        let memory = WikiCreationMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "nested", filename: "Plan.md")
        let result = try await store.save(document: document, workingSource: "\u{FEFF}# Plan\r\n")
        #expect(document.path == "nested/Plan.md")
        #expect(document.isNewFile)
        #expect(client.submitted?.document.baseRevision == "wiki-new-v1:" + client.root.generation)
        #expect(result.verifiedCommitted)
        #expect(result.currentDocument?.originalSource == "\u{FEFF}# Plan\r\n")
        #expect(memory.state?.saves.first?.verifiedCommitted == true)
        try WikiDraftLimits.validateDocument(document, owner: client.owner)
    }

    @Test func verifiedCreationBecomesRevisionCheckedEditorForNextSave() async throws {
        let client = WikiCreationProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        let drafts = WikiDraftStore(owner: client.owner, persistence: WikiCreationDraftMemory())
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let result = try await store.save(document: document, workingSource: "First")
        var freeSource = "First"
        let context = try WikiScratchpadContext.adoptingCreation(result, drafts: drafts,
            wiki: store, freeSource: &freeSource)
        #expect(freeSource.isEmpty)
        #expect(context.canSave)
        #expect(context.draft?.document.isNewFile == false)
        #expect(context.draft?.document.baseRevision == result.committedRevision)
        #expect(context.binding.wrappedValue == "First")
        #expect(store.pendingSaves.isEmpty)
        context.binding.wrappedValue = "Second"
        context.save()
        for _ in 0..<100 where context.isWorking { await Task.yield() }
        #expect(!context.isWorking)
        #expect(context.pending == nil)
        #expect(store.pendingSaves.isEmpty)
        #expect(client.submitted?.document.baseRevision == result.committedRevision)
        #expect(context.isSaved)
        #expect(context.draft?.document.originalBytes == Data("Second".utf8))
        let secondRevision = context.draft?.document.baseRevision
        context.binding.wrappedValue = "Third"
        #expect(!context.isSaved)
        context.save()
        for _ in 0..<100 where context.isWorking { await Task.yield() }
        #expect(context.isSaved)
        #expect(context.pending == nil)
        #expect(client.submitted?.document.baseRevision == secondRevision)
        #expect(context.draft?.document.originalBytes == Data("Third".utf8))
        #expect(client.commitCalls == 3)
        #expect(context.draft?.isDirty == false)
        context.sceneChanged(.inactive)
        #expect(context.failure == nil)
        #expect(context.binding.wrappedValue == "Third")
    }

    @Test func recoveredCreationPreservesNewerFreeDraft() async throws {
        let client = WikiCreationProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        let drafts = WikiDraftStore(owner: client.owner, persistence: WikiCreationDraftMemory())
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let result = try await store.save(document: document, workingSource: "A")
        var freeSource = "B"
        let context = try WikiScratchpadContext.adoptingCreation(result, drafts: drafts,
            wiki: store, freeSource: &freeSource)
        #expect(freeSource.isEmpty)
        #expect(context.binding.wrappedValue == "B")
        #expect(context.draft?.document.originalSource == "A")
        #expect(context.draft?.isDirty == true)
        #expect(drafts.draft(id: context.draftID)?.workingSource == "B")
        #expect(client.commitCalls == 1)
    }

    @Test func discardedCreationUnlocksFormWithoutChangingFreeSource() async throws {
        let client = WikiCreationProbe()
        client.conflict = true
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        var document: WikiDocument? = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let source = "Keep my free draft"
        let result = try await store.save(document: #require(document), workingSource: source)
        #expect(result.phase == .conflict)
        WikiCreationState.resetRetiredDocument(&document, pendingID: result.id, saving: false)
        #expect(document != nil)
        try store.discardSave(operationID: result.id)
        WikiCreationState.resetRetiredDocument(&document, pendingID: nil, saving: true)
        #expect(document != nil) // Initial admission may not have journaled yet.
        WikiCreationState.resetRetiredDocument(&document, pendingID: store.pendingSaves.first?.id, saving: false)
        #expect(document == nil)
        let renamed = try store.newDocument(root: client.root, folder: "", filename: "Renamed.md")
        client.conflict = false
        let retried = try await store.save(document: renamed, workingSource: source)
        #expect(retried.document.path == "Renamed.md")
        #expect(retried.workingSource == "Keep my free draft")
        #expect(retried.verifiedCommitted)
    }

    @Test func inactiveRecoveryCancelsResumedAdmissionWithoutCommit() async throws {
        let client = WikiCreationProbe()
        client.failBegin = true
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        do { _ = try await store.save(document: document, workingSource: "A") } catch { }
        let pending = try #require(store.pendingSaves.first)
        client.failBegin = false
        client.operationNotFound = true
        client.suspendBegin = true
        let work = WikiRecoveryWork()
        var finished = false
        work.run(store: store) {
            defer { finished = true }
            _ = try await store.resumeSave(operationID: pending.id)
        }
        for _ in 0..<100 where client.beginContinuation == nil { await Task.yield() }
        let continuation = try #require(client.beginContinuation)
        work.sceneChanged(.inactive)
        continuation.resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(finished)
        #expect(client.commitCalls == 0)
        #expect(store.pendingSaves.first?.id == pending.id)
        #expect(store.pendingSaves.first?.workingSource == "A")
        #expect(work.failure == nil)
    }

    @Test func inactiveAdoptedEditorCancelsSubsequentSaveAndPreservesDraft() async throws {
        let client = WikiCreationProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        let memory = WikiCreationDraftMemory()
        let drafts = WikiDraftStore(owner: client.owner, persistence: memory)
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let result = try await store.save(document: document, workingSource: "First")
        let context = try WikiScratchpadContext.adoptingCreation(result, drafts: drafts, wiki: store)
        context.sceneChanged(.inactive)
        #expect(context.failure == nil) // No work to cancel after terminal success.
        #expect(context.isValid)
        context.binding.wrappedValue = "Second"
        client.suspendBegin = true
        context.save()
        for _ in 0..<100 where client.beginContinuation == nil { await Task.yield() }
        let continuation = try #require(client.beginContinuation)
        context.sceneChanged(.background)
        continuation.resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(client.commitCalls == 1)
        #expect(!context.isWorking)
        #expect(context.failure == nil)
        #expect(context.binding.wrappedValue == "Second")
        #expect(memory.state?.drafts.first?.workingSource == "Second")
        #expect(store.pendingSaves.first?.workingSource == "Second")
        #expect(store.pendingSaves.first?.verifiedCommitted == false)
    }

    @Test func localReadOnlyConnectionCannotBeBypassedBySelectingItsRoot() async throws {
        let client = WikiCreationProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        _ = try store.connect(name: "Protected locally", root: client.root, readOnly: true)
        #expect(throws: WikiError.readOnly) {
            try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        }
        #expect(client.submitted == nil)
    }

    @Test func legacyHostsKeepEditingButCannotAdmitCreation() async throws {
        let client = WikiCreationProbe()
        client.root.supportsCreation = nil
        let decoded = try JSONDecoder().decode(WikiRoot.self, from: JSONEncoder().encode(client.root))
        #expect(decoded.allowsEditing)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        #expect(throws: WikiError.creationUnsupported) {
            try store.newDocument(root: decoded, folder: "", filename: "Plan.md")
        }
        #expect(store.pendingSaves.isEmpty)
        #expect(store.connections.isEmpty)
    }

    @Test func retryingSameFolderOffsetRestartsRequestWithoutLosingPagePosition() {
        let first = WikiCreationState.FolderRequest(rootID: "notes", folder: "nested", offset: 100, refreshID: UUID())
        let retry = WikiCreationState.FolderRequest(rootID: first.rootID, folder: first.folder,
            offset: first.offset, refreshID: UUID())
        #expect(first != retry)
        #expect(retry.offset == 100)
        #expect(retry.folder == "nested")
    }

    @Test func filenameIsOneExactMarkdownComponent() throws {
        #expect(try WikiNavigation.newFilePath(folder: "nested", filename: "Plan.md") == "nested/Plan.md")
        for filename in ["", "../Plan.md", "child/Plan.md", ".hidden.md", "Plan.txt", "Plan.md\n"] {
            #expect(throws: WikiError.invalidPath) { try WikiNavigation.newFilePath(folder: "", filename: filename) }
        }
        #expect(throws: WikiError.invalidPath) { try WikiNavigation.newFilePath(folder: "../outside", filename: "Plan.md") }
    }

    @Test func ownerChangeBeforeCreationDoesNotCreateConnectionOrJournal() async throws {
        let client = WikiCreationProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        store.setContext(owner: nil, client: nil)
        #expect(throws: WikiError.unavailable) {
            try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        }
        #expect(store.pendingSaves.isEmpty)
    }

    @Test func recordedCommitWithoutMatchingReadbackIsNotSaved() async throws {
        let client = WikiCreationProbe()
        client.readback = Data("Later external edit".utf8)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiCreationMemory())
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let result = try await store.save(document: document, workingSource: "My draft")
        #expect(!result.verifiedCommitted)
        #expect(result.hasLaterExternalChange)
        #expect(result.workingSource == "My draft")
        let drafts = WikiDraftStore(owner: client.owner, persistence: WikiCreationDraftMemory())
        #expect(throws: WikiError.recoveryRequired) {
            try WikiScratchpadContext.adoptingCreation(result, drafts: drafts, wiki: store)
        }
        #expect(drafts.drafts.isEmpty)
        #expect(store.pendingSaves.count == 1)
    }

    @Test func cancelledCreationKeepsJournalAndNeverCommitsLateAdmission() async throws {
        let client = WikiCreationProbe()
        client.suspendBegin = true
        let memory = WikiCreationMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        try await store.discoverRoots()
        let document = try store.newDocument(root: client.root, folder: "", filename: "Plan.md")
        let task = Task { try await store.save(document: document, workingSource: "Keep me") }
        for _ in 0..<100 where client.beginContinuation == nil { await Task.yield() }
        let continuation = try #require(client.beginContinuation)
        task.cancel()
        continuation.resume()
        do { _ = try await task.value; Issue.record("Cancelled upload must not commit") }
        catch { }
        #expect(client.commitCalls == 0)
        #expect(memory.state?.saves.first?.workingSource == "Keep me")
        #expect(memory.state?.saves.first?.verifiedCommitted == false)
    }
}

@MainActor private final class WikiCreationDraftMemory: WikiDraftPersistence {
    var state: WikiDraftState?
    func load(owner: WikiOwner) throws -> WikiDraftState? { state }
    func save(_ state: WikiDraftState) throws {
        try WikiDraftLimits.validate(state)
        self.state = state
    }
    func deleteAccount(accountID: String) throws { state = nil }
}

@MainActor private final class WikiCreationMemory: WikiPersistence {
    var folders: [WikiFolderPreference] = []
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] { folders }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws { self.folders = folders }
    var state: WikiLocalState?
    func load(owner: WikiOwner) throws -> WikiLocalState? { state }
    func save(_ state: WikiLocalState) throws { self.state = state }
    func deleteAccount(accountID: String) throws { state = nil }
}

@MainActor private final class WikiCreationProbe: WikiClientProtocol {
    let owner = WikiOwner(accountID: "fixture", hostID: "host", profileID: "default", deviceID: "device", authorizationEpoch: "1")
    var root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: "files",
                        generation: String(repeating: "a", count: 32), supportsCreation: true)
    var submitted: WikiPendingSave?
    var uploaded = Data()
    var readback: Data?
    var conflict = false
    var operationNotFound = false
    var failBegin = false
    var suspendBegin = false
    var beginContinuation: CheckedContinuation<Void, Never>?
    var commitCalls = 0
    func roots() async throws -> [WikiRoot] { [root] }
    func connect(folderPath: String) async throws -> WikiRoot { throw WikiError.unavailable }
    func resolve(folderPath: String) async throws -> WikiRoot { throw WikiError.unavailable }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage { throw WikiError.unavailable }
    func list(root: WikiRoot, path: String, offset: Int, revision: String?) async throws -> WikiDirectory { throw WikiError.unavailable }
    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int) async throws -> WikiSearchPage { throw WikiError.unavailable }
    func image(root: WikiRoot, path: String) async throws -> WikiBytes { throw WikiError.unavailable }
    func read(root: WikiRoot, path: String) async throws -> WikiBytes {
        let bytes = readback ?? uploaded
        return WikiBytes(data: bytes, revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(bytes))")
    }
    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse {
        submitted = save
        if failBegin { throw WikiError.unavailable }
        uploaded = Data()
        if suspendBegin { await withCheckedContinuation { beginContinuation = $0 } }
        return WikiSaveResponse(operationId: save.id, status: .receiving, nextOffset: 0,
                                totalBytes: save.bytes.count, revision: nil, errorCode: nil)
    }
    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse {
        #expect(offset == uploaded.count)
        uploaded.append(data)
        return WikiSaveResponse(operationId: operationID, status: .receiving, nextOffset: uploaded.count,
                                totalBytes: submitted?.bytes.count, revision: nil, errorCode: nil)
    }
    func commit(operationID: String) async throws -> WikiSaveResponse {
        commitCalls += 1
        if conflict {
            return WikiSaveResponse(operationId: operationID, status: .conflict, nextOffset: nil,
                totalBytes: nil, revision: nil, errorCode: nil)
        }
        return WikiSaveResponse(operationId: operationID, status: .committed, nextOffset: nil, totalBytes: nil,
                         revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(uploaded))", errorCode: nil)
    }
    func status(operationID: String) async throws -> WikiSaveResponse {
        if operationNotFound { throw WikiError.remote("OPERATION_NOT_FOUND") }
        return try await commit(operationID: operationID)
    }
}
