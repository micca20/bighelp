import CryptoKit
import Foundation
import Testing
@testable import Loopdy

@MainActor
struct WikiNativeTests {
    @Test func successfulMigrationIsReusedAcrossStartupHostProfileAndAuthorityBinds() {
        let memory = WikiConnectionMemory()
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: memory)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "cache-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 82, count: 32))
        for _ in 0..<2 {
            services.bind(owner: nil, credentials: credentials, accountID: nil, currentOwner: { nil })
            #expect(memory.migrations.count == 1)
        }
        for (host, profile) in [("host-a", "default"), ("host-a", "default"), ("host-b", "default"), ("host-b", "other")] {
            let owner = credentials.wikiOwner(hostID: host, profileID: profile)
            services.bind(owner: owner, credentials: credentials, accountID: nil, currentOwner: { owner })
            #expect(memory.migrations.count == 1)
            #expect(services.wiki.owner == owner)
        }
        let rotated = LoopdyLinkRuntimeCredentials(deviceID: credentials.deviceID, authorizationEpoch: 3,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: credentials.accountKey)
        let owner = rotated.wikiOwner(hostID: "host-b", profileID: "other")
        services.bind(owner: owner, credentials: rotated, accountID: nil, currentOwner: { owner })
        #expect(memory.migrations.count == 1)
        #expect(services.wiki.owner == owner)
        #expect(services.lifecycleFailure == nil)
    }

    @Test(arguments: ["account", "device"])
    func changedAuthenticatedNamespaceRunsMigrationAgain(change: String) {
        let memory = WikiConnectionMemory()
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: memory)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "cache-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 82, count: 32))
        services.bind(owner: nil, credentials: credentials, accountID: nil, currentOwner: { nil })
        let changed = LoopdyLinkRuntimeCredentials(deviceID: change == "device" ? "other-device" : credentials.deviceID,
            authorizationEpoch: 2, signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: change == "account" ? 83 : 82, count: 32))
        for _ in 0..<2 {
            services.bind(owner: nil, credentials: changed, accountID: nil, currentOwner: { nil })
            #expect(memory.migrations.count == 2)
            #expect(memory.migrations.last?.accountID == changed.wikiAccountID)
            #expect(memory.migrations.last?.deviceID == changed.deviceID)
        }
    }

    @Test func failedMigrationRetriesOnBindAndCachesOnlySuccess() {
        let memory = WikiConnectionMemory()
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: memory)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "cache-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 82, count: 32))
        memory.failMigration = true
        for expectedAttempts in 1...2 {
            services.bind(owner: nil, credentials: credentials, accountID: nil, currentOwner: { nil })
            #expect(memory.migrations.count == expectedAttempts)
            #expect(services.lifecycleFailure != nil)
        }
        memory.failMigration = false
        for _ in 0..<2 {
            services.bind(owner: nil, credentials: credentials, accountID: nil, currentOwner: { nil })
            #expect(memory.migrations.count == 3)
            #expect(services.lifecycleFailure == nil)
        }
    }

    @Test(arguments: [false, true])
    func historicalJournalsBeyondScopeQuotaCanBeErased(deletingAccount: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-many-scopes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let owners = try seedHistoricalWikiScopes(persistence, accountID: "many-scopes", deviceID: "device")
        let unrelated = WikiConnectionProbe().owner
        try persistence.save(WikiLocalState(owner: unrelated, connections: [], saves: []))
        try persistence.saveFolders([WikiFolderPreference(id: UUID(), name: "Private", folderPath: "/private")], owner: unrelated)
        // A deliberate removal must win over a retained historical connection.
        try persistence.saveFolders([], owner: owners[0])
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        services.bind(owner: owners[0], accountID: nil, currentOwner: { owners[0] })
        let base = WikiErasureProbe()
        let eraser = ReferenceAccountDataEraser(base: base, references: services)
        if deletingAccount { try eraser.erase() } else { try eraser.eraseForSignOut() }
        #expect(base.calls == 1)
        for (index, owner) in owners.enumerated() {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).map(\.folderPath)
                == (deletingAccount || index == 0 ? [] : ["/notes"]))
        }
        #expect(try persistence.load(owner: unrelated) != nil)
        #expect(try persistence.loadFolders(owner: unrelated).map(\.folderPath) == ["/private"])
    }

    @Test func authenticatedMigrationBeyondScopeQuotaRetriesAfterVaultErasure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-many-migrations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("Loopdy")
        let availability = WikiSelectionAvailability()
        let persistence = WikiLocalPersistence(directory: live.appendingPathComponent("Wiki"),
            preferencesDirectory: directory.appendingPathComponent("Preferences"), availability: availability)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "many-migrations", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 81, count: 32))
        let legacyOwners = try seedHistoricalWikiScopes(persistence, accountID: credentials.deviceID, deviceID: credentials.deviceID)
        let owners = legacyOwners.map { credentials.wikiOwner(hostID: $0.hostID, profileID: $0.profileID) }
        try persistence.saveFolders([], owner: owners[0])
        // An arbitrary foreign namespace must not even be decoded by migration.
        let foreign = live.appendingPathComponent("Wiki").appendingPathComponent(WikiLimits.digest(Data("foreign".utf8)))
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("corrupt foreign journal".utf8).write(to: foreign.appendingPathComponent("journal.json"))
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(credentials)
        let store = LoopdyLinkAccountStore(api: WikiCleanupAccountAPI(), passkeys: WikiCleanupPasskeys(), vault: vault,
            localDataEraser: ReferenceAccountDataEraser(
                base: LoopdyLocalAccountDataEraser(dataDirectory: live, defaults: defaults), references: services),
            deviceName: "Fixture", deviceKind: .phone)
        store.restore()
        availability.isProtectedDataAvailable = false
        services.bind(owner: owners[0], credentials: credentials, accountID: nil, currentOwner: { owners[0] })
        store.onLocalAccountCleared = {
            services.invalidate()
            services.bind(owner: nil, accountID: nil, currentOwner: { nil })
        }
        await store.signOut()
        #expect(try vault.load() == nil)
        #expect(store.credentials == nil)
        #expect(store.needsLocalCleanup)
        availability.isProtectedDataAvailable = true
        await store.signOut()
        #expect(!store.needsLocalCleanup)
        #expect(store.state == .signedOut)
        #expect(services.lifecycleFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: live.path))
        for (index, owner) in owners.enumerated() {
            #expect(try persistence.load(owner: legacyOwners[index]) == nil)
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).map(\.folderPath) == (index == 0 ? [] : ["/notes"]))
        }
        services.bind(owner: owners[0], credentials: credentials, accountID: nil, currentOwner: { owners[0] })
        try services.eraseAccountData()
        for owner in owners { #expect(try persistence.loadFolders(owner: owner).isEmpty) }
    }

    @Test(arguments: [false, true])
    func signOutRetainsNewestEpochBeyondJournalQuota(readBeforeCleanup: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-many-epochs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let root = WikiConnectionProbe().root
        var owners: [WikiOwner] = []
        for index in 0..<65 {
            let owner = WikiOwner(accountID: "many-epochs", hostID: "host", profileID: "default",
                deviceID: "device", authorizationEpoch: String(index + 1))
            owners.append(owner)
            try persistence.save(WikiLocalState(owner: owner,
                connections: [WikiConnection(owner: owner, name: "Epoch-\(index)", root: root)], saves: []))
            // Explicit modification dates avoid filesystem timestamp ties.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                ofItemAtPath: historicalWikiFile(directory: directory, owner: owner).path)
        }
        if readBeforeCleanup {
            #expect(try persistence.loadFolders(owner: owners[0]).map(\.name) == ["Epoch-64"])
        }
        try persistence.signOut(accountID: "many-epochs")
        for owner in owners {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).map(\.name) == ["Epoch-64"])
        }
    }

    @Test(arguments: ["corrupt", "oversized", "invalidState"])
    func historicalCleanupFailsWithoutErasingAnyJournalWhenDataIsInvalid(damage: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-corrupt-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let owners = try seedHistoricalWikiScopes(persistence, accountID: "damaged-history", deviceID: "device")
        // Existing tombstones must not bypass journal validation during cleanup.
        for owner in owners { try persistence.saveFolders([], owner: owner) }
        let damaged = try historicalWikiFile(directory: directory, owner: owners[0])
        let original = try Data(contentsOf: damaged)
        switch damage {
        case "oversized":
            let handle = try FileHandle(forWritingTo: damaged)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 40 * 1_024 * 1_024 + 1)
        case "invalidState":
            var state = try JSONDecoder().decode(WikiLocalState.self, from: original)
            state.connections.append(state.connections[0])
            try JSONEncoder().encode(state).write(to: damaged)
        default: try Data("not JSON".utf8).write(to: damaged)
        }
        #expect(throws: (any Error).self) { try persistence.signOut(accountID: "damaged-history") }
        for owner in owners {
            #expect(FileManager.default.fileExists(atPath: try historicalWikiFile(directory: directory, owner: owner).path))
        }
        try original.write(to: damaged)
        try persistence.signOut(accountID: "damaged-history")
        for owner in owners {
            #expect(try persistence.load(owner: owner) == nil)
            #expect(try persistence.loadFolders(owner: owner).isEmpty)
        }
    }

    private func historicalWikiFile(directory: URL, owner: WikiOwner) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try directory.appendingPathComponent(WikiLimits.digest(Data(owner.accountID.utf8)))
            .appendingPathComponent(WikiLimits.digest(encoder.encode(owner)) + ".json")
    }

    private func seedHistoricalWikiScopes(_ persistence: WikiLocalPersistence, accountID: String,
                                         deviceID: String) throws -> [WikiOwner] {
        // The existing writer accepts a 65th snapshot when it sees 64 siblings.
        // These are real persisted private operation journals, not a persistence mock.
        try (0..<65).map { index in
            let owner = WikiOwner(accountID: accountID, hostID: "host-\(index)", profileID: "default",
                deviceID: deviceID, authorizationEpoch: "1")
            let root = WikiConnectionProbe().root
            let connection = WikiConnection(owner: owner, name: "Notes-\(index)", root: root)
            let source = "private draft \(index)"
            let bytes = Data(source.utf8)
            let document = try WikiDocument(connection: connection, path: "note.md",
                bytes: WikiBytes(data: bytes, revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(bytes))"))
            let save = WikiPendingSave(operationId: "private-operation-\(index)", document: document,
                workingSource: source, sha256: WikiLimits.digest(bytes), phase: .prepared, nextOffset: 0)
            try persistence.save(WikiLocalState(owner: owner, connections: [connection], saves: [save]))
            return owner
        }
    }

    @Test func realCredentialWikiNamespaceIgnoresDeviceEpochAndSigningKey() {
        let key = Data(repeating: 17, count: 32)
        let first = LoopdyLinkRuntimeCredentials(deviceID: "first", authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: key)
        let second = LoopdyLinkRuntimeCredentials(deviceID: "second", authorizationEpoch: 9,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: key)
        let other = LoopdyLinkRuntimeCredentials(deviceID: "first", authorizationEpoch: 1,
            signingPrivateKey: first.signingPrivateKey, accountKey: Data(repeating: 18, count: 32))
        #expect(first.wikiAccountID == second.wikiAccountID)
        #expect(first.wikiAccountID != other.wikiAccountID)
        #expect(first.wikiAccountID != first.deviceID)
        #expect(first.wikiOwner(hostID: "host", profileID: "default").accountID == second.wikiAccountID)
        #expect(second.wikiOwner(hostID: "host", profileID: "default").deviceID == "second")
    }

    @Test func realBindMigratesOnlyAuthenticatedFoldersAndSurvivesRealBaseEraser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-real-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("Loopdy")
        let persistence = WikiLocalPersistence(directory: live.appendingPathComponent("Wiki"),
            preferencesDirectory: directory.appendingPathComponent("LoopdyWikiPreferences"), availability: WikiSelectionAvailable())
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "migration-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 71, count: 32))
        let owner = credentials.wikiOwner(hostID: "host", profileID: "default")
        let legacy = WikiOwner(accountID: credentials.deviceID, hostID: "host", profileID: "default",
            deviceID: credentials.deviceID, authorizationEpoch: "1")
        let root = WikiRoot(wikiId: "old-grant", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        try persistence.save(WikiLocalState(owner: legacy,
            connections: [WikiConnection(owner: legacy, name: "Retained", root: root)], saves: []))
        let mismatched = WikiOwner(accountID: credentials.deviceID, hostID: "unproven", profileID: "default",
            deviceID: "not-current-device", authorizationEpoch: "1")
        try persistence.save(WikiLocalState(owner: mismatched,
            connections: [WikiConnection(owner: mismatched, name: "Reject", root: root)], saves: []))
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        // Matches app startup: credentials are available before any host owner.
        services.bind(owner: nil, credentials: credentials, accountID: nil, currentOwner: { nil })
        #expect(services.lifecycleFailure == nil)
        #expect(try persistence.loadFolders(owner: owner).map(\.folderPath) == ["/notes"])
        #expect(try persistence.load(owner: owner) == nil)
        #expect(try persistence.loadFolders(owner: credentials.wikiOwner(hostID: "unproven", profileID: "default")).isEmpty)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let eraser = ReferenceAccountDataEraser(base: LoopdyLocalAccountDataEraser(dataDirectory: live, defaults: defaults), references: services)
        try eraser.eraseForSignOut()
        #expect(!FileManager.default.fileExists(atPath: live.path))
        let replacement = LoopdyLinkRuntimeCredentials(deviceID: "replacement", authorizationEpoch: 5,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: credentials.accountKey)
        let restored = replacement.wikiOwner(hostID: "host", profileID: "default")
        #expect(try persistence.loadFolders(owner: restored).map(\.name) == ["Retained"])
        services.bind(owner: nil, credentials: replacement, accountID: nil, currentOwner: { nil })
        try eraser.erase()
        #expect(try persistence.loadFolders(owner: restored).isEmpty)
    }

    @Test func signOutRetriesAuthenticatedMigrationAfterCredentialsAreCleared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-migration-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = WikiSelectionAvailability()
        let persistence = WikiLocalPersistence(directory: directory.appendingPathComponent("Wiki"),
            preferencesDirectory: directory.appendingPathComponent("Preferences"), availability: availability)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "retry-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 72, count: 32))
        let owner = credentials.wikiOwner(hostID: "host", profileID: "default")
        let legacy = WikiOwner(accountID: credentials.deviceID, hostID: "host", profileID: "default",
            deviceID: credentials.deviceID, authorizationEpoch: "1")
        let root = WikiRoot(wikiId: "old", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        try persistence.save(WikiLocalState(owner: legacy,
            connections: [WikiConnection(owner: legacy, name: "Retained", root: root)], saves: []))
        let unrelated = WikiOwner(accountID: "unrelated-device", hostID: "host", profileID: "default",
            deviceID: "unrelated-device", authorizationEpoch: "1")
        try persistence.save(WikiLocalState(owner: unrelated,
            connections: [WikiConnection(owner: unrelated, name: "Private", root: root)], saves: []))
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        let base = WikiErasureProbe()
        let vault = LoopdyLinkMemoryCredentialVault()
        try vault.save(credentials)
        let store = LoopdyLinkAccountStore(api: WikiCleanupAccountAPI(), passkeys: WikiCleanupPasskeys(), vault: vault,
            localDataEraser: ReferenceAccountDataEraser(base: base, references: services),
            deviceName: "Fixture", deviceKind: .phone)
        store.restore()
        availability.isProtectedDataAvailable = false
        services.bind(owner: owner, credentials: credentials, accountID: nil, currentOwner: { owner })
        #expect(services.lifecycleFailure != nil)
        store.onLocalAccountCleared = {
            services.invalidate()
            services.bind(owner: nil, accountID: nil, currentOwner: { nil })
        }
        await store.signOut()
        #expect(store.credentials == nil)
        #expect(try vault.load() == nil)
        #expect(store.needsLocalCleanup)
        #expect(base.calls == 0)
        await store.signOut()
        #expect(store.needsLocalCleanup)
        #expect(base.calls == 0)
        availability.isProtectedDataAvailable = true
        #expect(try persistence.load(owner: legacy) != nil)
        await store.signOut()
        #expect(!store.needsLocalCleanup)
        #expect(store.state == .signedOut)
        #expect(services.lifecycleFailure == nil)
        #expect(base.calls == 1)
        #expect(try persistence.load(owner: legacy) == nil)
        #expect(try persistence.loadFolders(owner: owner).map(\.name) == ["Retained"])
        #expect(try persistence.load(owner: unrelated) != nil)
        let otherCredentials = LoopdyLinkRuntimeCredentials(deviceID: "other-device", authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 73, count: 32))
        let otherOwner = otherCredentials.wikiOwner(hostID: "host", profileID: "default")
        services.bind(owner: otherOwner, credentials: otherCredentials, accountID: nil, currentOwner: { otherOwner })
        #expect(try persistence.loadFolders(owner: otherOwner).isEmpty)
        try services.eraseAccountData()
        #expect(try persistence.loadFolders(owner: owner).map(\.name) == ["Retained"])
        #expect(try persistence.load(owner: unrelated) != nil)
    }

    @Test(arguments: ["discover", "rename", "removeUnrelated", "rebind"])
    func openingWikiRetriesMigrationBeforeCreatingPreferencesWithoutRebind(firstOperation: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-open-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = WikiSelectionAvailability()
        let persistence = WikiLocalPersistence(directory: directory.appendingPathComponent("Wiki"),
            preferencesDirectory: directory.appendingPathComponent("Preferences"), availability: availability)
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "open-retry-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 75, count: 32))
        let owner = credentials.wikiOwner(hostID: "host", profileID: "default")
        let legacy = WikiOwner(accountID: credentials.deviceID, hostID: "host", profileID: "default",
            deviceID: credentials.deviceID, authorizationEpoch: "1")
        let connection = WikiConnection(owner: legacy, name: "Retained", root: WikiConnectionProbe().root)
        try persistence.save(WikiLocalState(owner: legacy, connections: [connection], saves: []))
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        availability.isProtectedDataAvailable = false
        services.bind(owner: owner, credentials: credentials, accountID: nil, currentOwner: { owner })
        #expect(services.lifecycleFailure != nil)
        #expect(throws: (any Error).self) { try services.wiki.restoreLocalState() }
        availability.isProtectedDataAvailable = true
        switch firstOperation {
        case "rename": try services.wiki.renameFolder(id: connection.id, name: "Retained")
        case "removeUnrelated": try services.wiki.removeFolder(id: UUID())
        case "rebind": services.bind(owner: owner, credentials: credentials, accountID: nil, currentOwner: { owner })
        default: break
        }
        // The discover case opens Wiki without another bind. The old host
        // rejects discovery, but local selections must already be safe.
        do { try await services.wiki.discoverRoots(); Issue.record("Expected old host failure") } catch { }
        #expect(services.wiki.savedFolders.map(\.name) == ["Retained"])
        #expect(services.lifecycleFailure == nil)
        try services.wiki.restoreLocalState()
        #expect(services.wiki.savedFolders.map(\.id) == [connection.id])
        let base = WikiErasureProbe()
        let eraser = ReferenceAccountDataEraser(base: base, references: services)
        try eraser.eraseForSignOut()
        #expect(base.calls == 1)
        #expect(try persistence.load(owner: legacy) == nil)
        #expect(try persistence.loadFolders(owner: owner).map(\.name) == ["Retained"])
    }

    @Test func preferencePreparationGuardsDirectReadsAndEveryMutationAfterRestore() async throws {
        let client = WikiConnectionProbe()
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: nil, client: nil, persistence: memory)
        var blocked = false
        store.setContext(owner: client.owner, client: client, preparePreferences: {
            if blocked { throw WikiError.quota }
        })
        let connection = try await store.connect(name: "Retained", folderPath: "/notes")
        let folders = memory.folders
        blocked = true
        #expect(throws: WikiError.quota) { try store.restoreLocalState() }
        #expect(throws: WikiError.quota) { try store.renameFolder(id: connection.id, name: "Lost") }
        #expect(throws: WikiError.quota) { try store.removeFolder(id: connection.id) }
        #expect(throws: WikiError.quota) { try store.disconnect(connection) }
        #expect(throws: WikiError.quota) { try store.connect(name: "Lost", root: client.root) }
        do { _ = try await store.connect(name: "Lost", folderPath: "/notes"); Issue.record("Expected preparation failure") }
        catch { #expect(error as? WikiError == .quota) }
        do { try await store.discoverRoots(); Issue.record("Expected preparation failure") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(client.connectPaths == ["/notes"])
        #expect(memory.folders == folders)
        #expect(store.savedFolders == folders)
        #expect(store.connections == [connection])
        blocked = false
        try store.renameFolder(id: connection.id, name: "Recovered")
        #expect(memory.folders.first?.name == "Recovered")
        try store.removeFolder(id: connection.id)
        #expect(memory.folders.isEmpty)
    }

    @Test(arguments: ["account", "device", "currentOwner"])
    func authenticatedPreferencePreparationRejectsMismatchedOwner(mismatch: String) throws {
        let credentials = LoopdyLinkRuntimeCredentials(deviceID: "proof-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 76, count: 32))
        let authenticatedOwner = credentials.wikiOwner(hostID: "host", profileID: "default")
        let authenticatedDeviceID = try #require(authenticatedOwner.deviceID)
        let authenticatedEpoch = try #require(authenticatedOwner.authorizationEpoch)
        let owner = WikiOwner(accountID: mismatch == "account" ? "other-account" : authenticatedOwner.accountID,
            hostID: authenticatedOwner.hostID, profileID: authenticatedOwner.profileID,
            deviceID: mismatch == "device" ? "other-device" : authenticatedDeviceID,
            authorizationEpoch: authenticatedEpoch)
        let memory = WikiConnectionMemory()
        let services = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: memory)
        services.bind(owner: owner, credentials: credentials, accountID: nil,
            currentOwner: { mismatch == "currentOwner" ? nil : owner })
        #expect(throws: WikiError.ownerChanged) { try services.wiki.restoreLocalState() }
        #expect(throws: WikiError.ownerChanged) { try services.wiki.removeFolder(id: UUID()) }
        #expect(services.wiki.savedFolders.isEmpty)
    }

    @Test func authenticatedMigrationDescriptorRejectsInvalidCredentials() throws {
        let valid = LoopdyLinkRuntimeCredentials(deviceID: "verified-device", authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey(), accountKey: Data(repeating: 74, count: 32))
        let migration = try WikiAuthenticatedMigration(credentials: valid)
        #expect(migration.accountID == valid.wikiAccountID)
        #expect(migration.deviceID == valid.deviceID)
        for invalid in [
            LoopdyLinkRuntimeCredentials(deviceID: valid.deviceID, authorizationEpoch: 2,
                signingPrivateKey: valid.signingPrivateKey, accountKey: Data()),
            LoopdyLinkRuntimeCredentials(deviceID: "", authorizationEpoch: 2,
                signingPrivateKey: valid.signingPrivateKey, accountKey: valid.accountKey)
        ] {
            #expect(throws: WikiError.ownerChanged) { try WikiAuthenticatedMigration(credentials: invalid) }
        }
    }

    @Test func unconfiguredWikiStoreIsInertAndOptional() {
        let store = WikiStore(owner: nil, client: nil)
        #expect(store.connections.isEmpty)
        #expect(!store.isLoading)
    }

    @Test func oldHostOperationNegotiationShowsPluginUpdateInstruction() {
        let failure = WikiError.safe(LoopdyLinkLiveSocketError.hostUpdateRequired)
        #expect(failure == .remote("UNSUPPORTED_OPERATION"))
        #expect(failure.localizedDescription.contains("Update its Loopdy plugin"))
    }

    @Test func preparedWikiConnectPreservesHostUpdateRequiredWithoutFallback() async throws {
        let owner = WikiConnectionProbe().owner
        let messaging = WikiOldHostMessaging()
        let client = WikiLinkClient(owner: owner, workspace: LoopdyLinkWorkspaceClient(messaging: messaging),
                                    currentOwner: { owner })
        do { _ = try await client.connect(folderPath: "/notes"); Issue.record("Old host must reject connect") }
        catch { #expect(WikiError.safe(error) == .remote("UNSUPPORTED_OPERATION")) }
        #expect(messaging.preparedCalls == 1)
        #expect(messaging.unpreparedCalls == 0)
    }

    @Test func folderConnectionRegistersAndInfersName() async throws {
        let client = WikiConnectionProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let connection = try await store.connect(name: "", folderPath: "/notes")
        #expect(client.connectPaths == ["/notes"])
        #expect(connection.name == "Notes")
        #expect(connection.readOnly)
        #expect(connection.root.folderPath == "/notes")
        #expect(store.connections == [connection])
    }

    @Test func authenticatedWritableFolderConnectEnablesEditingByDefault() async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let connection = try await store.connect(name: "", folderPath: "/notes")
        #expect(connection.allowsEditing, "Account-authorized folder Save connects read and write")
    }

    @Test func savedFolderReconnectsWithCurrentAuthorityAfterAccountEpochChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-selection-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: previous.owner, name: "My notes", root: previous.root)
        // Seed the existing on-disk format: migration must keep the selection,
        // not the old authority, across a fresh store and authorization epoch.
        try persistence.save(WikiLocalState(owner: previous.owner, connections: [legacy], saves: []))
        let currentOwner = WikiOwner(accountID: previous.owner.accountID, hostID: previous.owner.hostID,
            profileID: previous.owner.profileID, deviceID: "replacement-device", authorizationEpoch: "2")
        let freshRoot = WikiRoot(wikiId: "fresh-notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "b", count: 32), folderPath: "/notes")
        let current = WikiConnectionProbe(owner: currentOwner, root: freshRoot)
        let store = WikiStore(owner: currentOwner, client: current,
            persistence: WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable()))
        try store.restoreLocalState()
        #expect(store.connections.isEmpty, "Retained selection is not an active authority handle")
        #expect(store.pendingSaves.isEmpty)
        try await store.discoverRoots()
        #expect(current.connectPaths == ["/notes"], "Reconnect retained folder using current authenticated client")
        let restored = try #require(store.connections.first)
        #expect(restored.owner == currentOwner)
        #expect(restored.root == freshRoot)
        #expect(restored.name == "My notes")
        #expect(restored.allowsEditing)
        store.setContext(owner: nil, client: nil)
        #expect(store.connections.isEmpty)
        #expect(store.authorizedRoots.isEmpty)
        #expect(store.document == nil)
    }

    @Test(arguments: ["generated", "mirror", "export", "unknown"])
    func nonFileSourcesRemainReadOnly(sourceKind: String) async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: sourceKind,
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        #expect(try await !store.connect(name: "", folderPath: "/notes").allowsEditing)
    }

    @Test func reconnectReplacesOldGrantAndKeepsExplicitReadOnlyChoice() async throws {
        let root = WikiRoot(wikiId: "notes", name: "Notes", writable: true, sourceKind: "files",
            generation: String(repeating: "b", count: 32), folderPath: "/notes")
        let client = WikiConnectionProbe(root: root)
        client.listedRoot = WikiRoot(wikiId: "notes", name: "Notes", writable: false, sourceKind: "files",
            generation: String(repeating: "a", count: 32), folderPath: "/notes")
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        _ = try await store.connect(name: "Chosen", folderPath: "/notes", readOnly: true)
        store.setContext(owner: client.owner, client: client)
        try await store.discoverRoots()
        #expect(store.authorizedRoots == [root])
        #expect(store.connections.first?.readOnly == true)
        #expect(store.connections.first?.root.generation == root.generation)
    }

    @Test func preferenceWriteFailureDoesNotPublishOrForgetSelections() async throws {
        let client = WikiConnectionProbe()
        let memory = WikiConnectionMemory()
        let store = WikiStore(owner: client.owner, client: client, persistence: memory)
        memory.failFolderSave = true
        do { _ = try await store.connect(name: "Notes", folderPath: "/notes"); Issue.record("Expected failed persistence") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.connections.isEmpty)
        #expect(store.savedFolders.isEmpty)
        memory.failFolderSave = false
        let connection = try await store.connect(name: "Notes", folderPath: "/notes")
        memory.failFolderSave = true
        do { try store.removeFolder(id: connection.id); Issue.record("Expected failed removal") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.connections == [connection])
        #expect(store.savedFolders.count == 1)
        do { try store.renameFolder(id: connection.id, name: "Lost"); Issue.record("Expected failed rename") }
        catch { #expect(error as? WikiError == .quota) }
        #expect(store.savedFolders.first?.name == "Notes")
    }

    @Test func folderPreferencesAreIsolatedAndRemovalDoesNotResurrectLegacyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: client.owner, name: "Old name", root: client.root)
        try persistence.save(WikiLocalState(owner: client.owner, connections: [legacy], saves: []))
        let store = WikiStore(owner: client.owner, client: client, persistence: persistence)
        try await store.discoverRoots()
        try store.renameFolder(id: legacy.id, name: "Renamed")
        #expect(try persistence.loadFolders(owner: client.owner).first?.name == "Renamed")
        for other in [
            WikiOwner(accountID: "other", hostID: client.owner.hostID, profileID: client.owner.profileID, deviceID: "d", authorizationEpoch: "1"),
            WikiOwner(accountID: client.owner.accountID, hostID: "other", profileID: client.owner.profileID, deviceID: "d", authorizationEpoch: "1"),
            WikiOwner(accountID: client.owner.accountID, hostID: client.owner.hostID, profileID: "other", deviceID: "d", authorizationEpoch: "1")
        ] {
            let otherClient = WikiConnectionProbe(owner: other)
            let otherStore = WikiStore(owner: other, client: otherClient, persistence: persistence)
            try await otherStore.discoverRoots()
            #expect(otherStore.savedFolders.isEmpty)
            #expect(otherClient.connectPaths.isEmpty)
        }
        try store.removeFolder(id: legacy.id)
        let reopened = WikiStore(owner: client.owner, client: client, persistence: persistence)
        try await reopened.discoverRoots()
        #expect(reopened.savedFolders.isEmpty)
        #expect(reopened.connections.isEmpty)
        #expect(client.connectPaths == ["/notes"])
    }

    @Test func failedReconnectRetainsRetryablePreferenceAndRemovalFencesLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let folder = WikiFolderPreference(id: UUID(), name: "Notes", folderPath: "/notes")
        try persistence.saveFolders([folder], owner: client.owner)
        let store = WikiStore(owner: client.owner, client: client, persistence: persistence)
        client.failConnect = true
        do { try await store.discoverRoots(); Issue.record("Expected unavailable folder") } catch { }
        #expect(store.savedFolders == [folder])
        #expect(store.connections.isEmpty)
        client.failConnect = false
        try await store.discoverRoots()
        #expect(store.connections.count == 1)
        store.setContext(owner: client.owner, client: client)
        client.suspend = true
        let reconnect = Task { try await store.discoverRoots() }
        for _ in 0..<100 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        try store.removeFolder(id: folder.id)
        pending.resume(returning: client.root)
        try await reconnect.value
        #expect(store.connections.isEmpty)
        #expect(try persistence.loadFolders(owner: client.owner).isEmpty)
    }

    @Test func realReferenceEraserPreservesOnlyFolderChoicesOnSignOutThenDeletesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-eraser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = WikiConnectionProbe()
        let persistence = WikiLocalPersistence(directory: directory, availability: WikiSelectionAvailable())
        let legacy = WikiConnection(owner: client.owner, name: "Retained", root: client.root)
        let source = "private draft"
        let document = try WikiDocument(connection: legacy, path: "note.md",
            bytes: WikiBytes(data: Data(source.utf8), revision: "wiki-v1:\(client.root.generation):\(WikiLimits.digest(Data(source.utf8)))"))
        let save = WikiPendingSave(operationId: "private-operation", document: document, workingSource: source,
            sha256: WikiLimits.digest(Data(source.utf8)), phase: .prepared, nextOffset: 0)
        try persistence.save(WikiLocalState(owner: client.owner, connections: [legacy], saves: [save]))
        let references = OptionalReferenceServices(workspace: LoopdyLinkWorkspaceClient(messaging: WikiOldHostMessaging()),
            configuration: nil, wikiPersistence: persistence)
        references.bind(owner: client.owner, accountID: client.owner.accountID, currentOwner: { client.owner })
        let base = WikiErasureProbe()
        let eraser = ReferenceAccountDataEraser(base: base, references: references)
        try eraser.eraseForSignOut()
        #expect(base.calls == 1)
        #expect(references.wiki.owner == nil)
        #expect(references.wiki.connections.isEmpty)
        #expect(references.wiki.pendingSaves.isEmpty)
        #expect(references.wikiClient == nil)
        #expect(try persistence.load(owner: client.owner) == nil)
        #expect(try persistence.loadFolders(owner: client.owner).map(\.name) == ["Retained"])
        references.bind(owner: client.owner, accountID: client.owner.accountID, currentOwner: { client.owner })
        try eraser.erase()
        #expect(base.calls == 2)
        #expect(try persistence.loadFolders(owner: client.owner).isEmpty)
    }

    @Test func ownerReplacementRejectsLateFolderRegistration() async throws {
        let client = WikiConnectionProbe()
        client.suspend = true
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        let operation = Task { try await store.connect(name: "", folderPath: "/notes") }
        for _ in 0..<100 where client.pending == nil { await Task.yield() }
        let pending = try #require(client.pending)
        store.setContext(owner: nil, client: nil)
        pending.resume(returning: client.root)
        do { _ = try await operation.value; Issue.record("Late connection must fail") }
        catch { }
        #expect(store.connections.isEmpty)
        #expect(store.authorizedRoots.isEmpty)
    }

    @Test func wikiReferenceKeepsSourcePathAndCleanTitle() throws {
        let client = WikiConnectionProbe()
        let connection = WikiConnection(owner: client.owner, name: "Notes", root: client.root)
        let bytes = Data("# Plan\nNested source\n".utf8)
        let document = try WikiDocument(connection: connection, path: "nested/plan.md",
            bytes: WikiBytes(data: bytes, revision: "wiki-v1:\(client.root.generation):\(WikiLimits.digest(bytes))"))
        let snapshot = try #require(ReferenceWikiAdapter.options(for: document).first).snapshot
        #expect(snapshot.title == "plan.md")
        #expect(snapshot.selectedContent.contains("Wiki source path (JSON):"))
        #expect(snapshot.selectedContent.contains("nested"))
        #expect(snapshot.selectedContent.hasSuffix("# Plan\nNested source\n"))
    }

    @Test func emptyWikiReferenceBrowseIncludesNestedFilesAndRevalidatesLocationOnly() async throws {
        let client = WikiConnectionProbe()
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        _ = try await store.connect(name: "", folderPath: "/notes")
        let owner = ReferenceHubOwner(accountID: client.owner.accountID, hostID: client.owner.hostID,
            deviceID: try #require(client.owner.deviceID), authorizationEpoch: "1", sessionID: "fixture-session",
            agentID: client.owner.profileID, recipientIDs: ["default"])
        let adapter = ReferenceWikiAdapter(store: store, client: client, owner: client.owner,
            connections: store.connections, ownerIsCurrent: { $0 == owner })
        let page = try await adapter.provider.search(owner, .wiki, "")
        #expect(page.results.map(\.title) == ["plan.md", "paper.pdf"])
        let result = try #require(page.results.first(where: { $0.title == "paper.pdf" }))
        let preview = try await adapter.provider.resolve(owner, result)
        #expect(preview.sourceKindLabel.contains("contents not included"))
        let snapshot = try #require(preview.options.first).snapshot
        let metadata = try JSONDecoder().decode([String: LoopdyJSONValue].self, from: Data(snapshot.selectedContent.utf8))
        #expect(metadata["sourcePath"]?.string == "/notes/nested/paper.pdf")
        #expect(client.readCalls == 0)
        client.fileSize = 2_048
        let changed = try await adapter.provider.revalidate(owner, snapshot)
        #expect(!changed.hasSameContent(as: snapshot))
        #expect(client.readCalls == 0)
    }

    @Test func hostFilenameSearchFindsFilesOutsideInitialCatalogWithoutBodyMatches() async throws {
        let client = WikiConnectionProbe()
        let revision = "wiki-v1:\(client.root.generation):\(WikiLimits.digest(Data("host-name-only".utf8)))"
        client.hostNameMatches = [
            WikiSearchMatch(path: "beyond-initial-catalog/name-only.md", title: "name-only.md", snippet: nil, revision: revision),
            WikiSearchMatch(path: "beyond-initial-catalog/name-only.pdf", title: "name-only.pdf", snippet: nil, revision: revision)
        ]
        let store = WikiStore(owner: client.owner, client: client, persistence: WikiConnectionMemory())
        _ = try await store.connect(name: "", folderPath: "/notes")
        let owner = ReferenceHubOwner(accountID: client.owner.accountID, hostID: client.owner.hostID,
            deviceID: try #require(client.owner.deviceID), authorizationEpoch: "1", sessionID: "fixture-session",
            agentID: client.owner.profileID, recipientIDs: ["default"])
        let adapter = ReferenceWikiAdapter(store: store, client: client, owner: client.owner,
            connections: store.connections, ownerIsCurrent: { $0 == owner })
        // The initial listing contains only plan.md/paper.pdf; content search
        // returns no matches. Both results must come from host filename search.
        let page = try await adapter.provider.search(owner, .wiki, "name-only")
        #expect(page.results.map(\.title) == ["name-only.md", "name-only.pdf"])
        #expect(client.searchModes == [.name, .content])
        #expect(client.readCalls == 0)
    }

    @Test func legacyRootDecodesAndMatchesSameGrantWithNewPathMetadata() throws {
        let root = WikiConnectionProbe().root
        var legacy = root
        legacy.folderPath = nil
        let decoded = try JSONDecoder().decode(WikiRoot.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.folderPath == nil)
        #expect(decoded.matchesGrant(root))
        var different = root
        different.folderPath = "/other"
        #expect(!root.matchesGrant(different))
        #expect(LoopdyLinkWorkspaceOperation.wikiConnect.requiresHostCapability)
        #expect(LoopdyLinkWorkspaceOperation.wikiConnect.requiredCapability == "wiki.v1")
    }
}

private final class WikiSelectionAvailability: LoopdyProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isProtectedDataAvailable = true
}

@MainActor private final class WikiCleanupAccountAPI: LoopdyLinkAccountAPI {
    func passkeyOptions(registration: Bool) async throws -> LoopdyLinkPasskeyOptions { throw WikiError.unavailable }
    func verifyPasskey(registration: Bool, flowID: String, response: [String: Any]) async throws -> LoopdyLinkAccountSession { throw WikiError.unavailable }
    func storeAccountKeyEnvelope(_ envelope: String, accessToken: String) async throws { throw WikiError.unavailable }
    func loadAccountKeyEnvelope(accessToken: String) async throws -> String { throw WikiError.unavailable }
    func saveAccountProfile(displayName: String, avatar: UserProfileAvatar?, expectedRevision: Int,
                            credentials: LoopdyLinkRuntimeCredentials) async throws -> LoopdyLinkAccountProfile { throw WikiError.unavailable }
    func loadAccountProfile(credentials: LoopdyLinkRuntimeCredentials) async throws -> LoopdyLinkAccountProfile? { nil }
    func registerDevice(accessToken: String, credentials: LoopdyLinkRuntimeCredentials, name: String,
                        kind: LoopdyLinkDeviceKind) async throws -> LoopdyLinkDevice { throw WikiError.unavailable }
    func revokeCurrentDevice(credentials: LoopdyLinkRuntimeCredentials) async throws { }
    func deleteAccount(accessToken: String) async throws { throw WikiError.unavailable }
}

@MainActor private final class WikiCleanupPasskeys: LoopdyLinkPasskeyAuthorizing {
    func authorize(registration: Bool, options: [String: Any]) async throws -> LoopdyLinkPasskeyAuthorization {
        throw WikiError.unavailable
    }
}

private final class WikiErasureProbe: LoopdyLocalAccountDataErasing {
    var calls = 0
    func erase() throws { calls += 1 }
}

private struct WikiSelectionAvailable: LoopdyProtectedDataAvailabilityProviding {
    var isProtectedDataAvailable: Bool { true }
}

@MainActor private final class WikiConnectionMemory: WikiPersistence {
    var folders: [WikiFolderPreference] = []
    var failFolderSave = false
    var migrations: [WikiAuthenticatedMigration] = []
    var failMigration = false
    func migrateAuthenticatedLegacyFolders(_ migration: WikiAuthenticatedMigration) throws {
        migrations.append(migration)
        if failMigration { throw WikiError.quota }
    }
    func loadFolders(owner: WikiOwner) throws -> [WikiFolderPreference] { folders }
    func saveFolders(_ folders: [WikiFolderPreference], owner: WikiOwner) throws {
        if failFolderSave { throw WikiError.quota }
        self.folders = folders
    }
    func load(owner: WikiOwner) throws -> WikiLocalState? { nil }
    func save(_ state: WikiLocalState) throws { }
    func deleteAccount(accountID: String) throws { }
}

@MainActor private final class WikiConnectionProbe: WikiClientProtocol {
    let owner: WikiOwner
    let root: WikiRoot
    init(owner: WikiOwner = WikiOwner(accountID: "fixture-account", hostID: "fixture-host", profileID: "default",
                                      deviceID: "fixture-device", authorizationEpoch: "1"),
         root: WikiRoot = WikiRoot(wikiId: "notes", name: "Notes", writable: false, sourceKind: "files",
                                  generation: String(repeating: "a", count: 32), folderPath: "/notes")) {
        self.owner = owner
        self.root = root
    }
    var listedRoot: WikiRoot?
    var connectPaths: [String] = []
    var fileSize = 1_024
    var readCalls = 0
    var hostNameMatches: [WikiSearchMatch] = []
    var searchModes: [WikiSearchMode] = []
    var failConnect = false
    var suspend = false
    var pending: CheckedContinuation<WikiRoot, Never>?
    func connect(folderPath: String) async throws -> WikiRoot {
        connectPaths.append(folderPath)
        if failConnect { throw WikiError.unavailable }
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return root
    }
    func resolve(folderPath: String) async throws -> WikiRoot { throw WikiError.unavailable }
    func roots() async throws -> [WikiRoot] { [listedRoot ?? root] }
    func folderSuggestions(parentPath: String, prefix: String, offset: Int) async throws -> HermesWorkspaceFolderPage { throw WikiError.unavailable }
    func list(root: WikiRoot, path: String, offset: Int, revision: String?) async throws -> WikiDirectory {
        let entries = path.isEmpty
            ? [WikiEntry(name: "nested", path: "nested", kind: "directory", size: nil)]
            : [WikiEntry(name: "plan.md", path: "nested/plan.md", kind: "file", size: 20),
               WikiEntry(name: "paper.pdf", path: "nested/paper.pdf", kind: "file", size: fileSize)]
        return WikiDirectory(wikiId: root.wikiId, path: path, parent: WikiNavigation.parent(of: path),
            revision: "wiki-v1:\(root.generation):\(WikiLimits.digest(Data(String(fileSize).utf8)))",
            offset: offset, limit: 100, total: entries.count, entries: entries, nextOffset: nil)
    }
    func read(root: WikiRoot, path: String) async throws -> WikiBytes { readCalls += 1; throw WikiError.unavailable }
    func search(root: WikiRoot, query: String, mode: WikiSearchMode, offset: Int) async throws -> WikiSearchPage {
        searchModes.append(mode)
        return WikiSearchPage(wikiId: root.wikiId, query: query, mode: mode,
            matches: mode == .name ? hostNameMatches : [], nextOffset: nil, isComplete: true, indexedAt: nil)
    }
    func image(root: WikiRoot, path: String) async throws -> WikiBytes { throw WikiError.unavailable }
    func begin(_ save: WikiPendingSave) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func chunk(operationID: String, offset: Int, data: Data) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func commit(operationID: String) async throws -> WikiSaveResponse { throw WikiError.unavailable }
    func status(operationID: String) async throws -> WikiSaveResponse { throw WikiError.unavailable }
}

@MainActor private final class WikiOldHostMessaging: LoopdyLinkWorkspaceMessaging {
    var preparedCalls = 0
    var unpreparedCalls = 0
    func performWorkspaceRequest(_ request: LoopdyLinkWorkspaceRequest) async throws -> LoopdyLinkWorkspaceResult {
        unpreparedCalls += 1
        throw WikiError.unavailable
    }
    func performPreparedWorkspaceRequest(_ request: LoopdyLinkWorkspaceRequest) async throws -> LoopdyLinkWorkspaceResult {
        preparedCalls += 1
        throw LoopdyLinkLiveSocketError.hostUpdateRequired
    }
}
