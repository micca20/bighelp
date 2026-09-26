import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SkillDocumentMutationTests {
    enum Mutation: CaseIterable {
        case update, create, importDocument
        func run(_ store: SkillsAndToolsStore) async -> Bool {
            switch self {
            case .update:
                return await store.saveSkill(content: "Updated exact bytes\n", agentID: "default")
            case .create:
                return await store.createSkill(name: "new-skill", description: "Say \"hello\"\non\\path",
                                               instructions: "Exact instructions\n", category: "", agentID: "default") != nil
            case .importDocument:
                return await store.importSkill(data: Data("Imported exact bytes\n".utf8), kind: "skillMd", agentID: "default") != nil
            }
        }
    }

    @Test(arguments: Mutation.allCases, [false, true])
    func returnedIdentityMustBelongToItsRequest(mutation: Mutation, wrongAgent: Bool) async {
        let (store, client) = await preparedStore()
        if wrongAgent { client.returnedAgent = "other" } else { client.returnedSkill = "other-skill" }
        let accepted = await mutation.run(store)
        #expect(accepted == (mutation == .importDocument && !wrongAgent))
        #expect(client.mutations == 1)
        #expect(!store.isSaving)
        if accepted {
            #expect(store.document?.skillID == "other-skill")
        } else {
            #expect(store.document?.skillID == "weather")
        }
    }

    @Test(arguments: Mutation.allCases, [false, true])
    func closingOrResettingDuringMutationCannotPublishLateContent(mutation: Mutation, resetAccount: Bool) async throws {
        let (store, client) = await preparedStore()
        let gate = AsyncOperationTestGate()
        client.beforeMutation = { try await gate.wait() }
        let task = Task { await mutation.run(store) }
        defer { gate.finish(); task.cancel(); client.beforeMutation = nil }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        #expect(store.isSaving)
        if resetAccount { store.resetForAccountBoundary() } else { store.clearDocument() }
        gate.finish()
        #expect(!(await task.value))
        #expect(store.document == nil && !store.isSaving)
        #expect(store.statusMessage == nil)
        #expect(client.mutations == 1)
    }

    @Test(arguments: Mutation.allCases)
    func acceptedMutationReleasesBusyBeforeCatalogReadback(mutation: Mutation) async throws {
        let (store, client) = await preparedStore()
        let gate = AsyncOperationTestGate()
        client.beforeMutation = {
            client.beforeLoad = {
                #expect(!store.isSaving)
                try await gate.wait()
            }
        }
        let task = Task { await mutation.run(store) }
        defer { gate.finish(); task.cancel(); client.beforeMutation = nil; client.beforeLoad = nil }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        #expect(store.document != nil && store.statusMessage != nil)
        store.clearDocument()
        gate.finish()
        #expect(await task.value)
        #expect(store.document == nil && !store.isSaving)
        #expect(client.mutations == 1)
    }

    @Test func createKeepsEscapingAndImportKeepsExactBytes() async throws {
        let (store, client) = await preparedStore()
        #expect(await Mutation.create.run(store))
        let created = try #require(store.document)
        #expect(created.content == "---\nname: new-skill\ndescription: \"Say \\\"hello\\\" on\\\\path\"\n---\n\nExact instructions\n")
        #expect(client.createdCategory == nil)
        #expect(await Mutation.importDocument.run(store))
        #expect(store.document?.content == "Imported exact bytes\n")
        #expect(client.importedData == Data("Imported exact bytes\n".utf8))
        #expect(client.importedKind == "skillMd" && client.importedCategory == nil)
    }

    private func preparedStore() async -> (SkillsAndToolsStore, ControlledSkillDocumentClient) {
        let client = ControlledSkillDocumentClient()
        let store = SkillsAndToolsStore(client: client)
        await store.load(agentID: "default")
        _ = await store.loadSkill(id: "weather", agentID: "default")
        return (store, client)
    }
}

@MainActor
private final class ControlledSkillDocumentClient: HermesSkillsAndToolsCatalogClient {
    let backing = FixtureSkillsAndToolsClient()
    var beforeMutation: (() async throws -> Void)?
    var beforeLoad: (() async throws -> Void)?
    var returnedAgent: String?
    var returnedSkill: String?
    var mutations = 0
    var createdCategory: String?
    var importedData: Data?
    var importedKind: String?
    var importedCategory: String?

    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        try await beforeLoad?()
        return try await backing.load(agentID: agentID)
    }
    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        try await backing.skill(id: id, agentID: agentID)
    }
    private func mutate(_ operation: () async throws -> HermesSkillDocument) async throws -> HermesSkillDocument {
        mutations += 1
        try await beforeMutation?()
        let value = try await operation()
        return .init(agentID: returnedAgent ?? value.agentID, skillID: returnedSkill ?? value.skillID,
                     content: value.content, sha256: value.sha256)
    }
    func updateSkill(id: String, content: String, expectedSHA256: String, agentID: String) async throws -> HermesSkillDocument {
        try await mutate { try await backing.updateSkill(id: id, content: content, expectedSHA256: expectedSHA256, agentID: agentID) }
    }
    func createSkill(name: String, content: String, category: String?, agentID: String) async throws -> HermesSkillDocument {
        createdCategory = category
        return try await mutate { try await backing.createSkill(name: name, content: content, category: category, agentID: agentID) }
    }
    func importSkill(data: Data, kind: String, category: String?, agentID: String) async throws -> HermesSkillDocument {
        importedData = data
        importedKind = kind
        importedCategory = category
        return try await mutate { try await backing.importSkill(data: data, kind: kind, category: category, agentID: agentID) }
    }
}
