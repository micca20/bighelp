import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct WorkspaceGrantedFilesClientTests {
    @Test func rootSelectionDoesNotAutomaticallyReadFolders() async throws {
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities()]
        let value = try await client(transport).load(path: nil, root: nil)
        #expect(value == .fileRoots([.init(id: "notes", label: "Notes")]))
        #expect(transport.calls.map(\.operation) == [.managedFilesCapabilities])
    }

    @Test func realDirectoryPagingCarriesRevisionAndReprobesGrant() async throws {
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities(), capabilities()]
        transport.responses[.managedFilesList] = [
            page(name: "a.txt", offset: 0, next: 1), page(name: "b.txt", offset: 1, next: nil)
        ]
        let files = client(transport)
        guard case .files(let first) = try await files.load(path: "", root: "notes") else {
            Issue.record("Expected first page")
            return
        }
        #expect(first.entries.map(\.path) == ["a.txt"])
        #expect(first.nextPage?.offset == 1)
        let combined = try await files.nextPage(first)
        #expect(combined.entries.map(\.path) == ["a.txt", "b.txt"])
        #expect(combined.nextPage == nil)
        let calls = transport.calls.filter { $0.operation == .managedFilesList }
        #expect(calls[0].payload["revision"] == nil)
        #expect(calls[1].payload["revision"] == .string(directoryRevision))
        #expect(transport.calls.map(\.operation) == [.managedFilesCapabilities, .managedFilesList, .managedFilesCapabilities, .managedFilesList])
    }

    @Test func revokedRootBlocksNextPageBeforeFileRequest() async throws {
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities(), capabilities(roots: [])]
        transport.responses[.managedFilesList] = [page(name: "a.txt", offset: 0, next: 1)]
        let files = client(transport)
        guard case .files(let first) = try await files.load(path: "", root: "notes") else {
            Issue.record("Expected first page")
            return
        }
        await #expect(throws: (any Error).self) { try await files.nextPage(first) }
        #expect(transport.calls.filter { $0.operation == .managedFilesList }.count == 1)
    }

    @Test func servingProfileAndOwnerMustMatchBeforeAnyRequest() async throws {
        let transport = try GrantPerformer()
        let files = WorkspaceGrantedFilesClient(owner: transport.owner!, profileID: "research",
            servingProfileID: nil, performer: transport, isCurrent: { true })
        await #expect(throws: (any Error).self) { try await files.load(path: nil, root: nil) }
        #expect(transport.calls.isEmpty)
    }

    @Test func ownerChangeDuringCapabilityResponseCannotReleaseRootList() async throws {
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities()]
        transport.replacesOwner = true
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await client(transport).load(path: nil, root: nil)
        }
        #expect(transport.calls.count == 1)
    }

    @Test func completePreviewIsByteVerifiedNotBasedOnServerTextField() async throws {
        let data = Data("Synthetic note \u{1F30A}".utf8)
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities()]
        transport.responses[.managedFilesRead] = [chunk(data, size: data.count, offset: 0, next: nil, revision: digest(data))]
        let preview = try await client(transport).preview(path: "a.txt", root: "notes")
        #expect(preview.text == "Synthetic note \u{1F30A}")
        #expect(!preview.text.contains("ignored"))
    }

    @Test func changedChunkRevisionNeverReturnsPartialPreview() async throws {
        let data = Data("abcdef".utf8)
        let transport = try GrantPerformer()
        transport.responses[.managedFilesCapabilities] = [capabilities()]
        transport.responses[.managedFilesRead] = [
            chunk(Data(data.prefix(3)), size: 6, offset: 0, next: 3, revision: digest(data)),
            chunk(Data(data.suffix(3)), size: 6, offset: 3, next: nil, revision: digest(Data("changed".utf8)))
        ]
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client(transport).preview(path: "a.txt", root: "notes")
        }
        #expect(transport.calls.last?.payload["revision"] == .string(digest(data)))
    }

    private let directoryRevision = "sha256:" + String(repeating: "a", count: 64)

    private func client(_ performer: GrantPerformer) -> WorkspaceGrantedFilesClient {
        .init(owner: performer.owner!, profileID: "research", servingProfileID: "research", performer: performer, isCurrent: { true })
    }

    private func capabilities(roots: [BighelpJSONValue]? = nil) -> [String: BighelpJSONValue] {
        ["schema_version": .integer(1), "read_only": .boolean(true), "host_grants_only": .boolean(true),
         "remote_grant_mutation": .boolean(false), "secure_traversal": .boolean(true),
         "max_file_bytes": .integer(8_388_608), "max_chunk_bytes": .integer(65_536), "max_directory_page": .integer(1),
         "roots": .array(roots ?? [.object(["workspace_id": .string("notes"), "label": .string("Notes")])])]
    }

    private func page(name: String, offset: Int, next: Int?) -> [String: BighelpJSONValue] {
        ["workspace_id": .string("notes"), "path": .string(""), "parent": .null,
         "revision": .string(directoryRevision), "offset": .integer(offset), "limit": .integer(1), "total": .integer(2),
         "entries": .array([.object(["name": .string(name), "path": .string(name), "kind": .string("file"), "size": .integer(6)])]),
         "next_offset": next.map(BighelpJSONValue.integer) ?? .null]
    }

    private func chunk(_ data: Data, size: Int, offset: Int, next: Int?, revision: String) -> [String: BighelpJSONValue] {
        ["workspace_id": .string("notes"), "path": .string("a.txt"), "offset": .integer(offset),
         "availability": .string("available"), "size": .integer(size), "revision": .string(revision),
         "data": .string(data.base64EncodedString()), "text": .string("ignored"),
         "next_offset": next.map(BighelpJSONValue.integer) ?? .null]
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class GrantPerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner) }
    var responses: [WorkspaceOperation: [[String: BighelpJSONValue]]] = [:]
    var calls: [Call] = []
    var replacesOwner = false

    init() throws {
        owner = .init(authority: try .fixture(id: "granted-files"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        guard let first = responses[operation]?.first else { throw WorkspaceClientError.invalidResponse }
        responses[operation]?.removeFirst()
        if replacesOwner {
            self.owner = .init(authority: owner.authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        }
        return first
    }
}
