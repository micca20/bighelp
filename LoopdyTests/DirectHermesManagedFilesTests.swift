import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesManagedFilesTests {
    @Test func hostConfiguredRootIsDiscoveredWithoutLiteralFallback() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        let result = try await client.list()
        #expect(result.path == http.root)
        #expect(result.parent == nil)
        #expect(result.files.map(\.path) == [http.root + "/result.txt"])
        #expect(http.requests.first?.path == "/api/plugins/loopdy/native/context")
        #expect(http.requests.contains { $0.path == "/api/plugins/loopdy/native/workspace-files/list" })
        #expect(!http.requests.contains { $0.path.hasPrefix("/api/files") || $0.path == "/api/fs/default-cwd" })
        #expect(!http.requests.contains { $0.query.contains { $0.value == "/workspace" } })
    }

    @Test func traversalAndForeignRootsNeverReadTheirFileContents() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: http.root, owner: owner)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, scope: scope, currentOwner: { owner })
        for path in ["/", http.root + "/../private", http.root + "-other", http.root + "//folder"] {
            await #expect(throws: (any Error).self) { _ = try await client.list(path: path) }
        }
        #expect(http.requests.allSatisfy { $0.path == "/api/plugins/loopdy/native/context" || $0.path == "/api/plugins/loopdy/native/workspace-files/scope" })
    }

    @Test func wrongOwnerNeverReadsAndLateOwnerCannotPublish() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        var current: WorkspaceOwner? = nil
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { current })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.isEmpty)
        current = owner
        http.onRequest = { current = nil }
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.count == 1)
    }

    @Test func listingCannotSmuggleOutsideWorkspaceEntries() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root, filePath: "/private/result.txt")
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
    }

    @Test func posixScopeDoesNotMergeUnicodeEquivalentPaths() throws {
        let owner = try makeOwner()
        let scope = try DirectHermesWorkspaceFileScope.fixture(root: "/srv/caf\u{e9}", owner: owner)
        #expect(scope.contains("/srv/caf\u{e9}/file.txt"))
        #expect(!scope.contains("/srv/cafe\u{301}/file.txt"))
        #expect(!DirectHermesWorkspaceFileScope.samePath("/srv/caf\u{e9}", "/srv/cafe\u{301}"))
    }

    @Test func changedDefaultWorkspaceRevokesOldListingScope() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.result = listing(root: http.root)
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.workspaceScope()
        http.requests.removeAll()
        http.cwdResponse = .object(["cwd": .string("/srv/replacement"), "branch": .string("")])
        await #expect(throws: DirectHermesManagedFilesError.scopeChanged) { _ = try await client.list() }
        #expect(http.requests.allSatisfy { $0.path == "/api/plugins/loopdy/native/context" || $0.path == "/api/plugins/loopdy/native/workspace-files/scope" })
    }

    @Test func missingDefaultWorkspaceDoesNotFallBackToAnyRoot() async throws {
        let owner = try makeOwner()
        let http = ManagedFilesTestHTTP()
        http.cwdResponse = .object(["branch": .string("")])
        let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) { _ = try await client.list() }
        #expect(http.requests.count == 2)
        #expect(http.requests.last?.path == "/api/plugins/loopdy/native/workspace-files/scope")
    }

    @Test func driveRootAndLockedBroaderRootKeepWorkspaceBoundary() throws {
        let owner = try makeOwner()
        let windows = try DirectHermesWorkspaceFileScope.fixture(root: "C:\\", owner: owner)
        #expect(windows.contains("c:\\folder\\file.txt"))
        #expect(!windows.contains("D:\\folder\\file.txt"))
        let locked = try DirectHermesWorkspaceFileScope.fixture(root: "/opt/data/project", owner: owner, lockedManagedRoot: "/opt/data")
        #expect(locked.contains("/opt/data/project/file"))
        #expect(!locked.contains("/opt/data/other"))
        #expect(throws: DirectHermesManagedFilesError.self) { try locked.parent(of: locked.root) }
    }

    private func makeOwner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "files"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    private func listing(root: String, filePath: String? = nil) -> LoopdyJSONValue {
        .object(["path": .string(root), "parent": .string("/srv/team"), "can_change_path": .boolean(true),
            "root": .null, "locked_root": .null, "entries": .array([
                .object(["name": .string("result.txt"), "path": .string(filePath ?? root + "/result.txt"), "is_directory": .boolean(false),
                    "size": .integer(3), "mtime": .integer(1), "mime_type": .string("text/plain")])
            ])])
    }
}

@MainActor
private final class ManagedFilesTestHTTP: DirectHermesAuthenticatedHTTP, DirectHermesNativeHTTP {
    let root = "/srv/team/project"
    var requests: [DirectHermesHTTPRequest] = []
    var result: LoopdyJSONValue = .object([:])
    var cwdResponse: LoopdyJSONValue?
    var onRequest: (@MainActor () -> Void)?
    func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        requests.append(request)
        throw WorkspaceClientError.invalidRequest
    }
    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        requests.append(request)
        onRequest?()
        let etag = "\"sha256:" + String(repeating: "a", count: 64) + "\""
        var headers = ["ETag": etag, "Cache-Control": "no-store"]
        var object: [String: LoopdyJSONValue]
        if request.path == "/api/plugins/loopdy/native/context" {
            object = ["schemaVersion": .integer(1), "pluginVersion": .string("test"),
                "runtimeId": .string("fixture-runtime"), "servingProfileId": .string("default"),
                "principal": .object(["provider": .string("test"), "userId": .string("files"), "displayName": .null]),
                "features": .array([.string("native-context-v1"), .string("serving-profile-v1"), .string("native-workspace-files-v1")])]
        } else {
            let guardValue = try #require(requestGuard)
            headers["X-Loopdy-Request-ID"] = guardValue.requestIDHeader
            let configured: String
            if let cwdResponse {
                guard let value = cwdResponse.object?["cwd"]?.string else { throw WorkspaceClientError.invalidResponse }
                configured = value
            } else { configured = root }
            object = request.path.hasSuffix("/list") ? result.object ?? [:] : ["entries": .array([])]
            object["workspace"] = .object(["root": .string(configured), "source": .string("terminal.cwd"), "profileId": .string("default")])
            object["path"] = .string(configured)
            object["root"] = .string(configured)
            object["locked_root"] = .string(configured)
            object["can_change_path"] = .boolean(false)
            object["parent"] = .null
        }
        let url = try #require(URL(string: "https://fixture.example.test" + request.path))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers))
        return .init(http: response, body: try JSONEncoder().encode(LoopdyJSONValue.object(object)))
    }
}
