import Foundation
import Observation

@MainActor
@Observable
final class WikiStore {
    private(set) var owner: WikiOwner?
    private(set) var connections: [WikiConnection] = []
    private(set) var savedFolders: [WikiFolderPreference] = []
    private(set) var isLoading = false
    private(set) var authorizedRoots: [WikiRoot] = []
    private(set) var pendingSaves: [WikiPendingSave] = []
    private(set) var document: WikiDocument?
    private(set) var directory: WikiDirectory?
    private(set) var entries: [WikiEntry] = []
    private(set) var searchPage: WikiSearchPage?
    private(set) var matches: [WikiSearchMatch] = []
    private(set) var selectedConnectionID: UUID?
    private(set) var anchor: String? {
        didSet { anchorRequestID = UUID() }
    }
    private(set) var anchorRequestID = UUID()
    private(set) var linkChoiceAnchor: String?
    private(set) var linkChoices: [WikiSearchMatch] = []
    private(set) var linkSearchIncomplete = false

    @ObservationIgnored private var client: (any WikiClientProtocol)?
    @ObservationIgnored private let persistence: any WikiPersistence
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var navigationGeneration = UUID()
    @ObservationIgnored private var cancellations: [UUID: () -> Void] = [:]
    @ObservationIgnored private var activeSaves: Set<String> = []
    @ObservationIgnored private var imageLoads = 0
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var preparePreferences: (@MainActor () throws -> Void)?

    init(owner: WikiOwner?, client: (any WikiClientProtocol)?, persistence: (any WikiPersistence)? = nil) {
        self.owner = owner
        self.client = client
        self.persistence = persistence ?? WikiLocalPersistence()
    }

    var isAvailable: Bool { owner != nil && owner == client?.owner }
    var canDisconnectOnHost: Bool { owner?.isNative == true && isAvailable && client?.supportsRemoteDisconnect == true }
    var selectedConnection: WikiConnection? { connections.first { $0.id == selectedConnectionID } }

    /// Call synchronously on ANY account, selected-host, profile, device or epoch change.
    /// Cancellations also propagate to prepared Link requests; late results never publish.
    func setContext(owner: WikiOwner?, client: (any WikiClientProtocol)?,
                    preparePreferences: (@MainActor () throws -> Void)? = nil) {
        for cancel in cancellations.values { cancel() }
        cancellations.removeAll()
        generation = UUID()
        navigationGeneration = UUID()
        activeSaves.removeAll()
        self.owner = owner
        self.client = client
        self.preparePreferences = preparePreferences
        connections = []
        savedFolders = []
        authorizedRoots = []
        pendingSaves = []
        restored = false
        selectedConnectionID = nil
        clearContent()
        isLoading = false
    }

    func restoreLocalState() throws {
        guard let owner else { return }
        // A read can create a removal tombstone. Authenticated migration must
        // finish first, even for direct callers and an already-restored store.
        try preparePreferences?()
        guard !restored else { return }
        savedFolders = try persistence.loadFolders(owner: owner)
        if let state = try persistence.load(owner: owner) {
            // Recovery retains its exact Link or native principal owner and is never resumed here.
            pendingSaves = state.saves
        }
        restored = true
    }

    private func persist() throws {
        guard let owner else { throw WikiError.ownerChanged }
        try persistence.save(WikiLocalState(owner: owner, connections: connections, saves: pendingSaves))
    }

    private func require(_ connection: WikiConnection) throws {
        guard owner == connection.owner, connections.contains(where: {
            $0.id == connection.id && $0.owner == connection.owner && $0.root == connection.root
                && $0.readOnly == connection.readOnly
        }) else { throw WikiError.ownerChanged }
    }

    private func owned<T: Sendable>(_ work: @escaping @MainActor (any WikiClientProtocol) async throws -> T) async throws -> T {
        guard let owner, let client, client.owner == owner else { throw WikiError.unavailable }
        let epoch = generation
        let id = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await work(client)
        }
        cancellations[id] = { task.cancel() }
        isLoading = true
        defer {
            if generation == epoch {
                cancellations[id] = nil
                isLoading = !cancellations.isEmpty
            }
        }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == epoch, self.owner == owner else { throw WikiError.ownerChanged }
        return value
    }

    func folderSuggestions(parentPath: String, prefix: String = "", offset: Int = 0) async throws -> HermesWorkspaceFolderPage {
        try await owned { try await $0.folderSuggestions(parentPath: parentPath, prefix: prefix, offset: offset) }
    }

    func discoverRoots() async throws {
        try restoreLocalState()
        let epoch = generation
        let roots = try await owned { try await $0.roots() }
        guard generation == epoch else { throw WikiError.ownerChanged }
        authorizedRoots = roots
        var firstFailure: (any Error)?
        for folder in savedFolders {
            guard !connections.contains(where: { $0.id == folder.id }) else { continue }
            do {
                let root = try await owned { client in
                    if client.owner.isNative {
                        return try await client.resolve(folderPath: folder.folderPath)
                    }
                    return try await client.connect(folderPath: folder.folderPath)
                }
                guard generation == epoch, savedFolders.contains(folder), let owner,
                      !connections.contains(where: { $0.id == folder.id }) else { continue }
                guard root.folderPath == folder.folderPath else { throw WikiError.invalidResponse }
                recordRoot(root)
                connections.append(WikiConnection(id: folder.id, owner: owner, name: folder.name,
                    root: root, readOnly: folder.readOnly == true || !root.allowsEditing))
            } catch {
                guard generation == epoch else { throw WikiError.ownerChanged }
                try Task.checkCancellation()
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func recordRoot(_ root: WikiRoot) {
        authorizedRoots.removeAll { $0.wikiId == root.wikiId }
        authorizedRoots.append(root)
    }

    func connect(name: String, root: WikiRoot, readOnly: Bool = false) throws -> WikiConnection {
        try restoreLocalState()
        guard let owner, isAvailable, authorizedRoots.contains(root) else { throw WikiError.unavailable }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else { throw WikiError.invalidPath }
        guard connections.count < WikiLimits.maxConnections else { throw WikiError.quota }
        let connection = WikiConnection(owner: owner, name: name, root: root,
                                        readOnly: readOnly || !root.allowsEditing)
        if let path = root.folderPath {
            var folders = savedFolders.filter { $0.folderPath != path }
            folders.append(WikiFolderPreference(id: connection.id, name: name, folderPath: path, readOnly: readOnly))
            try persistence.saveFolders(folders, owner: owner)
            savedFolders = folders
            connections.removeAll { $0.root.folderPath == path }
        }
        connections.append(connection)
        return connection
    }

    func connect(name: String, folderPath: String, readOnly: Bool = false) async throws -> WikiConnection {
        try restoreLocalState()
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedName.utf8.count <= 256 else { throw WikiError.invalidPath }
        guard connections.count < WikiLimits.maxConnections else { throw WikiError.quota }
        try WikiLimits.validateFolderPath(folderPath)
        let epoch = generation
        let folders = savedFolders
        let root = try await owned { try await $0.connect(folderPath: folderPath) }
        guard generation == epoch, savedFolders == folders else { throw WikiError.ownerChanged }
        guard root.folderPath == folderPath else { throw WikiError.invalidResponse }
        recordRoot(root)
        return try connect(name: requestedName.isEmpty ? root.name : requestedName, root: root, readOnly: readOnly)
    }

    /// Local disconnect never revokes a host grant and never destroys save recovery.
    func disconnect(_ connection: WikiConnection) throws {
        try require(connection)
        guard !pendingSaves.contains(where: { $0.document.connection.id == connection.id && activeSaves.contains($0.id) }) else {
            throw WikiError.recoveryRequired
        }
        try removeFolder(id: connection.id)
        connections.removeAll { $0.id == connection.id }
        if selectedConnectionID == connection.id {
            navigationGeneration = UUID()
            selectedConnectionID = nil
            clearContent()
        }
    }

    /// Explicit principal-wide revocation, never used for local removal, logout or cache cleanup.
    func disconnectOnHost(_ connection: WikiConnection) async throws {
        try require(connection)
        guard canDisconnectOnHost else { throw WikiError.remote("CAPABILITY_UNSUPPORTED") }
        let epoch = generation
        try await owned { try await $0.disconnect(root: connection.root) }
        guard epoch == generation, owner == connection.owner else { throw WikiError.ownerChanged }
        let removed = connections.filter { $0.root.wikiId == connection.root.wikiId }
        let ids = Set(removed.map(\.id))
        let paths = Set(removed.compactMap(\.root.folderPath))
        connections.removeAll { $0.root.wikiId == connection.root.wikiId }
        authorizedRoots.removeAll { $0.wikiId == connection.root.wikiId }
        if let selectedConnectionID, ids.contains(selectedConnectionID) {
            navigationGeneration = UUID()
            self.selectedConnectionID = nil
            clearContent()
        }
        let folders = savedFolders.filter { !ids.contains($0.id) && !paths.contains($0.folderPath) }
        do {
            try persistence.saveFolders(folders, owner: connection.owner)
            savedFolders = folders
            try persist()
        } catch {
            throw WikiError.remote("LOCAL_DISCONNECT_CLEANUP_FAILED")
        }
    }

    func renameFolder(id: UUID, name: String) throws {
        try restoreLocalState()
        guard let owner else { throw WikiError.ownerChanged }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              let index = savedFolders.firstIndex(where: { $0.id == id }) else { throw WikiError.invalidPath }
        var folders = savedFolders
        folders[index].name = name
        try persistence.saveFolders(folders, owner: owner)
        savedFolders = folders
        if let index = connections.firstIndex(where: { $0.id == id }) { connections[index].name = name }
    }

    /// Also permits removing an unavailable folder without reconnecting it first.
    func removeFolder(id: UUID) throws {
        try restoreLocalState()
        guard let owner else { throw WikiError.ownerChanged }
        guard !pendingSaves.contains(where: { $0.document.connection.id == id && activeSaves.contains($0.id) }) else {
            throw WikiError.recoveryRequired
        }
        let folders = savedFolders.filter { $0.id != id }
        try persistence.saveFolders(folders, owner: owner)
        savedFolders = folders
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id {
            navigationGeneration = UUID(); selectedConnectionID = nil; clearContent()
        }
    }

    private func clearContent() {
        imageLoads = 0
        document = nil
        directory = nil
        entries = []
        searchPage = nil
        matches = []
        anchor = nil
        linkChoices = []
        linkChoiceAnchor = nil
        linkSearchIncomplete = false
    }

    func browse(_ connection: WikiConnection, path: String = "", append: Bool = false) async throws {
        try require(connection)
        if !append {
            navigationGeneration = UUID()
            clearContent()
            selectedConnectionID = connection.id
        }
        let navigation = navigationGeneration
        let offset: Int
        let revision: String?
        if append {
            guard selectedConnectionID == connection.id, directory?.path == path,
                  let next = directory?.nextOffset else { return }
            guard entries.count < 5_000 else { throw WikiError.resultBudget }
            offset = next
            revision = directory?.revision
        } else { offset = 0; revision = nil }
        let page = try await owned { try await $0.list(root: connection.root, path: path, offset: offset, revision: revision) }
        try require(connection)
        guard navigation == navigationGeneration else { throw CancellationError() }
        if append {
            guard Set(entries.map(\.path)).isDisjoint(with: page.entries.map(\.path)) else { throw WikiError.invalidResponse }
            entries += page.entries
        } else { entries = page.entries }
        directory = page
    }

    func search(_ connection: WikiConnection, query: String, mode: WikiSearchMode, append: Bool = false) async throws {
        try require(connection)
        if !append {
            navigationGeneration = UUID()
            clearContent()
            selectedConnectionID = connection.id
        }
        let navigation = navigationGeneration
        let offset: Int
        if append {
            guard searchPage?.query == query, searchPage?.mode == mode,
                  let next = searchPage?.nextOffset else { return }
            guard matches.count < 5_000 else { throw WikiError.resultBudget }
            offset = next
        } else { offset = 0 }
        let page = try await owned { try await $0.search(root: connection.root, query: query, mode: mode, offset: offset) }
        try require(connection)
        guard navigation == navigationGeneration else { throw CancellationError() }
        if append {
            guard Set(matches.map(\.path)).isDisjoint(with: page.matches.map(\.path)) else { throw WikiError.invalidResponse }
            matches += page.matches
        } else { matches = page.matches }
        searchPage = page
    }

    @discardableResult
    func open(_ connection: WikiConnection, path: String, anchor: String? = nil) async throws -> WikiDocument {
        try require(connection)
        guard WikiNavigation.isMarkdownPath(path) else { throw WikiError.invalidPath }
        navigationGeneration = UUID()
        let navigation = navigationGeneration
        clearContent()
        selectedConnectionID = connection.id
        let bytes = try await owned { try await $0.read(root: connection.root, path: path) }
        try require(connection)
        guard navigation == navigationGeneration else { throw CancellationError() }
        let value = try WikiDocument(connection: connection, path: path, bytes: bytes)
        document = value
        self.anchor = anchor
        return value
    }

    func home(_ connection: WikiConnection) async throws {
        try require(connection)
        navigationGeneration = UUID()
        let navigation = navigationGeneration
        clearContent()
        selectedConnectionID = connection.id
        for path in ["index.md", "README.md"] {
            do {
                let bytes = try await owned { try await $0.read(root: connection.root, path: path) }
                try require(connection)
                guard navigation == navigationGeneration else { throw CancellationError() }
                document = try WikiDocument(connection: connection, path: path, bytes: bytes)
                return
            } catch {
                // A failed read must not restart navigation after the user leaves.
                try Task.checkCancellation()
                try require(connection)
                guard navigation == navigationGeneration else { throw CancellationError() }
                switch error {
                case WikiError.remote("PATH_NOT_FOUND"), WikiError.remote("SECRET_SCAN_BLOCKED"):
                    // Home pages are optional. Keep the host's refusal intact and
                    // try the next candidate; explicit open() still reports it.
                    continue
                default: throw error
                }
            }
        }
        try await browse(connection)
    }

    /// External URLs are returned for an explicit confirmation, never opened here.
    @discardableResult
    func follow(_ raw: String, in document: WikiDocument) async throws -> URL? {
        try require(document.connection)
        guard self.document?.id == document.id else { throw WikiError.ownerChanged }
        switch try WikiNavigation.destination(raw, from: document.path) {
        case .external(let url): return url
        case .anchor(let anchor): self.anchor = anchor; return nil
        case .pages(let paths, let anchor, let shortName):
            let navigation = navigationGeneration
            for path in paths {
                do {
                    let bytes = try await owned { try await $0.read(root: document.root, path: path) }
                    try require(document.connection)
                    guard navigationGeneration == navigation else { throw CancellationError() }
                    self.document = try WikiDocument(connection: document.connection, path: path, bytes: bytes)
                    imageLoads = 0
                    self.anchor = anchor
                    linkChoices = []
                    return nil
                } catch WikiError.remote("PATH_NOT_FOUND") { continue }
            }
            guard let shortName else { throw WikiError.remote("PATH_NOT_FOUND") }
            let page = try await owned {
                try await $0.search(root: document.root, query: shortName, mode: .name, offset: 0)
            }
            try require(document.connection)
            guard navigationGeneration == navigation else { throw CancellationError() }
            let stem = (shortName as NSString).deletingPathExtension.lowercased()
            let candidates = page.matches.filter {
                (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == stem
            }
            linkChoices = candidates
            linkChoiceAnchor = anchor
            linkSearchIncomplete = !page.isComplete || page.nextOffset != nil
            if candidates.count == 1 && !linkSearchIncomplete {
                _ = try await open(document.connection, path: candidates[0].path, anchor: anchor)
            } else if candidates.isEmpty && !linkSearchIncomplete { throw WikiError.remote("PATH_NOT_FOUND") }
            return nil
        }
    }

    func loadImage(_ raw: String, in document: WikiDocument) async throws -> WikiBytes {
        try require(document.connection)
        let path = try WikiNavigation.imagePath(raw, from: document.path)
        guard imageLoads < 4 else { throw WikiError.imageBudget }
        imageLoads += 1
        let bytes = try await owned { try await $0.image(root: document.root, path: path) }
        try require(document.connection)
        guard self.document?.id == document.id, self.document?.baseRevision == document.baseRevision else {
            throw WikiError.ownerChanged
        }
        return bytes
    }

    /// Browse a destination without moving the Wiki browser's current document.
    func creationDirectory(root: WikiRoot, path: String, offset: Int = 0,
                           revision: String? = nil) async throws -> WikiDirectory {
        guard authorizedRoots.contains(root) else { throw WikiError.unavailable }
        return try await owned { try await $0.list(root: root, path: path, offset: offset, revision: revision) }
    }

    func requireCreationPermission(root: WikiRoot) throws {
        guard isAvailable, authorizedRoots.contains(root) else { throw WikiError.unavailable }
        guard root.allowsEditing,
              !connections.contains(where: { $0.root.wikiId == root.wikiId && $0.readOnly }) else {
            throw WikiError.readOnly
        }
        guard root.supportsCreation == true else { throw WikiError.creationUnsupported }
        guard connections.filter({ $0.root.wikiId == root.wikiId }).allSatisfy({ $0.root.matchesGrant(root) }) else {
            throw WikiError.remote("REVISION_STALE")
        }
    }

    /// Local admission only, not a saved file. Save uses the ordinary durable
    /// upload journal with an explicit create-if-absent precondition.
    func newDocument(root: WikiRoot, folder: String, filename: String) throws -> WikiDocument {
        try restoreLocalState()
        let path = try WikiNavigation.newFilePath(folder: folder, filename: filename)
        try requireCreationPermission(root: root)
        guard !pendingSaves.contains(where: { $0.document.root.wikiId == root.wikiId
            && Data($0.document.path.utf8) == Data(path.utf8) }) else { throw WikiError.recoveryRequired }
        let connection: WikiConnection
        if let existing = connections.first(where: { $0.root.wikiId == root.wikiId }) {
            connection = existing
        } else {
            connection = try connect(name: root.name, root: root, readOnly: false)
        }
        return try WikiDocument(connection: connection, path: path,
                                bytes: WikiBytes(data: Data(), revision: "wiki-new-v1:" + root.generation))
    }

    @discardableResult
    func save(document: WikiDocument, workingSource: String) async throws -> WikiPendingSave {
        try Task.checkCancellation()
        try restoreLocalState()
        try require(document.connection)
        guard document.canEdit else { throw WikiError.readOnly }
        let bytes = document.bytes(for: workingSource)
        guard bytes.count <= WikiLimits.editBytes else { throw WikiError.oversized }
        guard !pendingSaves.contains(where: { WikiDraft.sameFile($0.document, document) }) else { throw WikiError.recoveryRequired }
        guard pendingSaves.count < WikiLimits.maxPendingSaves else { throw WikiError.quota }
        let save = WikiPendingSave(operationId: "wiki_" + UUID().uuidString, document: document,
                                   workingSource: workingSource, sha256: WikiLimits.digest(bytes),
                                   phase: .prepared, nextOffset: 0)
        pendingSaves.append(save)
        do { try persist() } catch { pendingSaves.removeAll { $0.id == save.id }; throw error }
        return try await upload(operationID: save.id, fresh: true)
    }

    /// Explicit resume only. Status first, same immutable ID/digest. A recovered
    /// prepared/committing/indeterminate operation is NEVER automatically committed.
    @discardableResult
    func resumeSave(operationID: String) async throws -> WikiPendingSave {
        try await upload(operationID: operationID, fresh: false)
    }

    /// Explicit Retry only. Unknown outcomes keep their ID. A known failure may
    /// be replaced atomically with an identical payload; no recovery bytes vanish
    /// between removing the old journal and admitting its replacement.
    func retrySave(operationID: String) async throws -> WikiPendingSave {
        let previous = try pending(operationID)
        guard previous.phase == .failed else { return try await resumeSave(operationID: operationID) }
        try Task.checkCancellation()
        try require(previous.document.connection)
        guard !activeSaves.contains(operationID), let index = pendingSaves.firstIndex(where: { $0.id == operationID }) else {
            throw WikiError.recoveryRequired
        }
        let replacement = WikiPendingSave(operationId: "wiki_" + UUID().uuidString,
            document: previous.document, workingSource: previous.workingSource, sha256: previous.sha256,
            phase: .prepared, nextOffset: 0)
        pendingSaves[index] = replacement
        do { try persist() } catch { pendingSaves[index] = previous; throw error }
        return try await upload(operationID: replacement.id, fresh: true)
    }

    private func pending(_ id: String) throws -> WikiPendingSave {
        guard let value = pendingSaves.first(where: { $0.id == id }), value.document.owner == owner else {
            throw WikiError.ownerChanged
        }
        return value
    }

    private func update(_ save: WikiPendingSave) throws {
        guard owner == save.document.owner,
              let index = pendingSaves.firstIndex(where: { $0.id == save.id }) else { throw WikiError.ownerChanged }
        pendingSaves[index] = save
        // Keep in-memory recovery even if protection/quota prevents a disk update.
        try persist()
    }

    private func upload(operationID: String, fresh: Bool) async throws -> WikiPendingSave {
        var save = try pending(operationID)
        guard !activeSaves.contains(operationID) else { throw WikiError.recoveryRequired }
        activeSaves.insert(operationID)
        let epoch = generation
        defer { if epoch == generation { activeSaves.remove(operationID) } }
        do {
            let initialSave = save
            let response: WikiSaveResponse
            if fresh { response = try await owned { try await $0.begin(initialSave) } }
            else {
                do { response = try await owned { try await $0.status(operationID: operationID) } }
                catch WikiError.remote("OPERATION_NOT_FOUND") where !initialSave.admitted {
                    // No acknowledged admission means this client could not have
                    // sent commit. Retry the same immutable begin, never a new ID.
                    response = try await owned { try await $0.begin(initialSave) }
                }
            }
            guard generation == epoch else { throw WikiError.ownerChanged }
            guard response.status == .receiving else { return try await record(response, for: operationID) }
            guard response.totalBytes == save.bytes.count, let next = response.nextOffset,
                  (0...save.bytes.count).contains(next) else { throw WikiError.invalidResponse }
            save.phase = .receiving
            save.admitted = true
            save.nextOffset = next
            try update(save)
            while save.nextOffset < save.bytes.count {
                let offset = save.nextOffset
                let chunk = save.bytes.subdata(in: offset..<min(offset + WikiLimits.chunkBytes, save.bytes.count))
                let result = try await owned { try await $0.chunk(operationID: operationID, offset: offset, data: chunk) }
                guard generation == epoch else { throw WikiError.ownerChanged }
                guard result.status == .receiving, result.totalBytes == save.bytes.count,
                      result.nextOffset == offset + chunk.count else { throw WikiError.invalidResponse }
                save.nextOffset += chunk.count
                try update(save)
            }
            save.phase = .committing
            try update(save) // durable intent BEFORE an acknowledgement can be lost
            let result = try await owned { try await $0.commit(operationID: operationID) }
            guard generation == epoch else { throw WikiError.ownerChanged }
            return try await record(result, for: operationID)
        } catch {
            guard generation == epoch else { throw WikiError.ownerChanged }
            save = try pending(operationID)
            if save.phase != .committed && save.phase != .conflict && save.phase != .failed {
                save.phase = .indeterminate
            }
            save.failure = WikiError.safe(error).localizedDescription
            try update(save)
            throw error
        }
    }

    @discardableResult
    func reconcileSave(operationID: String) async throws -> WikiPendingSave {
        _ = try pending(operationID)
        guard !activeSaves.contains(operationID) else { throw WikiError.recoveryRequired }
        activeSaves.insert(operationID)
        let epoch = generation
        defer { if epoch == generation { activeSaves.remove(operationID) } }
        let result = try await owned { try await $0.status(operationID: operationID) }
        guard generation == epoch else { throw WikiError.ownerChanged }
        return try await record(result, for: operationID)
    }

    private func record(_ response: WikiSaveResponse, for id: String) async throws -> WikiPendingSave {
        var save = try pending(id)
        guard response.operationId == id else { throw WikiError.invalidResponse }
        if response.status == .receiving {
            guard response.totalBytes == save.bytes.count, let next = response.nextOffset,
                  (0...save.bytes.count).contains(next) else { throw WikiError.invalidResponse }
            save.nextOffset = next
            save.admitted = true
        }
        save.phase = response.status
        save.failure = response.errorCode.map { WikiError.remote($0).localizedDescription }
        save.currentDocument = nil
        if response.status == .committed {
            guard let revision = response.revision,
                  WikiLimits.validRevision(revision, generation: save.document.root.generation),
                  revision.hasSuffix(":" + save.sha256) else { throw WikiError.invalidResponse }
            save.committedRevision = revision
        }
        try update(save)
        if response.status == .committed || response.status == .conflict {
            let original = save.document
            let epoch = generation
            do {
                let current = try await owned { try await $0.read(root: original.root, path: original.path) }
                guard epoch == generation else { throw WikiError.ownerChanged }
                save.currentDocument = try WikiDocument(connection: original.connection, path: original.path, bytes: current)
                try update(save)
            } catch {
                guard epoch == generation else { throw WikiError.ownerChanged }
                save.failure = "The host outcome is recorded, but current source could not be read back. " + WikiError.safe(error).localizedDescription
                try update(save)
            }
        }
        return save
    }

    /// Call only after the editor has durably adopted the verified base and
    /// preserved newer edits. Unlike discard, this completes a successful Save.
    func finishVerifiedSave(operationID: String) throws {
        let save = try pending(operationID)
        guard save.verifiedCommitted, let current = save.currentDocument else { throw WikiError.recoveryRequired }
        try discardSave(operationID: operationID)
        // Closing the editor must reveal the host readback, not its pre-save page.
        if let document, WikiDraft.sameFile(document, save.document),
           document.baseRevision == save.document.baseRevision {
            self.document = current
        }
    }

    /// Parent must first obtain explicit discard/export confirmation. No eviction.
    func discardSave(operationID: String) throws {
        guard !activeSaves.contains(operationID) else { throw WikiError.recoveryRequired }
        _ = try pending(operationID)
        let previous = pendingSaves
        pendingSaves.removeAll { $0.id == operationID }
        do { try persist() } catch { pendingSaves = previous; throw error }
    }

    func signOutAccountData(accountID: String) throws {
        if owner?.accountID == accountID { setContext(owner: nil, client: nil) }
        try persistence.signOut(accountID: accountID)
    }

    func deleteAccountData(accountID: String) throws {
        if owner?.accountID == accountID { setContext(owner: nil, client: nil) }
        try persistence.deleteAccount(accountID: accountID)
    }
}
