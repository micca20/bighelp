import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesWikiClientTests {
    @Test func nativeRootsAndConnectUseOnlyFixedOperationsAndAgentCoordinate() async throws {
        let transport = try WikiNativePerformer()
        transport.responses[.wikiRoots] = [["roots": .array([.object(rootPayload())])]]
        transport.responses[.wikiConnect] = [rootPayload()]
        let client = try client(transport)
        #expect(client.owner.deviceID == nil)
        #expect(try await client.roots().count == 1)
        #expect(try await client.connect(folderPath: "/notes").wikiId == "wiki_notes")
        #expect(transport.calls[0].payload == ["agentId": .string("default")])
        #expect(transport.calls[1].payload == ["agentId": .string("default"), "folderPath": .string("/notes")])
        #expect(transport.calls.map(\.operation) == [.wikiRoots, .wikiConnect])
    }

    @Test func unauthenticatedAuthorityCannotConstructNativeWikiClient() throws {
        let transport = try WikiNativePerformer()
        transport.owner = .init(authority: try .fixture(id: "not-a-login"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        #expect(throws: WikiError.ownerChanged) { try client(transport) }
        #expect(transport.calls.isEmpty)
    }

    @Test func unadvertisedNativeWikiMakesNoRequest() async throws {
        let transport = try WikiNativePerformer()
        transport.available = false
        await #expect(throws: WikiError.unavailable) { try await client(transport).roots() }
        #expect(transport.calls.isEmpty)
    }

    @Test func bytesKeepExistingRevisionAndDigestValidation() async throws {
        let transport = try WikiNativePerformer()
        let bytes = Data("\u{FEFF}# Notes\r\n".utf8)
        transport.responses[.wikiRead] = [file(bytes)]
        let value = try await client(transport).read(root: root(), path: "note.md")
        #expect(value.data == bytes)
        #expect(transport.calls.first?.payload == [
            "agentId": .string("default"), "wikiId": .string("wiki_notes"), "path": .string("note.md"),
            "offset": .integer(0), "limit": .integer(WikiLimits.chunkBytes)
        ])
    }

    @Test func uploadAndStatusPreserveExactOperationWithoutEnrollmentFields() async throws {
        let transport = try WikiNativePerformer()
        let client = try client(transport)
        let save = try pending(owner: client.owner)
        transport.responses[.wikiSaveBegin] = [receiving(save)]
        transport.responses[.wikiSaveChunk] = [receiving(save, offset: save.bytes.count)]
        transport.responses[.wikiSaveCommit] = [[
            "operationId": .string(save.id), "status": .string("committed"),
            "revision": .string(revision(save.bytes))
        ]]
        transport.responses[.wikiSaveStatus] = [receiving(save)]
        _ = try await client.begin(save)
        _ = try await client.chunk(operationID: save.id, offset: 0, data: save.bytes)
        _ = try await client.commit(operationID: save.id)
        _ = try await client.status(operationID: save.id)
        #expect(transport.calls.map(\.operation) == [.wikiSaveBegin, .wikiSaveChunk, .wikiSaveCommit, .wikiSaveStatus])
        for call in transport.calls {
            #expect(call.payload["agentId"] == .string("default"))
            #expect(call.payload["operationId"] == .string(save.id))
            #expect(call.payload["deviceId"] == nil)
            #expect(call.payload["principal"] == nil)
            #expect(call.payload["profile"] == nil)
        }
        #expect(transport.calls[0].payload["sha256"] == .string(save.sha256))
    }

    @Test func creationCapabilityNeverOverridesReadOnlySource() async throws {
        let transport = try WikiNativePerformer()
        let client = try client(transport)
        let readOnly = WikiRoot(wikiId: "wiki_notes", name: "Generated", writable: false,
            sourceKind: "generated", generation: generation, folderPath: "/notes", supportsCreation: true)
        let save = try pending(owner: client.owner, root: readOnly)
        await #expect(throws: WikiError.readOnly) { try await client.begin(save) }
        #expect(transport.calls.isEmpty)
    }

    @Test func explicitDisconnectValidatesReceiptAndRetiresOldRoot() async throws {
        let transport = try WikiNativePerformer()
        transport.responses[.wikiDisconnect] = [["wikiId": .string("wiki_notes"), "disconnected": .boolean(true)]]
        transport.responses[.wikiRoots] = [["roots": .array([.object(rootPayload())])]]
        let client = try client(transport)
        try await client.disconnect(root: root())
        #expect(transport.calls.first?.payload == ["agentId": .string("default"), "wikiId": .string("wiki_notes")])
        #expect(try await client.roots().isEmpty)
        await #expect(throws: WikiError.remote("WIKI_NOT_ALLOWED")) { try await client.read(root: root(), path: "note.md") }
        #expect(!transport.calls.contains { $0.operation == .wikiRead })
    }

    @Test func wrongDisconnectReceiptDoesNotRetireOrClaimSuccess() async throws {
        let transport = try WikiNativePerformer()
        transport.responses[.wikiDisconnect] = [["wikiId": .string("another"), "disconnected": .boolean(true)]]
        transport.responses[.wikiRoots] = [["roots": .array([.object(rootPayload())])]]
        let client = try client(transport)
        await #expect(throws: WikiError.invalidResponse) { try await client.disconnect(root: root()) }
        #expect(try await client.roots().count == 1)
    }

    @Test func lateReadCannotReappearAfterConfirmedDisconnect() async throws {
        let transport = try WikiNativePerformer()
        transport.suspendRead = true
        transport.responses[.wikiDisconnect] = [["wikiId": .string("wiki_notes"), "disconnected": .boolean(true)]]
        let client = try client(transport)
        let read = Task { try await client.read(root: root(), path: "note.md") }
        for _ in 0..<100 where transport.readContinuation == nil { await Task.yield() }
        let continuation = try #require(transport.readContinuation)
        try await client.disconnect(root: root())
        continuation.resume(returning: file(Data("old response".utf8)))
        await #expect(throws: WikiError.remote("WIKI_NOT_ALLOWED")) { try await read.value }
    }

    @Test func freshReconnectRootDoesNotAdoptRetiredIdentity() async throws {
        let transport = try WikiNativePerformer()
        transport.responses[.wikiDisconnect] = [["wikiId": .string("wiki_notes"), "disconnected": .boolean(true)]]
        var fresh = rootPayload()
        fresh["wikiId"] = .string("wiki_fresh")
        fresh["generation"] = .string(String(repeating: "b", count: 32))
        transport.responses[.wikiConnect] = [fresh]
        let client = try client(transport)
        try await client.disconnect(root: root())
        let connected = try await client.connect(folderPath: "/notes")
        #expect(connected.wikiId == "wiki_fresh")
        #expect(!connected.matchesGrant(root()))
    }

    @Test func localDisconnectAndContextClearNeverInvokeHostRevocation() async throws {
        let transport = try WikiNativePerformer()
        transport.responses[.wikiConnect] = [rootPayload()]
        let client = try client(transport)
        let store = WikiStore(owner: client.owner, client: client, persistence: NativeWikiMemory())
        let connection = try await store.connect(name: "Notes", folderPath: "/notes")
        try store.disconnect(connection)
        store.setContext(owner: nil, client: nil)
        #expect(transport.calls.map(\.operation) == [.wikiConnect])
    }

    @Test func hostDisconnectKeepsPendingRecoveryAndRemovesOnlyAccessState() async throws {
        let transport = try WikiNativePerformer()
        let client = try client(transport)
        let save = try pending(owner: client.owner)
        let memory = NativeWikiMemory()
        memory.state = .init(owner: client.owner, connections: [save.document.connection], saves: [save])
        memory.folders = [.init(id: save.document.connection.id, name: "Notes", folderPath: "/notes", readOnly: false)]
        transport.responses[.wikiRoots] = [["roots": .array([.object(rootPayload())])]]
        transport.responses[.wikiResolve] = [rootPayload()]
        transport.responses[.wikiDisconnect] = [["wikiId": .string("wiki_notes"), "disconnected": .boolean(true)]]
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        try await store.discoverRoots()
        let connection = try #require(store.connections.first)
        try await store.disconnectOnHost(connection)
        #expect(store.connections.isEmpty)
        #expect(store.authorizedRoots.isEmpty)
        #expect(store.pendingSaves.map(\.id) == [save.id])
        #expect(memory.state?.saves.first?.bytes == save.bytes)
        #expect(memory.folders.isEmpty)
        #expect(transport.calls.filter { $0.operation == .wikiDisconnect }.count == 1)
        #expect(!transport.calls.contains { $0.operation == .wikiSaveCommit })
        #expect(!transport.calls.contains { $0.operation == .wikiConnect })
    }

    @Test func cachedNativeFolderNeverRecreatesARevokedGrantOnDiscovery() async throws {
        let transport = try WikiNativePerformer()
        let client = try client(transport)
        let memory = NativeWikiMemory()
        memory.folders = [.init(id: UUID(), name: "Notes", folderPath: "/notes")]
        transport.responses[.wikiRoots] = [["roots": .array([])]]
        transport.failures[.wikiResolve] = .rejected(code: "WIKI_NOT_ALLOWED")
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        await #expect(throws: WikiError.remote("WIKI_NOT_ALLOWED")) { try await store.discoverRoots() }
        #expect(store.connections.isEmpty)
        #expect(transport.calls.map(\.operation) == [.wikiRoots, .wikiResolve])
        #expect(!transport.calls.contains { $0.operation == .wikiConnect })
    }

    private let generation = String(repeating: "a", count: 32)

    private func client(_ transport: WikiNativePerformer) throws -> DirectHermesWikiClient {
        try .init(workspace: transport, owner: transport.owner!, profileID: "default", currentOwner: { transport.owner })
    }

    private func root() -> WikiRoot {
        .init(wikiId: "wiki_notes", name: "Notes", writable: true, sourceKind: "files", generation: generation,
            folderPath: "/notes", supportsCreation: true)
    }

    private func rootPayload() -> [String: LoopdyJSONValue] {
        ["wikiId": .string("wiki_notes"), "name": .string("Notes"), "writable": .boolean(true),
         "sourceKind": .string("files"), "generation": .string(generation), "folderPath": .string("/notes"),
         "supportsCreation": .boolean(true)]
    }

    private func revision(_ bytes: Data) -> String { "wiki-v1:\(generation):\(WikiLimits.digest(bytes))" }

    private func file(_ bytes: Data) -> [String: LoopdyJSONValue] {
        ["wikiId": .string("wiki_notes"), "path": .string("note.md"), "availability": .string("available"),
         "size": .integer(bytes.count), "offset": .integer(0), "data": .string(bytes.base64EncodedString()),
         "revision": .string(revision(bytes)), "nextOffset": .null]
    }

    private func pending(owner: WikiOwner, root: WikiRoot? = nil) throws -> WikiPendingSave {
        let original = Data("# Original\n".utf8)
        let connection = WikiConnection(owner: owner, name: "Notes", root: root ?? self.root(), readOnly: false)
        let document = try WikiDocument(connection: connection, path: "note.md",
            bytes: .init(data: original, revision: revision(original)))
        let source = "# Updated\n"
        return .init(operationId: "save-fixture", document: document, workingSource: source,
            sha256: WikiLimits.digest(Data(source.utf8)), phase: .prepared, nextOffset: 0)
    }

    private func receiving(_ save: WikiPendingSave, offset: Int = 0) -> [String: LoopdyJSONValue] {
        ["operationId": .string(save.id), "status": .string("receiving"),
         "nextOffset": .integer(offset), "totalBytes": .integer(save.bytes.count)]
    }
}

@MainActor
private final class WikiNativePerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: LoopdyJSONValue] }
    var owner: WorkspaceOwner?
    var available = true
    var capabilities: WorkspaceCapabilities {
        .init(owner: owner, values: available ? [.wikiRead: .available, .wikiEdit: .available, .wikiDisconnect: .available] : [:])
    }
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [[String: LoopdyJSONValue]]] = [:]
    var failures: [WorkspaceOperation: WorkspaceClientError] = [:]
    var suspendRead = false
    var readContinuation: CheckedContinuation<[String: LoopdyJSONValue], any Error>?

    init() throws {
        owner = .init(authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "password", userID: "synthetic"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: LoopdyJSONValue], owner: WorkspaceOwner) async throws -> [String: LoopdyJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        if let failure = failures[operation] { throw failure }
        if operation == .wikiRead && suspendRead { return try await withCheckedThrowingContinuation { readContinuation = $0 } }
        guard let result = responses[operation]?.first else { throw WorkspaceClientError.invalidResponse }
        responses[operation]?.removeFirst()
        return result
    }
}

@MainActor
private final class NativeWikiMemory: WikiPersistence {
    var state: WikiLocalState?
    var folders: [WikiFolderPreference] = []
    func load(owner: WikiOwner) throws -> WikiLocalState? { state?.owner == owner ? state : nil }
    func save(_ state: WikiLocalState) throws { self.state = state }
    func deleteAccount(accountID: String) throws { state = nil; folders = [] }
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] { folders }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws { self.folders = folders }
}
