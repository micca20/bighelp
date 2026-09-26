import Foundation
import Testing
@testable import Loopdy

@MainActor
struct WorkspaceArtifactsTests {
    @Test func recursiveIndexIncludesMixedTypesWithoutReadingBodies() async throws {
        let fixture = try ArtifactPerformer()
        fixture.listings["/workspace"] = listing("/workspace", entries: [
            entry("older.txt", timestamp: 1, mime: "text/plain"),
            entry("nested", directory: true),
            entry("unknown.bin", mime: "application/octet-stream"),
        ])
        fixture.listings["/workspace/nested"] = listing("/workspace/nested", entries: [
            entry("report.pdf", folder: "/workspace/nested", timestamp: 3, mime: "application/pdf"),
            entry("movie.mp4", folder: "/workspace/nested", timestamp: 2, mime: "video/mp4"),
        ])
        let store = try makeStore(fixture)
        await store.refresh()
        #expect(store.errorMessage == nil)
        #expect(store.files.map(\.name) == ["report.pdf", "movie.mp4", "older.txt", "unknown.bin"])
        // A plugin before 2.15 can't list recent files, so the app scans instead.
        #expect(fixture.calls.map(\.operation) == [.filesRecent, .filesList, .filesList])
        #expect(!store.isAgentIndex)
        #expect(store.files.last?.modifiedAt == nil)
        fixture.listings.removeAll()
        await store.refresh()
        #expect(store.files.count == 4)
        #expect(store.errorMessage != nil)
    }

    @Test func refreshDuringOpenReleasesBusyStateAndRejectsLatePreview() async throws {
        let fixture = try ArtifactPerformer()
        fixture.listings["/workspace"] = listing("/workspace", entries: [entry("report.txt", timestamp: 1, mime: "text/plain")])
        let store = try makeStore(fixture)
        await store.refresh()
        let file = try #require(store.files.first)
        let opening = Task { await store.open(file) }
        for _ in 0..<100 where fixture.pendingRead == nil { await Task.yield() }
        let continuation = try #require(fixture.pendingRead)
        #expect(store.isOpening)
        await store.refresh()
        #expect(!store.isOpening)
        continuation.resume(returning: [:])
        fixture.pendingRead = nil
        await opening.value
        #expect(!store.isOpening)
        #expect(store.openedAttachment == nil)
        #expect(store.openErrorMessage == nil)
    }

    @Test func literalWorkspaceBoundaryRejectsResolvedEscapeAndKeepsUnknownDates() throws {
        let valid = listing("/workspace", entries: [entry("report.txt", timestamp: 1.5, mime: "text/plain")])
        let decoded = try WorkspaceManagementDecoder.workspaceArtifacts(valid, expectedPath: "/workspace")
        #expect(decoded.parent == nil)
        #expect(decoded.entries.first?.modifiedAt == Date(timeIntervalSince1970: 1.5))
        #expect(decoded.entries.first?.mimeType == "text/plain")
        let escaped = listing("/workspace", entries: [entry("outside.txt", folder: "/outside")])
        #expect(throws: WorkspaceManagementError.fileRootNotConfined) {
            try WorkspaceManagementDecoder.workspaceArtifacts(escaped, expectedPath: "/workspace")
        }
    }

    @Test func populatedWorkspaceRetainsSiblingsWithoutFollowingEscapingLinks() async throws {
        let fixture = try ArtifactPerformer()
        let root = "/Volumes/Fixture's Disk/Team Workspace"
        func page(_ path: String, _ entries: [LoopdyJSONValue]) -> [String: LoopdyJSONValue] {
            ["path": .string(path), "parent": .string(URL(fileURLWithPath: path).deletingLastPathComponent().path),
             "entries": .array(entries), "root": .null, "locked_root": .null, "can_change_path": .boolean(true)]
        }
        fixture.listings[root] = page(root, [entry("mixed", folder: root, directory: true), entry("healthy", folder: root, directory: true)])
        fixture.listings[root + "/mixed"] = page(root + "/mixed", [
            entry("before.txt", folder: root + "/mixed", timestamp: 1.5, mime: "text/plain"),
            entry("outside-link", folder: "/outside", directory: true),
            .object(["name": .string("unsupported"), "path": .string(root + "/mixed/unsupported"), "size": .integer(-1)]),
            entry("after.txt", folder: root + "/mixed", timestamp: 3, mime: "text/plain"),
            entry("unreadable", folder: root + "/mixed", directory: true)
        ])
        fixture.listings[root + "/healthy"] = page(root + "/healthy", [
            entry("healthy.txt", folder: root + "/healthy", timestamp: 2, mime: "text/plain"),
            entry("unknown.bin", folder: root + "/healthy", mime: "application/octet-stream")
        ])
        let owner = try #require(fixture.owner)
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: root, owner: owner)
        let index = try await WorkspaceArtifactTreeEnumerator.load(scope: scope, owner: owner, performer: fixture, canContinue: { true })
        #expect(index.files.map(\.name) == ["after.txt", "healthy.txt", "before.txt", "unknown.bin"])
        #expect(index.files.last?.modifiedAt == nil)
        #expect(Set(index.diagnostics.map(\.kind)).isSuperset(of: [.outsideWorkspace, .unsupportedEntry, .unavailableBranch]))
        #expect(fixture.calls.allSatisfy { $0.operation == .filesList && ($0.payload["path"]?.string?.hasPrefix(root) ?? false) })
        #expect(fixture.calls.filter { $0.payload["path"] == .string(root + "/mixed/unreadable") }.count == 1)
    }

    @Test func creationOrderIgnoresLaterModificationAndKeepsUnknownDatesLast() async throws {
        let fixture = try ArtifactPerformer()
        var old = try #require(entry("old.txt", timestamp: 1).object)
        old["mtime"] = .number(1000)
        var newest = try #require(entry("new.txt", timestamp: 2).object)
        newest["mtime"] = .number(10)
        var unknown = try #require(entry("aaa-unknown.txt").object)
        unknown["mtime"] = .number(2000)
        fixture.listings["/workspace"] = listing("/workspace", entries: [.object(old), .object(unknown), .object(newest)])
        let store = try makeStore(fixture)
        await store.refresh()
        #expect(store.errorMessage == nil)
        #expect(store.files.map(\.name) == ["new.txt", "old.txt", "aaa-unknown.txt"])
        #expect(store.files.last?.createdAt == nil)
        #expect(store.files.last?.modifiedAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func recentFilesComeFromOneRequestInTheHostsOrder() async throws {
        let fixture = try ArtifactPerformer()
        var recent = listing("/workspace", entries: [
            entry("report.md", folder: "/workspace/deep/er", timestamp: 1, mime: "text/markdown"),
            entry("new.swift", folder: "/workspace", timestamp: 5, mime: "text/x-swift"),
            entry("clip.mp4", folder: "/workspace/media", timestamp: 3, mime: "video/mp4"),
        ])
        recent["parent"] = .null
        fixture.recent = recent
        let store = try makeStore(fixture)
        await store.refresh()
        #expect(store.errorMessage == nil)
        #expect(store.isAgentIndex)
        // The host ranks by when the agent wrote each file, not by creation date.
        #expect(store.files.map(\.name) == ["report.md", "new.swift", "clip.mp4"])
        #expect(fixture.calls.map(\.operation) == [.filesRecent])
    }

    @Test func fallbackScanSkipsToolingFoldersAndStaysShallow() async throws {
        let fixture = try ArtifactPerformer()
        fixture.listings["/workspace"] = listing("/workspace", entries: [
            entry("node_modules", directory: true), entry(".git", directory: true),
            entry("App.xcodeproj", directory: true), entry("a", directory: true),
            entry(".DS_Store", timestamp: 9), entry("top.txt", timestamp: 1, mime: "text/plain"),
        ])
        var folder = "/workspace"
        for name in ["a", "b", "c", "d"] {
            let child = folder + "/" + name
            let next = ["a": "b", "b": "c", "c": "d", "d": "e"][name]!
            var page = listing(child, entries: [
                entry(next, folder: child, directory: true),
                entry("\(name).txt", folder: child, timestamp: 2, mime: "text/plain"),
            ])
            page["parent"] = .string(folder)
            fixture.listings[child] = page
            folder = child
        }
        let store = try makeStore(fixture)
        await store.refresh()
        #expect(Set(store.files.map(\.name)) == ["top.txt", "a.txt", "b.txt", "c.txt"])
        let listed = fixture.calls.compactMap { $0.payload["path"]?.string }
        #expect(listed == ["/workspace", "/workspace/a", "/workspace/a/b", "/workspace/a/b/c"])
    }

    private func makeStore(_ fixture: ArtifactPerformer) throws -> WorkspaceArtifactsStore {
        let owner = try #require(fixture.owner)
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: "/workspace", owner: owner)
        return WorkspaceArtifactsStore(hostName: "Fixture Hermes", owner: owner,
            scope: scope, performer: fixture, scopeValidator: { scope }, isCurrent: { true })
    }

    private func entry(_ name: String, folder: String = "/workspace", directory: Bool = false,
                       timestamp: Double? = nil, mime: String? = "application/octet-stream") -> LoopdyJSONValue {
        .object(["name": .string(name), "path": .string(folder + "/" + name),
                 "is_directory": .boolean(directory), "size": directory ? .null : .integer(5),
                 "created": timestamp.map(LoopdyJSONValue.number) ?? .null,
                 "mtime": timestamp.map(LoopdyJSONValue.number) ?? .null,
                 "mime_type": directory ? .null : (mime.map(LoopdyJSONValue.string) ?? .null)])
    }

    private func listing(_ path: String, entries: [LoopdyJSONValue]) -> [String: LoopdyJSONValue] {
        ["path": .string(path), "parent": .string(path == "/workspace" ? "/" : "/workspace"),
         "entries": .array(entries), "root": .null, "locked_root": .null, "can_change_path": .boolean(true)]
    }
}

@MainActor
private final class ArtifactPerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: LoopdyJSONValue] }
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities
    var calls: [Call] = []
    var listings: [String: [String: LoopdyJSONValue]] = [:]
    /// The host's `files.recent` answer; nil acts like a plugin before 2.15.
    var recent: [String: LoopdyJSONValue]?
    var pendingRead: CheckedContinuation<[String: LoopdyJSONValue], any Error>?

    init() throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "artifacts-test"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        self.owner = owner
        capabilities = .init(owner: owner, values: [.filesRead: .available])
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: LoopdyJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: LoopdyJSONValue] {
        guard self.owner == owner else { throw WorkspaceClientError.ownerChanged }
        calls.append(.init(operation: operation, payload: payload))
        if operation == .filesRead {
            return try await withCheckedThrowingContinuation { pendingRead = $0 }
        }
        if operation == .filesRecent {
            guard let recent else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
            return recent
        }
        guard operation == .filesList, let path = payload["path"]?.string, let result = listings[path] else {
            throw WorkspaceManagementError.invalidResponse
        }
        return result
    }
}
