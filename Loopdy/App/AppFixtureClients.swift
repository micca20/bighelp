import Foundation

@MainActor
final class DemoSessionControlMessaging: LoopdyLinkSessionControlMessaging {
    private var models: [String: (provider: String, model: String)] = [:]
    private var reasoning: [String: String]

    init(reasoning: [String: String] = [:]) {
        self.reasoning = reasoning
    }

    func openPicker(_ request: LoopdyLinkPickerOpenRequest) async throws -> LoopdyLinkPicker {
        switch request.kind {
        case .model:
            let current = models[request.sessionID] ?? ("nous", "Hermes-4-405B")
            return .model(try JSONDecoder().decode(
                LoopdyLinkModelPicker.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "picker.model",
                      "pickerId": "picker_model_fixture_0001",
                      "sessionId": "\(request.sessionID)",
                      "currentModel": "\(current.model)",
                      "currentProvider": "\(current.provider)",
                      "providers": [
                        {
                          "id": "nous",
                          "name": "Nous Research",
                          "isCurrent": \(current.provider == "nous"),
                          "isCustom": false,
                          "models": ["Hermes-4-405B", "Hermes-4-70B"]
                        },
                        {
                          "id": "openai",
                          "name": "OpenAI",
                          "isCurrent": \(current.provider == "openai"),
                          "isCustom": false,
                          "models": ["gpt-5.6", "gpt-5.6-mini"]
                        },
                        {
                          "id": "anthropic",
                          "name": "Anthropic",
                          "isCurrent": \(current.provider == "anthropic"),
                          "isCustom": false,
                          "models": ["claude-opus-4.1", "claude-sonnet-4.1"]
                        }
                      ],
                      "sentAt": 1788000000
                    }
                    """.utf8
                )
            ))
        case .reasoning:
            let current = reasoning[request.sessionID] ?? "reset"
            return .choice(try JSONDecoder().decode(
                LoopdyLinkChoicePicker.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "picker.choice",
                      "pickerId": "picker_reason_fixture_0001",
                      "sessionId": "\(request.sessionID)",
                      "kind": "reasoning",
                      "title": "Reasoning effort",
                      "choices": [
                        {"value": "reset", "label": "Use default", "isCurrent": \(current == "reset")},
                        {"value": "low", "label": "Low", "isCurrent": \(current == "low")},
                        {"value": "medium", "label": "Medium", "isCurrent": \(current == "medium")},
                        {"value": "high", "label": "High", "isCurrent": \(current == "high")},
                        {"value": "max", "label": "Max", "isCurrent": \(current == "max")}
                      ],
                      "sentAt": 1788000000
                    }
                    """.utf8
                )
            ))
        }
    }

    func selectPicker(_ selection: LoopdyLinkPickerSelection) async throws -> LoopdyLinkPickerResult {
        switch selection.kind {
        case .model:
            if let provider = selection.provider, let model = selection.model {
                models[selection.sessionID] = (provider, model)
            }
        case .reasoning:
            if let value = selection.value {
                reasoning[selection.sessionID] = value
            }
        }
        return try JSONDecoder().decode(
            LoopdyLinkPickerResult.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.result",
                  "pickerId": "\(selection.pickerID)",
                  "sessionId": "\(selection.sessionID)",
                  "kind": "\(selection.kind.rawValue)",
                  "status": "completed",
                  "message": "Updated",
                  "sentAt": 1788000000
                }
                """.utf8
            )
        )
    }
}

@MainActor
final class DemoAgentDirectoryClient: AgentDirectoryClient {
    static let fixtureProfiles = [
        AgentProfile(
            id: "finance",
            name: "Avery Park",
            role: "Finance agent",
            summary: "Budget, planning, and financial decisions.",
            instructions: "Help with financial planning.",
            avatarFileName: nil,
            isDefault: true
        ),
        AgentProfile(
            id: "travel",
            name: "Mina Shah",
            role: "Travel agent",
            summary: "Trips and itineraries.",
            instructions: "Help with travel planning.",
            avatarFileName: nil,
            isDefault: false
        ),
        AgentProfile(
            id: "home",
            name: "Jordan Lee",
            role: "Home agent",
            summary: "Home and household planning.",
            instructions: "Help with home planning.",
            avatarFileName: nil,
            isDefault: false
        )
    ]

    private let repository: DemoRepository<[AgentProfile]>

    init(repository: DemoRepository<[AgentProfile]>) {
        self.repository = repository
    }

    func list() async throws -> [AgentProfile] {
        try repository.load()
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        var profiles = try repository.load()
        let profile = AgentProfile(
            id: UUID().uuidString,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            isDefault: draft.isDefault
        )
        profiles.append(profile)
        try repository.save(profiles)
        try repository.removeOrphanedAvatarFiles(keeping: Set(profiles.compactMap(\.avatarFileName)))
        return profile
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        var profiles = try repository.load()
        let profile = AgentProfile(
            id: id,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            isDefault: draft.isDefault
        )
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        profiles[index] = profile
        try repository.save(profiles)
        try repository.removeOrphanedAvatarFiles(keeping: Set(profiles.compactMap(\.avatarFileName)))
        return profile
    }
}
