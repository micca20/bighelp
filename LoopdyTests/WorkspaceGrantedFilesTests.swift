import CryptoKit
import Foundation
import Testing
@testable import Loopdy

struct WorkspaceGrantedFilesTests {
    @Test func requiresHostGrantAndSecureTraversalPromises() throws {
        let value = try WorkspaceGrantedFilesDecoder.capabilities(capabilities())
        #expect(value.roots == [.init(id: "notes", label: "Notes")])
        for key in ["read_only", "host_grants_only", "secure_traversal"] {
            var payload = capabilities()
            payload[key] = .boolean(false)
            #expect(throws: WorkspaceManagementError.fileRootNotConfined) {
                try WorkspaceGrantedFilesDecoder.capabilities(payload)
            }
        }
        var payload = capabilities()
        payload["remote_grant_mutation"] = .boolean(true)
        #expect(throws: WorkspaceManagementError.fileRootNotConfined) {
            try WorkspaceGrantedFilesDecoder.capabilities(payload)
        }
    }

    @Test func rejectsAmbiguousRootCatalog() {
        var payload = capabilities()
        payload["roots"] = .array([
            .object(["workspace_id": .string("notes"), "label": .string("First")]),
            .object(["workspace_id": .string("notes"), "label": .string("Second")])
        ])
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceGrantedFilesDecoder.capabilities(payload)
        }
    }

    @Test func relativePathsCannotBecomeAbsoluteOrTraverse() throws {
        #expect(try WorkspaceGrantedFilesDecoder.relativePath(.string("")) == "")
        #expect(try WorkspaceGrantedFilesDecoder.relativePath(.string("notes/hello.md")) == "notes/hello.md")
        for path in ["/etc/passwd", "..", "notes/../keys", "notes//file", "file:///tmp/a", "C:\\secret", "notes/./file"] {
            #expect(throws: WorkspaceManagementError.invalidResponse) {
                try WorkspaceGrantedFilesDecoder.relativePath(.string(path))
            }
        }
    }

    @Test func pageMatchesWorkspacePathOffsetLimitAndRevision() throws {
        let page = try decodePage(directory())
        #expect(page.entries.map(\.name) == ["hello.md"])
        #expect(page.nextOffset == nil)
        for (key, replacement) in [
            ("workspace_id", LoopdyJSONValue.string("other")), ("path", .string("another")),
            ("offset", .integer(1)), ("limit", .integer(500))
        ] {
            var payload = directory()
            payload[key] = replacement
            #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
        }
        #expect(throws: WorkspaceClientError.conflict) {
            try WorkspaceGrantedFilesDecoder.directory(directory(), workspaceID: "notes", path: "", offset: 0, limit: 100,
                expectedRevision: "sha256:" + String(repeating: "b", count: 64))
        }
    }

    @Test func paginationCannotSkipRepeatOrHideRemainingEntries() {
        var payload = directory()
        payload["total"] = .integer(200)
        #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
        payload["next_offset"] = .integer(0)
        #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
        payload["next_offset"] = .integer(100)
        #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
    }

    @Test func pageRejectsEntryFromAnotherDirectoryAndDuplicatePaths() {
        var payload = directory()
        let entry: LoopdyJSONValue = .object([
            "name": .string("hello.md"), "path": .string("other/hello.md"), "kind": .string("file"), "size": .integer(5)
        ])
        payload["entries"] = .array([entry])
        #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
        payload = directory()
        payload["entries"] = .array([validEntry(), validEntry()])
        payload["total"] = .integer(2)
        #expect(throws: WorkspaceManagementError.invalidResponse) { try decodePage(payload) }
    }

    @Test func chunkValidatesCoordinatesExactCountAndRevision() throws {
        let data = Data("hello".utf8)
        let revision = digest(data)
        let payload = chunk(data: data, size: 5, revision: revision)
        let result = try WorkspaceGrantedFilesDecoder.chunk(payload, workspaceID: "notes", path: "hello.md",
            offset: 0, limit: 65_536, expectedRevision: nil, expectedSize: nil)
        #expect(result.data == data)
        #expect(result.nextOffset == nil)
        #expect(throws: WorkspaceClientError.conflict) {
            try WorkspaceGrantedFilesDecoder.chunk(payload, workspaceID: "notes", path: "hello.md", offset: 0, limit: 65_536,
                expectedRevision: "sha256:" + String(repeating: "b", count: 64), expectedSize: 5)
        }
        var invalid = payload
        invalid["size"] = .integer(6)
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceGrantedFilesDecoder.chunk(invalid, workspaceID: "notes", path: "hello.md",
                offset: 0, limit: 65_536, expectedRevision: nil, expectedSize: nil)
        }
    }

    @Test func binaryAndOversizedAreUnavailableNotEmptySuccess() {
        for availability in ["binary", "oversized"] {
            let payload: [String: LoopdyJSONValue] = [
                "workspace_id": .string("notes"), "path": .string("hello.md"),
                "offset": .integer(0), "availability": .string(availability)
            ]
            #expect(throws: WorkspaceManagementError.filePreviewUnavailable) {
                try WorkspaceGrantedFilesDecoder.chunk(payload, workspaceID: "notes", path: "hello.md",
                    offset: 0, limit: 65_536, expectedRevision: nil, expectedSize: nil)
            }
        }
    }

    @Test func previewVerifiesFullContentDigestAndPreservesUnicode() throws {
        let content = "A synthetic note \u{1F30A}\nSecond line"
        let data = Data(content.utf8)
        let value = try WorkspaceGrantedFilesDecoder.preview(data: data, path: "notes/hello.md", revision: digest(data))
        #expect(value.text == content)
        #expect(value.name == "hello.md")
        #expect(throws: WorkspaceManagementError.filePreviewUnavailable) {
            try WorkspaceGrantedFilesDecoder.preview(data: Data("changed".utf8), path: "hello.md", revision: digest(data))
        }
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func capabilities() -> [String: LoopdyJSONValue] {
        ["schema_version": .integer(1), "read_only": .boolean(true), "host_grants_only": .boolean(true),
         "remote_grant_mutation": .boolean(false), "secure_traversal": .boolean(true),
         "max_file_bytes": .integer(8_388_608), "max_chunk_bytes": .integer(65_536), "max_directory_page": .integer(500),
         "roots": .array([.object(["workspace_id": .string("notes"), "label": .string("Notes")])])]
    }

    private func directory() -> [String: LoopdyJSONValue] {
        ["workspace_id": .string("notes"), "path": .string(""), "parent": .null,
         "revision": .string("sha256:" + String(repeating: "a", count: 64)),
         "offset": .integer(0), "limit": .integer(100), "total": .integer(1),
         "entries": .array([validEntry()]), "next_offset": .null]
    }

    private func validEntry() -> LoopdyJSONValue {
        .object(["name": .string("hello.md"), "path": .string("hello.md"), "kind": .string("file"), "size": .integer(5)])
    }

    private func decodePage(_ payload: [String: LoopdyJSONValue]) throws -> WorkspaceGrantedDirectoryPage {
        try WorkspaceGrantedFilesDecoder.directory(payload, workspaceID: "notes", path: "", offset: 0, limit: 100, expectedRevision: nil)
    }

    private func chunk(data: Data, size: Int, revision: String) -> [String: LoopdyJSONValue] {
        ["workspace_id": .string("notes"), "path": .string("hello.md"), "offset": .integer(0),
         "availability": .string("available"), "size": .integer(size), "revision": .string(revision),
         "data": .string(data.base64EncodedString()), "text": .string("hello"), "next_offset": .null]
    }
}
