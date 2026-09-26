import Foundation

/// Credential-free, simulator-only replay through the production Wiki client.
/// Never connects to a host or substitutes data in a signed-in Wiki store.
enum WikiHomeAcceptanceFixture {
    @MainActor static func makeStoreIfRequested() -> WikiStore? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures"),
              ProcessInfo.processInfo.arguments.contains("-test-wiki-home") else { return nil }
        let messaging = WikiHomeFixtureMessaging()
        if ProcessInfo.processInfo.arguments.contains("-test-wiki-home-root") {
            messaging.failures["README.md"] = "SECRET_SCAN_BLOCKED"
        }
        return messaging.makeStore()
        #else
        return nil
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class WikiHomeFixtureMessaging: LoopdyLinkWorkspaceMessaging {
    let owner = WikiOwner(accountID: "wiki-fixture-account", hostID: "wiki-fixture-host",
                          profileID: "default", deviceID: "wiki-fixture-device", authorizationEpoch: "1")
    let generation = String(repeating: "a", count: 32)
    var failures = ["index.md": "SECRET_SCAN_BLOCKED"]
    var reads: [String] = []
    var listings: [String] = []
    var beforeReadResult: ((String) async -> Void)?

    func makeStore() -> WikiStore {
        let client = WikiLinkClient(owner: owner, workspace: LoopdyLinkWorkspaceClient(messaging: self),
                                   currentOwner: { [owner] in owner })
        return WikiStore(owner: owner, client: client, persistence: WikiHomeFixturePersistence())
    }

    func performWorkspaceRequest(_ request: LoopdyLinkWorkspaceRequest) async throws -> LoopdyLinkWorkspaceResult {
        throw WikiError.unavailable // The production client must use prepared requests.
    }

    func performPreparedWorkspaceRequest(_ request: LoopdyLinkWorkspaceRequest) async throws -> LoopdyLinkWorkspaceResult {
        let root: [String: Any] = ["wikiId": "notes", "name": "Fixture Wiki", "writable": false,
                                   "sourceKind": "files", "generation": generation, "folderPath": "/fixture-notes"]
        var payload: [String: Any] = [:]
        var code: String?
        switch request.operation {
        case .wikiRoots: payload = ["roots": [root]]
        case .wikiConnect: payload = root
        case .wikiRead:
            let path = request.payload["path"]?.string ?? ""
            reads.append(path)
            await beforeReadResult?(path)
            code = failures[path]
            if code == nil {
                let bytes = Data("# Welcome to your Wiki\nReadable home page.\n".utf8)
                payload = ["wikiId": "notes", "path": path, "availability": "available", "size": bytes.count,
                           "offset": 0, "data": bytes.base64EncodedString(),
                           "revision": "wiki-v1:\(generation):\(WikiLimits.digest(bytes))", "nextOffset": NSNull()]
            }
        case .wikiList:
            let path = request.payload["path"]?.string ?? ""
            listings.append(path)
            let entryPath = path.isEmpty ? "notes.md" : path + "/notes.md"
            payload = ["wikiId": "notes", "path": path, "parent": WikiNavigation.parent(of: path) as Any? ?? NSNull(),
                       "revision": "wiki-v1:\(generation):\(WikiLimits.digest(Data("directory".utf8)))",
                       "offset": 0, "limit": 100, "total": 1, "nextOffset": NSNull(),
                       "entries": [["name": "notes.md", "path": entryPath, "kind": "file", "size": 20]]]
        default: throw WikiError.unavailable
        }
        var value: [String: Any] = ["version": 1, "type": "workspace.result", "requestId": request.requestID,
                                   "operation": request.operation.rawValue, "status": code == nil ? "completed" : "failed",
                                   "payload": payload, "sentAt": 1]
        if let code { value["code"] = code; value["message"] = "Host refused this request" }
        return try JSONDecoder().decode(LoopdyLinkWorkspaceResult.self,
                                       from: JSONSerialization.data(withJSONObject: value))
    }
}

@MainActor private final class WikiHomeFixturePersistence: WikiPersistence {
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] {
        [WikiFolderPreference(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                              name: "Fixture Wiki", folderPath: "/fixture-notes")]
    }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws { }
    func load(owner: WikiOwner) throws -> WikiLocalState? { nil }
    func save(_ state: WikiLocalState) throws { }
    func deleteAccount(accountID: String) throws { }
}
#endif
