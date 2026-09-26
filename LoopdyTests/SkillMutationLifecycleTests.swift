import Foundation
import Testing
@testable import Loopdy

@MainActor
struct SkillMutationLifecycleTests {
    @Test(arguments: [false, true])
    func closingEditorDuringSaveDoesNotWedgeTheCatalog(fail: Bool) async throws {
        let client = DeferredSkillSaveClient()
        let store = SkillsAndToolsStore(client: client)
        await store.load(agentID: "default")
        let document = try #require(await store.loadSkill(id: "weather", agentID: "default"))
        let save = Task { await store.saveSkill(content: document.content + "\nVerify facts.", agentID: "default", expectedDocument: document) }
        for _ in 0..<30 where !client.didRequest { await Task.yield() }
        #expect(client.didRequest)
        #expect(store.isSaving)
        store.clearDocument()
        client.finish(fail: fail)
        #expect(!(await save.value))
        #expect(!store.isSaving)
        #expect(store.document == nil)
        #expect(await store.loadSkill(id: "weather", agentID: "default") != nil)
    }
}

@MainActor
private final class DeferredSkillSaveClient: HermesSkillsAndToolsCatalogClient {
    private let backing = FixtureSkillsAndToolsClient()
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var didRequest = false

    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        try await backing.load(agentID: agentID)
    }

    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        try await backing.skill(id: id, agentID: agentID)
    }

    func updateSkill(id: String, content: String, expectedSHA256: String, agentID: String) async throws -> HermesSkillDocument {
        didRequest = true
        try await withCheckedThrowingContinuation { continuation = $0 }
        return try await backing.updateSkill(id: id, content: content, expectedSHA256: expectedSHA256, agentID: agentID)
    }

    func finish(fail: Bool) {
        if fail { continuation?.resume(throwing: URLError(.notConnectedToInternet)) }
        else { continuation?.resume() }
        continuation = nil
    }
}
