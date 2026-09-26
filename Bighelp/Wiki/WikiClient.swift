import Foundation

@MainActor
protocol WikiClientProtocol {
    var owner: WikiOwner { get }
    var supportsRemoteDisconnect: Bool { get }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage
    func roots() async throws -> [WikiRoot]
    func resolve(folderPath: String) async throws -> WikiRoot
    func connect(folderPath: String) async throws -> WikiRoot
    func list(root: WikiRoot, path: String, offset: Int, revision: String?) async throws -> WikiDirectory
    func read(root: WikiRoot, path: String) async throws -> WikiBytes
    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int) async throws -> WikiSearchPage
    func image(root: WikiRoot, path: String) async throws -> WikiBytes
    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse
    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse
    func commit(operationID: String) async throws -> WikiSaveResponse
    func status(operationID: String) async throws -> WikiSaveResponse
    func disconnect(root: WikiRoot) async throws
}

extension WikiClientProtocol {
    var supportsRemoteDisconnect: Bool { false }
    func disconnect(root: WikiRoot) async throws { throw WikiError.remote("CAPABILITY_UNSUPPORTED") }
}

/// Shared, bounded Wiki codecs. The Link initializer keeps its prepared transport;
/// the native initializer accepts only a finite request closure with separate owner fencing.
@MainActor
final class WikiLinkClient: WikiClientProtocol {
    let owner: WikiOwner
    private let request: @MainActor (BighelpLinkWorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
    private let folderRequest: (@MainActor (String, String, Int) async throws -> HermesWorkspaceFolderPage)?
    private let expectsNativeOwner: Bool
    private let currentOwner: @MainActor () -> WikiOwner?

    init(owner: WikiOwner, workspace: BighelpLinkWorkspaceClient,
         currentOwner: @escaping @MainActor () -> WikiOwner?) {
        self.owner = owner
        request = { operation, fields in try await workspace.perform(operation, payload: fields) }
        folderRequest = { parent, prefix, offset in
            try await BighelpLinkHermesWorkspaceClient(workspace: workspace).folderSuggestions(
                parentPath: parent, prefix: prefix, offset: offset, limit: WikiLimits.pageEntries,
                agentID: owner.profileID)
        }
        expectsNativeOwner = false
        self.currentOwner = currentOwner
    }

    init(owner: WikiOwner,
         nativeRequest: @escaping @MainActor (BighelpLinkWorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue],
         currentOwner: @escaping @MainActor () -> WikiOwner?) {
        self.owner = owner
        request = nativeRequest
        folderRequest = nil
        expectsNativeOwner = true
        self.currentOwner = currentOwner
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard owner.isValid, owner.isNative == expectsNativeOwner, currentOwner() == owner else { throw WikiError.ownerChanged }
    }

    private func call<T: Decodable>(_ operation: BighelpLinkWorkspaceOperation,
                                    _ fields: [String: BighelpJSONValue] = [:]) async throws -> T {
        try checkOwner()
        var payload = fields
        payload["agentId"] = .string(owner.profileID)
        let encoded = try JSONEncoder().encode(payload)
        guard encoded.count <= 100_000 else { throw WikiError.oversized }
        let response: [String: BighelpJSONValue]
        do { response = try await request(operation, payload) }
        catch {
            try checkOwner()
            throw WikiError.safe(error)
        }
        try checkOwner()
        let data = try JSONEncoder().encode(response)
        guard data.count < 196_608 else { throw WikiError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WikiError.invalidResponse }
    }

    private func validate(_ root: WikiRoot) throws {
        if let folderPath = root.folderPath { try WikiLimits.validateFolderPath(folderPath) }
        guard !root.wikiId.isEmpty, root.wikiId.utf8.count <= 180,
              root.wikiId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }),
              !root.name.isEmpty, root.name.utf8.count <= 1_024,
              WikiLimits.validGeneration(root.generation) else { throw WikiError.invalidResponse }
    }

    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage {
        try checkOwner()
        guard let folderRequest else { throw WikiError.remote("FOLDER_SUGGESTIONS_UNAVAILABLE") }
        let page = try await folderRequest(parentPath, prefix, offset)
        try checkOwner()
        return page
    }

    func roots() async throws -> [WikiRoot] {
        struct Result: Decodable { let roots: [WikiRoot] }
        let result: Result = try await call(.wikiRoots)
        guard result.roots.count <= 256,
              Set(result.roots.map(\.wikiId)).count == result.roots.count else { throw WikiError.invalidResponse }
        for root in result.roots { try validate(root) }
        return result.roots
    }

    func resolve(folderPath: String) async throws -> WikiRoot {
        guard folderPath.hasPrefix("/"), folderPath.utf8.count <= 4_096,
              !folderPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WikiError.invalidPath
        }
        let root: WikiRoot = try await call(.wikiResolve, ["folderPath": .string(folderPath)])
        try validate(root)
        return root
    }

    func connect(folderPath: String) async throws -> WikiRoot {
        try WikiLimits.validateFolderPath(folderPath)
        let root: WikiRoot = try await call(.wikiConnect, ["folderPath": .string(folderPath)])
        try validate(root)
        guard root.folderPath == folderPath else { throw WikiError.invalidResponse }
        return root
    }

    func list(root: WikiRoot, path: String, offset: Int = 0, revision: String? = nil) async throws -> WikiDirectory {
        try WikiNavigation.validatePath(path, allowRoot: true)
        guard offset >= 0 else { throw WikiError.invalidPath }
        var fields: [String: BighelpJSONValue] = [
            "wikiId": .string(root.wikiId), "path": .string(path), "offset": .integer(offset),
            "limit": .integer(WikiLimits.pageEntries), "query": .string("")
        ]
        if let revision { fields["revision"] = .string(revision) }
        let page: WikiDirectory = try await call(.wikiList, fields)
        guard page.wikiId == root.wikiId, page.path.utf8.elementsEqual(path.utf8), page.offset == offset,
              page.limit == WikiLimits.pageEntries, page.total >= 0, page.total >= offset,
              page.entries.count <= WikiLimits.pageEntries,
              page.entries.count <= page.total - offset,
              WikiLimits.validRevision(page.revision, generation: root.generation),
              revision == nil || revision == page.revision,
              Set(page.entries.map(\.path)).count == page.entries.count,
              page.parent == WikiNavigation.parent(of: path) else { throw WikiError.invalidResponse }
        try validateNext(page.nextOffset, offset: offset, count: page.entries.count, total: page.total)
        for entry in page.entries {
            try WikiNavigation.validatePath(entry.path)
            guard WikiNavigation.parent(of: entry.path) == path,
                  (entry.path as NSString).lastPathComponent == entry.name,
                  entry.size == nil || entry.size! >= 0 else { throw WikiError.invalidResponse }
        }
        return page
    }

    private func validateNext(_ next: Int?, offset: Int, count: Int, total: Int? = nil) throws {
        guard count >= 0, offset <= Int.max - count else { throw WikiError.invalidResponse }
        if let next {
            guard count > 0, next == offset + count,
                  total == nil || next < total! else { throw WikiError.invalidResponse }
        } else if let total, offset + count != total { throw WikiError.invalidResponse }
    }

    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int = 0) async throws -> WikiSearchPage {
        guard !query.isEmpty, query.utf8.count <= 512, offset >= 0 else { throw WikiError.invalidPath }
        let page: WikiSearchPage = try await call(.wikiSearch, [
            "wikiId": .string(root.wikiId), "query": .string(query), "mode": .string(mode.rawValue),
            "offset": .integer(offset), "limit": .integer(WikiLimits.pageEntries)
        ])
        guard page.wikiId == root.wikiId, page.query == query, page.mode == mode,
              page.matches.count <= WikiLimits.pageEntries,
              Set(page.matches.map(\.path)).count == page.matches.count,
              page.indexedAt == nil || page.indexedAt!.isFinite else { throw WikiError.invalidResponse }
        try validateNext(page.nextOffset, offset: offset, count: page.matches.count)
        for match in page.matches {
            try WikiNavigation.validatePath(match.path)
            guard WikiLimits.validRevision(match.revision, generation: root.generation) else {
                throw WikiError.invalidResponse
            }
        }
        return page
    }

    func read(root: WikiRoot, path: String) async throws -> WikiBytes {
        try await bytes(root: root, path: path, operation: .wikiRead)
    }

    func image(root: WikiRoot, path: String) async throws -> WikiBytes {
        guard WikiNavigation.isImagePath(path) else { throw WikiError.unsafeImage }
        return try await bytes(root: root, path: path, operation: .wikiImage)
    }

    private func bytes(root: WikiRoot, path: String, operation: BighelpLinkWorkspaceOperation) async throws -> WikiBytes {
        try WikiNavigation.validatePath(path)
        var result = Data()
        var revision: String?
        var total: Int?
        // A finite limit even for a malicious sequence of one-byte chunks.
        for _ in 0...(WikiLimits.readBytes / WikiLimits.chunkBytes) {
            var fields: [String: BighelpJSONValue] = [
                "wikiId": .string(root.wikiId), "path": .string(path),
                "offset": .integer(result.count), "limit": .integer(WikiLimits.chunkBytes)
            ]
            if let revision { fields["revision"] = .string(revision) }
            let page: WikiFilePage = try await call(operation, fields)
            guard page.wikiId == root.wikiId, page.path.utf8.elementsEqual(path.utf8) else { throw WikiError.invalidResponse }
            if page.availability == "oversized" { throw WikiError.oversized }
            // Image endpoint may retain the Files binary classification; bytes remain authoritative.
            guard page.availability == "available" || (operation == .wikiImage && page.availability == "binary") else {
                throw WikiError.invalidUTF8
            }
            guard page.offset == result.count, (0...WikiLimits.readBytes).contains(page.size),
                  total == nil || page.size == total,
                  let token = page.revision, WikiLimits.validRevision(token, generation: root.generation),
                  revision == nil || revision == token,
                  let encoded = page.data, encoded.utf8.count <= 87_384,
                  let chunk = Data(base64Encoded: encoded), chunk.base64EncodedString() == encoded,
                  chunk.count <= WikiLimits.chunkBytes, chunk.count <= page.size - result.count else {
                throw WikiError.invalidResponse
            }
            revision = token
            total = page.size
            let offset = result.count
            result.append(chunk)
            try validateNext(page.nextOffset, offset: offset, count: chunk.count, total: page.size)
            if page.nextOffset == nil {
                guard token.hasSuffix(":" + WikiLimits.digest(result)) else { throw WikiError.invalidResponse }
                return WikiBytes(data: result, revision: token)
            }
            guard chunk.count == WikiLimits.chunkBytes else { throw WikiError.invalidResponse }
        }
        throw WikiError.oversized
    }

    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse {
        guard save.document.owner == owner, save.document.canEdit,
              save.bytes.count <= WikiLimits.editBytes, WikiLimits.digest(save.bytes) == save.sha256 else {
            throw WikiError.readOnly
        }
        try WikiNavigation.validatePath(save.document.path)
        if save.document.isNewFile {
            let roots = try await roots()
            guard let current = roots.first(where: { $0.matchesGrant(save.document.root) }) else {
                throw WikiError.remote("REVISION_STALE")
            }
            guard current.supportsCreation == true else { throw WikiError.creationUnsupported }
        }
        return try await saveCall(.wikiSaveBegin, operationID: save.operationId, fields: [
            "wikiId": .string(save.document.root.wikiId), "path": .string(save.document.path),
            "baseRevision": .string(save.document.baseRevision), "totalBytes": .integer(save.bytes.count),
            "sha256": .string(save.sha256)
        ])
    }

    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse {
        guard offset >= 0, !data.isEmpty, data.count <= WikiLimits.chunkBytes else { throw WikiError.oversized }
        return try await saveCall(.wikiSaveChunk, operationID: operationID, fields: [
            "offset": .integer(offset), "data": .string(data.base64EncodedString())
        ])
    }

    func commit(operationID: String) async throws -> WikiSaveResponse {
        try await saveCall(.wikiSaveCommit, operationID: operationID)
    }

    func status(operationID: String) async throws -> WikiSaveResponse {
        try await saveCall(.wikiSaveStatus, operationID: operationID)
    }

    private func saveCall(_ operation: BighelpLinkWorkspaceOperation, operationID: String,
                          fields: [String: BighelpJSONValue] = [:]) async throws -> WikiSaveResponse {
        guard !operationID.isEmpty, operationID.utf8.count <= 180 else { throw WikiError.invalidResponse }
        var fields = fields
        fields["operationId"] = .string(operationID)
        let response: WikiSaveResponse = try await call(operation, fields)
        guard response.operationId == operationID else { throw WikiError.invalidResponse }
        if response.status == .receiving {
            guard let next = response.nextOffset, let total = response.totalBytes,
                  (0...WikiLimits.editBytes).contains(total), (0...total).contains(next) else {
                throw WikiError.invalidResponse
            }
        }
        if response.status == .committed {
            guard let revision = response.revision, WikiLimits.validRevision(revision) else {
                throw WikiError.invalidResponse
            }
        }
        return response
    }
}
