import Foundation

@MainActor
final class DirectHermesWikiClient: WikiClientProtocol {
    let owner: WikiOwner
    private let scope: DirectHermesCoreRequestScope
    private let codec: WikiLinkClient
    private var disconnectedRootIDs: Set<String> = []

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner, profileID: String,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) throws {
        let profile = try DirectHermesCoreRequestScope.profile(profileID)
        let wikiOwner = try WikiOwner.native(authority: owner.authority, profileID: profile)
        let scope = DirectHermesCoreRequestScope(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.owner = wikiOwner
        self.scope = scope
        codec = WikiLinkClient(owner: wikiOwner, nativeRequest: { operation, payload in
            let native = try Self.operation(operation)
            try scope.require(Self.capability(native), profile: profile)
            return try await scope.perform(native, payload)
        }, currentOwner: {
            guard currentOwner() == owner, workspace.owner == owner else { return nil }
            return wikiOwner
        })
    }

    var supportsRemoteDisconnect: Bool {
        (try? scope.check()) != nil
            && scope.workspace.capabilities.supports(.wikiDisconnect, owner: scope.owner, profileID: owner.profileID)
    }

    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage {
        try await codec.folderSuggestions(parentPath: parentPath, prefix: prefix, offset: offset)
    }
    func roots() async throws -> [WikiRoot] {
        try await codec.roots().filter { !disconnectedRootIDs.contains($0.wikiId) }
    }
    func resolve(folderPath: String) async throws -> WikiRoot {
        let root = try await codec.resolve(folderPath: folderPath)
        try requireRoot(root)
        return root
    }
    func connect(folderPath: String) async throws -> WikiRoot {
        let root = try await codec.connect(folderPath: folderPath)
        try requireRoot(root)
        return root
    }
    func list(root: WikiRoot, path: String, offset: Int, revision: String?) async throws -> WikiDirectory {
        try await withRoot(root) { try await codec.list(root: root, path: path, offset: offset, revision: revision) }
    }
    func read(root: WikiRoot, path: String) async throws -> WikiBytes {
        try await withRoot(root) { try await codec.read(root: root, path: path) }
    }
    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int) async throws -> WikiSearchPage {
        try await withRoot(root) { try await codec.search(root: root, query: query, mode: mode, offset: offset) }
    }
    func image(root: WikiRoot, path: String) async throws -> WikiBytes {
        try await withRoot(root) { try await codec.image(root: root, path: path) }
    }
    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse {
        try requireRoot(save.document.root)
        return try await codec.begin(save)
    }
    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse {
        try await codec.chunk(operationID: operationID, offset: offset, data: data)
    }
    func commit(operationID: String) async throws -> WikiSaveResponse { try await codec.commit(operationID: operationID) }
    func status(operationID: String) async throws -> WikiSaveResponse { try await codec.status(operationID: operationID) }

    func disconnect(root: WikiRoot) async throws {
        try scope.require(.wikiDisconnect, profile: owner.profileID)
        guard disconnectedRootIDs.contains(root.wikiId) || disconnectedRootIDs.count < 1_024 else {
            throw WikiError.remote("QUOTA_EXCEEDED")
        }
        guard !root.wikiId.isEmpty, root.wikiId.utf8.count <= 180,
              root.wikiId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }),
              WikiLimits.validGeneration(root.generation) else { throw WikiError.invalidResponse }
        do {
            let result = try await scope.perform(.wikiDisconnect, [
                "agentId": .string(owner.profileID), "wikiId": .string(root.wikiId)
            ])
            guard result["wikiId"]?.string == root.wikiId, result["disconnected"]?.boolean == true else {
                throw WikiError.invalidResponse
            }
            disconnectedRootIDs.insert(root.wikiId)
        } catch {
            try scope.check()
            throw WikiError.safe(error)
        }
    }

    private func requireRoot(_ root: WikiRoot) throws {
        guard !disconnectedRootIDs.contains(root.wikiId) else { throw WikiError.remote("WIKI_NOT_ALLOWED") }
    }

    private func withRoot<T: Sendable>(_ root: WikiRoot, _ action: @MainActor () async throws -> T) async throws -> T {
        try requireRoot(root)
        let result = try await action()
        try requireRoot(root)
        return result
    }

    private static func operation(_ operation: LoopdyLinkWorkspaceOperation) throws -> WorkspaceOperation {
        switch operation {
        case .wikiRoots: .wikiRoots
        case .wikiConnect: .wikiConnect
        case .wikiResolve: .wikiResolve
        case .wikiList: .wikiList
        case .wikiRead: .wikiRead
        case .wikiSearch: .wikiSearch
        case .wikiImage: .wikiImage
        case .wikiSaveBegin: .wikiSaveBegin
        case .wikiSaveChunk: .wikiSaveChunk
        case .wikiSaveCommit: .wikiSaveCommit
        case .wikiSaveStatus: .wikiSaveStatus
        default: throw WikiError.unavailable
        }
    }

    private static func capability(_ operation: WorkspaceOperation) -> WorkspaceCapability {
        switch operation {
        case .wikiConnect, .wikiSaveBegin, .wikiSaveChunk, .wikiSaveCommit: .wikiEdit
        default: .wikiRead
        }
    }
}
