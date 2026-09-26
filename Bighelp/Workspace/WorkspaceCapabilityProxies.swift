import Foundation

@MainActor
final class WorkspaceSkillsAndToolsProxy: HermesSkillsAndToolsCatalogClient {
    let box: WorkspaceOwnedClientBox<any HermesSkillsAndToolsCatalogClient>
    init(box: WorkspaceOwnedClientBox<any HermesSkillsAndToolsCatalogClient>) { self.box = box }
    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog { try await box.value().load(agentID: agentID) }
    func control(kind: HermesCapabilityKind, id: String, agentID: String) async throws -> HermesCapabilityControl {
        try await box.value().control(kind: kind, id: id, agentID: agentID)
    }
    func setEnabled(_ enabled: Bool, control: HermesCapabilityControl) async throws -> HermesCapabilityControl {
        try await box.value().setEnabled(enabled, control: control)
    }
    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        try await box.value().skill(id: id, agentID: agentID)
    }
    func createSkill(name: String, content: String, category: String?, agentID: String) async throws -> HermesSkillDocument {
        try await box.value().createSkill(name: name, content: content, category: category, agentID: agentID)
    }
    func updateSkill(id: String, content: String, expectedSHA256: String, agentID: String) async throws -> HermesSkillDocument {
        try await box.value().updateSkill(id: id, content: content, expectedSHA256: expectedSHA256, agentID: agentID)
    }
    func importSkill(data: Data, kind: String, category: String?, agentID: String) async throws -> HermesSkillDocument {
        try await box.value().importSkill(data: data, kind: kind, category: category, agentID: agentID)
    }
}

/// Resolve the selected profile for each request; never reuse a previous agent's client.
@MainActor
final class WorkspacePersonalityProxy: PersonalityClient {
    let makeClient: @MainActor () throws -> any PersonalityClient
    init(makeClient: @escaping @MainActor () throws -> any PersonalityClient) { self.makeClient = makeClient }
    func load() async throws -> PersonalityCatalog { try await makeClient().load() }
    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        try await makeClient().mutate(request)
    }
}
