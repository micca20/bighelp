import Foundation
import Observation

@MainActor
final class ReferenceWikiAdapter {
    static let providerID = "wiki-reference-v1"
    private struct Hit {
        let connection: WikiConnection
        let path: String
        let result: ReferenceHubResult
    }

    private let store: WikiStore
    private let client: any WikiClientProtocol
    private let owner: WikiOwner
    private let connections: [WikiConnection]
    private let ownerIsCurrent: (ReferenceHubOwner) -> Bool
    private let lease = ReferenceAdapterLease()
    private var boundOwner: ReferenceHubOwner?
    private var hits: [String: Hit] = [:]
    private var order: [String] = []

    init(store: WikiStore, client: any WikiClientProtocol, owner: WikiOwner,
         connections: [WikiConnection], ownerIsCurrent: @escaping (ReferenceHubOwner) -> Bool) {
        self.store = store
        self.client = client
        self.owner = owner
        self.connections = connections
        self.ownerIsCurrent = ownerIsCurrent
        let lease = self.lease
        // setContext always assigns owner/connections, even for an equal-owner
        // replacement client. A one-shot latch rejects replacement and ABA races.
        // Parent supplies the SAME bound client it passed to WikiStore.
        withObservationTracking {
            _ = store.owner
            _ = store.connections
            _ = store.isAvailable
        } onChange: { lease.invalidate() }
    }

    var provider: ReferenceHubProvider {
        ReferenceHubProvider(id: Self.providerID, label: "Wiki", categories: [.wiki],
            search: { try await self.search(owner: $0, category: $1, query: $2) },
            resolve: { try await self.resolve(owner: $0, result: $1) },
            revalidate: { try await self.revalidate(owner: $0, snapshot: $1) })
    }

    private func check(_ hubOwner: ReferenceHubOwner) throws {
        try Task.checkCancellation()
        guard !owner.isNative, lease.isValid, ownerIsCurrent(hubOwner), store.owner == owner,
              client.owner == owner, store.isAvailable, store.connections == connections,
              hubOwner.accountID == owner.accountID, hubOwner.hostID == owner.hostID,
              hubOwner.deviceID == owner.deviceID, hubOwner.agentID == owner.profileID,
              boundOwner == nil || boundOwner == hubOwner else {
            hits.removeAll(); order.removeAll()
            throw ReferenceAdapterError.authorityChanged
        }
        // The hub authorization epoch may combine several providers. The Wiki
        // epoch is pinned independently by owner/client/store and the live closure.
        boundOwner = hubOwner
    }

    private func owned<T: Sendable>(_ hubOwner: ReferenceHubOwner,
                                    _ operation: @MainActor () async throws -> T) async throws -> T {
        try check(hubOwner)
        do {
            let result = try await operation()
            try check(hubOwner)
            return result
        } catch {
            try check(hubOwner)
            if error is CancellationError { throw error }
            throw ReferenceAdapterError.unavailable
        }
    }

    /// Shareable logical root alias, not a local connection/grant/host identifier
    /// or mutable display name. Length framing prevents concatenation collisions.
    private func namespace(_ connection: WikiConnection) -> String {
        Self.referenceNamespace(connection)
    }

    private static func referenceNamespace(_ connection: WikiConnection) -> String {
        let parts = ["loopdy-wiki-reference-v1", connection.owner.accountID, connection.owner.hostID,
                     connection.owner.profileID, connection.root.wikiId]
        let framed = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return "wiki-" + WikiLimits.digest(Data(framed.utf8))
    }

    private func currentRoots(_ hubOwner: ReferenceHubOwner) async throws -> [WikiRoot] {
        let roots = try await owned(hubOwner) { try await self.client.roots() }
        try check(hubOwner)
        guard roots.count <= 256, Set(roots.map(\.wikiId)).count == roots.count else {
            throw ReferenceAdapterError.invalidSource
        }
        return roots
    }

    private func require(_ connection: WikiConnection, in roots: [WikiRoot]) throws {
        guard connections.contains(connection), roots.contains(where: { $0.matchesGrant(connection.root) }),
              WikiLimits.validGeneration(connection.root.generation) else {
            throw ReferenceAdapterError.unavailable
        }
    }

    private func search(owner hubOwner: ReferenceHubOwner, category: ReferenceCategory,
                        query: String) async throws -> ReferenceHubSearchPage {
        try check(hubOwner)
        guard category == .all || category == .wiki else {
            return ReferenceHubSearchPage(results: [], isPartial: false)
        }
        guard query.utf8.count <= 512 else { throw ReferenceAdapterError.invalidSource }
        let roots = try await currentRoots(hubOwner)
        try check(hubOwner)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await browse(hubOwner, roots: roots)
        }
        // Never search newly discovered or unconnected roots. Bounded filename
        // browsing plus one name/content page each per root, eight roots and 100 results.
        var seenRoots = Set<String>()
        let named = connections.filter { seenRoots.insert($0.root.wikiId).inserted }
        var partial = named.count > 8
        let namedFiles = try await browse(hubOwner, roots: roots, query: query)
        partial = partial || namedFiles.isPartial
        var results = namedFiles.results
        var seen = Set(results.map(\.resourceID))
        for connection in named.prefix(8) {
            guard roots.contains(where: { $0.matchesGrant(connection.root) }) else { partial = true; continue }
            for mode in [WikiSearchMode.name, .content] {
                let page = try await owned(hubOwner) {
                    try await self.client.search(root: connection.root, query: query, mode: mode, offset: 0)
                }
                try check(hubOwner)
                guard page.wikiId == connection.root.wikiId, page.query.utf8.elementsEqual(query.utf8),
                      page.mode == mode, page.matches.count <= WikiLimits.pageEntries else {
                    throw ReferenceAdapterError.invalidSource
                }
                partial = partial || !page.isComplete || page.nextOffset != nil
                for match in page.matches {
                    guard WikiLimits.validRevision(match.revision, generation: connection.root.generation) else {
                        throw ReferenceAdapterError.invalidSource
                    }
                    try WikiNavigation.validatePath(match.path)
                    // Name discovery also offers ordinary-file locations. Only
                    // Markdown participates in selected content references.
                    guard mode == .name || WikiNavigation.isMarkdownPath(match.path) else { continue }
                    let id = namespace(connection) + ":" + WikiLimits.digest(Data(match.path.utf8))
                    guard seen.insert(id).inserted else { continue }
                    guard results.count < 100 else { partial = true; continue }
                    let row = ReferenceHubResult(resourceID: id, providerID: Self.providerID, category: .wiki,
                        title: ReferenceAdapterContent.prefix(match.title, maximumBytes: 1_024).text,
                        subtitle: connection.name + ": " + match.path, state: nil, isCached: false)
                    let hit = Hit(connection: connection, path: match.path, result: row)
                    if hits[id] == nil { order.append(id) }
                    hits[id] = hit
                    while order.count > 200 { hits.removeValue(forKey: order.removeFirst()) }
                    results.append(row)
                }
            }
        }
        return ReferenceHubSearchPage(results: results, isPartial: partial)
    }

    /// File discovery is a bounded recursive browse of connected roots.
    /// Each file is read/revalidated only after selection; directory metadata is
    /// not presented as a source revision or an already-reviewed snapshot.
    private func browse(_ hubOwner: ReferenceHubOwner, roots: [WikiRoot], query: String = "") async throws -> ReferenceHubSearchPage {
        var seenRoots = Set<String>()
        let named = connections.filter { seenRoots.insert($0.root.wikiId).inserted }
        var results: [ReferenceHubResult] = []
        var partial = named.count > 8
        var remainingDirectories = 32
        for connection in named.prefix(8) {
            guard roots.contains(where: { $0.matchesGrant(connection.root) }) else { partial = true; continue }
            var pending = [""]
            while !pending.isEmpty {
                guard remainingDirectories > 0, results.count < 100 else { partial = true; break }
                remainingDirectories -= 1
                let path = pending.removeFirst()
                let page = try await owned(hubOwner) {
                    try await self.client.list(root: connection.root, path: path, offset: 0, revision: nil)
                }
                try check(hubOwner)
                guard page.wikiId == connection.root.wikiId, page.path == path,
                      page.entries.count <= WikiLimits.pageEntries,
                      WikiLimits.validRevision(page.revision, generation: connection.root.generation) else {
                    throw ReferenceAdapterError.invalidSource
                }
                partial = partial || page.nextOffset != nil
                for entry in page.entries {
                    try WikiNavigation.validatePath(entry.path)
                    guard WikiNavigation.parent(of: entry.path) == path else { throw ReferenceAdapterError.invalidSource }
                    if entry.isDirectory {
                        if pending.count < 32 && entry.path.split(separator: "/").count < 32 { pending.append(entry.path) }
                        else { partial = true }
                        continue
                    }
                    guard entry.kind == "file",
                          query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) else { continue }
                    guard results.count < 100 else { partial = true; continue }
                    let id = namespace(connection) + ":" + WikiLimits.digest(Data(entry.path.utf8))
                    let row = ReferenceHubResult(resourceID: id, providerID: Self.providerID, category: .wiki,
                        title: ReferenceAdapterContent.prefix(entry.name, maximumBytes: 1_024).text,
                        subtitle: connection.name + ": " + entry.path, state: nil, isCached: false)
                    if hits[id] == nil { order.append(id) }
                    hits[id] = Hit(connection: connection, path: entry.path, result: row)
                    while order.count > 200 { hits.removeValue(forKey: order.removeFirst()) }
                    results.append(row)
                }
            }
        }
        return ReferenceHubSearchPage(results: results, isPartial: partial)
    }

    private func document(_ hubOwner: ReferenceHubOwner, connection: WikiConnection,
                          path: String) async throws -> WikiDocument {
        try check(hubOwner)
        try WikiNavigation.validatePath(path)
        guard WikiNavigation.isMarkdownPath(path) else { throw ReferenceAdapterError.invalidSource }
        let roots = try await currentRoots(hubOwner)
        try check(hubOwner)
        try require(connection, in: roots)
        let bytes = try await owned(hubOwner) {
            try await self.client.read(root: connection.root, path: path)
        }
        try check(hubOwner)
        guard bytes.data.count <= WikiLimits.readBytes,
              WikiLimits.validRevision(bytes.revision, generation: connection.root.generation),
              bytes.revision.hasSuffix(":" + WikiLimits.digest(bytes.data)) else {
            throw ReferenceAdapterError.invalidSource
        }
        guard let currentRoot = roots.first(where: { $0.matchesGrant(connection.root) }) else {
            throw ReferenceAdapterError.unavailable
        }
        let currentConnection = WikiConnection(id: connection.id, owner: connection.owner, name: connection.name,
                                              root: currentRoot, readOnly: connection.readOnly)
        return try WikiDocument(connection: currentConnection, path: path, bytes: bytes)
    }

    private func resolve(owner hubOwner: ReferenceHubOwner, result: ReferenceHubResult) async throws -> ReferenceHubPreview {
        try check(hubOwner)
        guard result.providerID == Self.providerID, result.category == .wiki,
              let hit = hits[result.resourceID] else { throw ReferenceAdapterError.expiredResult }
        if !WikiNavigation.isMarkdownPath(hit.path) {
            let snapshot = try await fileLocation(hubOwner, connection: hit.connection, path: hit.path)
            return ReferenceHubPreview(result: hit.result, sourceKindLabel: "Wiki file location · contents not included",
                options: [ReferenceContentOption(id: "location", label: "File location only", snapshot: snapshot)])
        }
        let doc = try await document(hubOwner, connection: hit.connection, path: hit.path)
        try check(hubOwner)
        let options = try Self.options(for: doc)
        let sourceLabel = hit.connection.root.sourceKind == "files" ? "Wiki Markdown file" : "Wiki read-only source"
        return ReferenceHubPreview(result: hit.result,
            sourceKindLabel: sourceLabel + " · page and up to 32 unambiguous ATX heading sections", options: options)
    }

    /// Fresh metadata only. A directory revision fingerprints the entry's
    /// filesystem identity/stat; it is never claimed to be a content digest.
    private func fileLocation(_ hubOwner: ReferenceHubOwner, connection: WikiConnection,
                              path: String) async throws -> ReferenceSnapshot {
        try WikiNavigation.validatePath(path)
        let roots = try await currentRoots(hubOwner)
        try require(connection, in: roots)
        guard let root = roots.first(where: { $0.matchesGrant(connection.root) }),
              let folderPath = root.folderPath else { throw ReferenceAdapterError.unavailable }
        try WikiLimits.validateFolderPath(folderPath)
        let parent = WikiNavigation.parent(of: path) ?? ""
        var offset = 0
        var revision: String?
        for _ in 0..<10 {
            let requestedOffset = offset
            let requestedRevision = revision
            let page = try await owned(hubOwner) {
                try await self.client.list(root: root, path: parent, offset: requestedOffset, revision: requestedRevision)
            }
            try check(hubOwner)
            guard page.wikiId == root.wikiId, page.path == parent, page.offset == offset,
                  WikiLimits.validRevision(page.revision, generation: root.generation),
                  revision == nil || revision == page.revision else { throw ReferenceAdapterError.invalidSource }
            revision = page.revision
            if let entry = page.entries.first(where: { $0.path.utf8.elementsEqual(path.utf8) }) {
                guard entry.kind == "file", let size = entry.size, size >= 0 else { throw ReferenceAdapterError.unavailable }
                let metadata: [String: BighelpJSONValue] = [
                    "sourcePath": .string(folderPath + "/" + path), "sizeBytes": .integer(size),
                    "selection": .string("File location only; file contents are not included"),
                    "revisionKind": .string("parent directory metadata")
                ]
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let text = String(decoding: try encoder.encode(metadata), as: UTF8.self)
                let snapshot = try ReferenceSnapshot(kind: .wiki,
                    identity: .wiki(WikiReferenceIdentity(namespace: namespace(connection), relativePath: path)),
                    title: entry.name, selectedContent: text, sourceRevision: page.revision, fetchedAt: Date())
                guard ReferenceAdapterContent.fits(snapshot) else { throw ReferenceAdapterError.invalidSource }
                return snapshot
            }
            guard let next = page.nextOffset, next > offset else { throw ReferenceAdapterError.unavailable }
            offset = next
        }
        throw ReferenceAdapterError.unavailable
    }

    /// Pure preview; the parent verifies live source and recipient ownership.
    static func options(for doc: WikiDocument) throws -> [ReferenceContentOption] {
        let page = try snapshot(doc, section: nil)
        var options = [ReferenceContentOption(id: "page", label: page.isTruncated ? "Page — truncated" : "Page",
                                              snapshot: page)]
        let sections = ReferenceWikiAdapterSections.sections(in: doc.originalBytes)
        for section in sections.prefix(32) {
            let selected = try snapshot(doc, section: section)
            options.append(ReferenceContentOption(id: section.id,
                label: "Section: " + section.title + (selected.isTruncated ? " — truncated" : ""), snapshot: selected))
        }
        return options
    }

    private func revalidate(owner hubOwner: ReferenceHubOwner, snapshot previous: ReferenceSnapshot) async throws -> ReferenceSnapshot {
        try check(hubOwner)
        guard previous.kind == .wiki, case .wiki(let identity) = previous.identity,
              let connection = connections.first(where: { namespace($0) == identity.namespace }),
              WikiLimits.validRevision(previous.sourceRevision, generation: connection.root.generation) else {
            throw ReferenceAdapterError.invalidSource
        }
        if !WikiNavigation.isMarkdownPath(identity.relativePath) {
            guard identity.section == nil else { throw ReferenceAdapterError.invalidSource }
            return try await fileLocation(hubOwner, connection: connection, path: identity.relativePath)
        }
        let doc = try await document(hubOwner, connection: connection, path: identity.relativePath)
        try check(hubOwner)
        let section: ReferenceWikiAdapterSections.Section?
        if let id = identity.section {
            guard let current = ReferenceWikiAdapterSections.sections(in: doc.originalBytes).first(where: { $0.id == id }) else {
                // Deleted, renamed or now ambiguous heading is not a page fallback.
                throw ReferenceAdapterError.unavailable
            }
            section = current
        } else { section = nil }
        return try Self.snapshot(doc, section: section)
    }

    private static func snapshot(_ document: WikiDocument,
                          section: ReferenceWikiAdapterSections.Section?) throws -> ReferenceSnapshot {
        let bytes = section.map { document.originalBytes.subdata(in: $0.range) } ?? document.originalBytes
        let source = String(decoding: bytes, as: UTF8.self)
        guard Data(source.utf8) == bytes else { throw ReferenceAdapterError.invalidSource }
        let identity = WikiReferenceIdentity(namespace: referenceNamespace(document.connection),
                                             relativePath: document.path, section: section?.id)
        let title = ReferenceAdapterContent.prefix(section?.title ?? document.title, maximumBytes: 1_024).text
        let sourceMetadata: String
        if let folderPath = document.root.folderPath {
            try WikiLimits.validateFolderPath(folderPath)
            let encodedPath = try JSONEncoder().encode(folderPath + "/" + document.path)
            sourceMetadata = "Wiki source path (JSON): " + String(decoding: encodedPath, as: UTF8.self) + "\n\n"
        } else { sourceMetadata = "" }
        var budget = 8_192
        while true {
            let excerpt = ReferenceAdapterContent.prefix(source, maximumBytes: budget)
            let selected = try ReferenceSnapshot(kind: .wiki, identity: .wiki(identity), title: title,
                selectedContent: sourceMetadata + excerpt.text + (excerpt.truncated ? ReferenceAdapterContent.truncationMarker : ""),
                sourceRevision: document.baseRevision, fetchedAt: document.fetchedAt, isTruncated: excerpt.truncated)
            if ReferenceAdapterContent.fits(selected) { return selected }
            guard budget > 0 else { throw ReferenceAdapterError.invalidSource }
            budget /= 2
        }
    }
}
