import Foundation

@MainActor
final class WorkspaceGrantedFilesClient: WorkspaceManagementFilesClient {
    private let owner: WorkspaceOwner
    private let profileID: String
    private let servingProfileID: String?
    private let performer: any WorkspaceOperationPerforming
    private let isCurrent: @MainActor () -> Bool

    init(owner: WorkspaceOwner, profileID: String, servingProfileID: String?,
         performer: any WorkspaceOperationPerforming, isCurrent: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.profileID = profileID
        self.servingProfileID = servingProfileID
        self.performer = performer
        self.isCurrent = isCurrent
    }

    func load(path: String?, root: String?) async throws -> WorkspaceManagementContent {
        if let path { _ = try WorkspaceGrantedFilesDecoder.relativePath(.string(path)) }
        if let root { _ = try WorkspaceGrantedFilesDecoder.identifier(.string(root)) }
        let capabilities = try await capabilities()
        guard let root else {
            guard path == nil else { throw WorkspaceManagementError.invalidInput }
            return .fileRoots(capabilities.roots)
        }
        let selected = try selectedRoot(root, in: capabilities)
        let path = path ?? ""
        let limit = min(100, capabilities.maximumDirectoryPage)
        let page = try await directory(root: root, path: path, offset: 0, limit: limit, revision: nil)
        return .files(listing(page, label: selected.label, entries: page.entries))
    }

    func nextPage(_ previous: WorkspaceFileListing) async throws -> WorkspaceFileListing {
        guard let cursor = previous.nextPage, cursor.offset == previous.entries.count,
              previous.entries.count <= 10_000 else { throw WorkspaceManagementError.invalidInput }
        _ = try WorkspaceGrantedFilesDecoder.relativePath(.string(previous.path))
        let capabilities = try await capabilities()
        let selected = try selectedRoot(previous.root, in: capabilities)
        guard cursor.limit <= capabilities.maximumDirectoryPage else { throw WorkspaceClientError.conflict }
        let page = try await directory(root: previous.root, path: previous.path, offset: cursor.offset,
            limit: cursor.limit, revision: cursor.revision)
        guard page.total == cursor.total else { throw WorkspaceClientError.conflict }
        let entries = try WorkspaceManagementDecoder.unique(previous.entries + page.entries)
        return listing(page, label: selected.label, entries: entries)
    }

    func preview(path: String, root: String) async throws -> WorkspaceFilePreview {
        _ = try WorkspaceGrantedFilesDecoder.relativePath(.string(path), allowsRoot: false)
        let capabilities = try await capabilities()
        _ = try selectedRoot(root, in: capabilities)
        var data = Data()
        var offset = 0
        var revision: String?
        var size: Int?
        for _ in 0..<16 {
            var payload: [String: LoopdyJSONValue] = [
                "workspace_id": .string(root), "path": .string(path),
                "offset": .integer(offset), "limit": .integer(capabilities.maximumChunkBytes)
            ]
            if let revision { payload["revision"] = .string(revision) }
            let raw = try await request(.managedFilesRead, payload: payload)
            let chunk = try WorkspaceGrantedFilesDecoder.chunk(raw, workspaceID: root, path: path,
                offset: offset, limit: capabilities.maximumChunkBytes, expectedRevision: revision, expectedSize: size)
            guard chunk.size <= capabilities.maximumFileBytes else { throw WorkspaceClientError.capacityExceeded }
            revision = chunk.revision
            size = chunk.size
            data.append(chunk.data)
            guard data.count <= WorkspaceManagementDecoder.maximumDocumentBytes else {
                throw WorkspaceClientError.capacityExceeded
            }
            guard let next = chunk.nextOffset else {
                guard data.count == chunk.size else { throw WorkspaceManagementError.invalidResponse }
                return try WorkspaceGrantedFilesDecoder.preview(data: data, path: path, revision: chunk.revision)
            }
            offset = next
        }
        throw WorkspaceClientError.capacityExceeded
    }

    private func capabilities() async throws -> WorkspaceGrantedFilesCapabilities {
        try WorkspaceGrantedFilesDecoder.capabilities(await request(.managedFilesCapabilities, payload: [:]))
    }

    private func selectedRoot(_ root: String, in capabilities: WorkspaceGrantedFilesCapabilities) throws -> WorkspaceFileRoot {
        guard let selected = capabilities.roots.first(where: { $0.id == root }) else {
            throw WorkspaceManagementError.unavailable("This folder is no longer granted on the selected host. Refresh the folder catalog.")
        }
        return selected
    }

    private func directory(root: String, path: String, offset: Int, limit: Int, revision: String?) async throws -> WorkspaceGrantedDirectoryPage {
        var payload: [String: LoopdyJSONValue] = [
            "workspace_id": .string(root), "path": .string(path), "offset": .integer(offset),
            "limit": .integer(limit), "query": .string("")
        ]
        if let revision { payload["revision"] = .string(revision) }
        let raw = try await request(.managedFilesList, payload: payload)
        return try WorkspaceGrantedFilesDecoder.directory(raw, workspaceID: root, path: path,
            offset: offset, limit: limit, expectedRevision: revision)
    }

    private func listing(_ page: WorkspaceGrantedDirectoryPage, label: String, entries: [WorkspaceFileListing.Entry]) -> WorkspaceFileListing {
        .init(path: page.path, root: page.workspaceID, parent: page.parent, entries: entries, rootLabel: label,
            nextPage: page.nextOffset.map {
                .init(revision: page.revision, offset: $0, limit: page.limit, total: page.total)
            })
    }

    private func request(_ operation: WorkspaceOperation, payload: [String: LoopdyJSONValue]) async throws -> [String: LoopdyJSONValue] {
        try checkOwner()
        try WorkspaceAuthority.validateIdentifier(profileID, maximumBytes: 128)
        guard servingProfileID == profileID else {
            throw WorkspaceManagementError.unavailable("The Files grant catalog belongs to the serving profile. Verify that profile before browsing.")
        }
        let response = try await performer.perform(operation, payload: payload, owner: owner)
        try checkOwner()
        guard try JSONEncoder().encode(response).count <= 2_097_152 else { throw WorkspaceClientError.capacityExceeded }
        return response
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard isCurrent(), performer.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }
}
