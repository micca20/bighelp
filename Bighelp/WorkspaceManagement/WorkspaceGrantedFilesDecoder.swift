import CryptoKit
import Foundation

struct WorkspaceGrantedFilesCapabilities: Equatable, Sendable {
    let roots: [WorkspaceFileRoot]
    let maximumFileBytes: Int
    let maximumChunkBytes: Int
    let maximumDirectoryPage: Int
}

struct WorkspaceGrantedDirectoryPage: Equatable, Sendable {
    let workspaceID: String
    let path: String
    let parent: String?
    let revision: String
    let offset: Int
    let limit: Int
    let total: Int
    let entries: [WorkspaceFileListing.Entry]
    let nextOffset: Int?
}

struct WorkspaceGrantedFileChunk: Equatable, Sendable {
    let data: Data
    let size: Int
    let revision: String
    let nextOffset: Int?
}

enum WorkspaceGrantedFilesDecoder {
    typealias Object = [String: BighelpJSONValue]
    typealias D = WorkspaceManagementDecoder

    static func capabilities(_ payload: Object) throws -> WorkspaceGrantedFilesCapabilities {
        guard payload["schema_version"]?.integer == 1,
              payload["read_only"]?.boolean == true,
              payload["host_grants_only"]?.boolean == true,
              payload["remote_grant_mutation"]?.boolean == false,
              payload["secure_traversal"]?.boolean == true,
              let maxFile = payload["max_file_bytes"]?.integer, maxFile > 0,
              let chunk = payload["max_chunk_bytes"]?.integer, (1...65_536).contains(chunk),
              let page = payload["max_directory_page"]?.integer, (1...500).contains(page) else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        let roots: [WorkspaceFileRoot] = try D.rows(payload["roots"], maximum: 100).map {
            let row = try D.object($0)
            return try .init(id: identifier(row["workspace_id"]), label: D.text(row["label"], maximum: 200))
        }
        return try .init(roots: D.unique(roots), maximumFileBytes: maxFile, maximumChunkBytes: chunk, maximumDirectoryPage: page)
    }

    static func identifier(_ value: BighelpJSONValue?) throws -> String {
        let value = try D.text(value, maximum: 128)
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              value != ".", value != ".." else { throw WorkspaceManagementError.invalidResponse }
        return value
    }

    static func relativePath(_ value: BighelpJSONValue?, allowsRoot: Bool = true) throws -> String {
        let value = try D.text(value, maximum: 4_096, empty: allowsRoot)
        if value.isEmpty && allowsRoot { return value }
        guard !value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { throw WorkspaceManagementError.invalidResponse }
        return value
    }

    static func revision(_ value: BighelpJSONValue?) throws -> String {
        let value = try D.text(value, maximum: 71)
        guard value.hasPrefix("sha256:"), value.count == 71,
              value.dropFirst(7).allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
            throw WorkspaceManagementError.invalidResponse
        }
        return value
    }

    static func directory(
        _ payload: Object, workspaceID: String, path: String, offset: Int, limit: Int, expectedRevision: String?
    ) throws -> WorkspaceGrantedDirectoryPage {
        guard payload["workspace_id"]?.string == workspaceID,
              payload["path"]?.string == path,
              payload["offset"]?.integer == offset,
              payload["limit"]?.integer == limit,
              let total = payload["total"]?.integer, (0...10_000).contains(total), offset <= total else {
            throw WorkspaceManagementError.invalidResponse
        }
        _ = try relativePath(.string(path))
        let revision = try revision(payload["revision"])
        guard expectedRevision == nil || revision == expectedRevision else { throw WorkspaceClientError.conflict }
        let parent = try D.optionalText(payload["parent"], maximum: 4_096)
        let expectedParent = path.isEmpty ? nil : path.split(separator: "/").dropLast().joined(separator: "/")
        guard parent == expectedParent else { throw WorkspaceManagementError.invalidResponse }
        let entries: [WorkspaceFileListing.Entry] = try D.rows(payload["entries"], maximum: limit).map {
            let row = try D.object($0)
            let name = try D.text(row["name"], maximum: 255)
            let entryPath = try relativePath(row["path"], allowsRoot: false)
            guard !name.contains("/"), !name.contains("\\"),
                  entryPath == (path.isEmpty ? name : "\(path)/\(name)"),
                  let kind = row["kind"]?.string, ["file", "directory"].contains(kind) else {
                throw WorkspaceManagementError.invalidResponse
            }
            let size = row["size"]?.integer
            guard kind == "directory" || (size != nil && size! >= 0) else { throw WorkspaceManagementError.invalidResponse }
            return .init(path: entryPath, name: name, isDirectory: kind == "directory", size: size)
        }
        let end = offset + entries.count
        guard end <= total else { throw WorkspaceManagementError.invalidResponse }
        let next: Int?
        switch payload["next_offset"] {
        case .null:
            guard end == total else { throw WorkspaceManagementError.invalidResponse }
            next = nil
        case .integer(let value):
            guard value == end, value > offset, value < total, entries.count == limit else {
                throw WorkspaceManagementError.invalidResponse
            }
            next = value
        default: throw WorkspaceManagementError.invalidResponse
        }
        return try .init(workspaceID: workspaceID, path: path, parent: parent, revision: revision,
            offset: offset, limit: limit, total: total, entries: D.unique(entries), nextOffset: next)
    }

    static func chunk(
        _ payload: Object, workspaceID: String, path: String, offset: Int, limit: Int,
        expectedRevision: String?, expectedSize: Int?
    ) throws -> WorkspaceGrantedFileChunk {
        guard payload["workspace_id"]?.string == workspaceID, payload["path"]?.string == path,
              payload["offset"]?.integer == offset else { throw WorkspaceManagementError.invalidResponse }
        guard payload["availability"]?.string == "available" else {
            throw WorkspaceManagementError.filePreviewUnavailable
        }
        guard let size = payload["size"]?.integer, (0...D.maximumDocumentBytes).contains(size),
              expectedSize == nil || size == expectedSize,
              let encoded = payload["data"]?.string, encoded.utf8.count <= limit * 2,
              let data = Data(base64Encoded: encoded), data.count <= limit,
              offset + data.count <= size, !data.isEmpty || size == 0 else {
            throw WorkspaceManagementError.invalidResponse
        }
        let revision = try revision(payload["revision"])
        guard expectedRevision == nil || revision == expectedRevision else { throw WorkspaceClientError.conflict }
        let next: Int?
        switch payload["next_offset"] {
        case .null:
            guard offset + data.count == size else { throw WorkspaceManagementError.invalidResponse }
            next = nil
        case .integer(let value):
            guard value == offset + data.count, value > offset, value < size else { throw WorkspaceManagementError.invalidResponse }
            next = value
        default: throw WorkspaceManagementError.invalidResponse
        }
        return .init(data: data, size: size, revision: revision, nextOffset: next)
    }

    static func preview(data: Data, path: String, revision: String) throws -> WorkspaceFilePreview {
        _ = try relativePath(.string(path), allowsRoot: false)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count <= D.maximumDocumentBytes, digest == revision,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            throw WorkspaceManagementError.filePreviewUnavailable
        }
        return .init(path: path, name: String(path.split(separator: "/").last ?? ""), text: text)
    }
}
