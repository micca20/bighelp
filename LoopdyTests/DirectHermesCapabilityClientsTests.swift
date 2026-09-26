import CryptoKit
import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesCapabilityClientsTests {
    @Test func skillsLoadReadsOfficialSkillPluginMCPAndToolsetSurfaces() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.skillsToolsList] = ["skills": .array([
            .object(["name": .string("daily"), "description": .string("Daily workflow"),
                     "category": .string("productivity"), "enabled": .boolean(true)])
        ])]
        workspace.responses[.pluginsList] = ["plugins": .array([
            .object(["key": .string("calendar"), "name": .string("Calendar"),
                     "version": .string("1.0"), "description": .string("Calendar tools"),
                     "status": .string("enabled"), "provides": .array([.string("events")])])
        ])]
        workspace.responses[.mcpServersList] = ["servers": .array([
            .object(["name": .string("docs"), "transport": .string("streamable_http"),
                     "enabled": .boolean(true), "tools": .array([.string("search"), .string("open")])])
        ])]
        workspace.responses[.toolsetsList] = ["toolsets": .array([
            .object(["name": .string("browser"), "label": .string("Browser"),
                     "description": .string("Browser actions"), "platform": .string("native"),
                     "enabled": .boolean(true), "tools": .array([.string("open")])])
        ])]

        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )
        let catalog = try await client.load(agentID: "studio")

        #expect(catalog.agentID == "studio")
        #expect(catalog.skills.map(\.id) == ["daily"])
        #expect(catalog.plugins.map(\.id) == ["calendar"])
        #expect(catalog.mcpServers.map(\.id) == ["docs"])
        #expect(catalog.tools.map(\.id) == ["browser"])
        #expect(catalog.skills.first?.isEnabled == true)
        #expect(catalog.plugins.first?.capabilityCount == 1)
        #expect(catalog.mcpServers.first?.toolCount == 2)
        #expect(catalog.tools.first?.toolCount == 1)
        #expect(workspace.calls.map(\.operation) == [.skillsToolsList, .pluginsList, .mcpServersList, .toolsetsList])
        #expect(workspace.calls.allSatisfy { $0.payload["profile"] == .string("studio") })

        let store = SkillsAndToolsStore(client: client)
        await store.load(agentID: "studio")
        #expect(store.catalog?.management?.canUpdate == true)
        #expect(store.catalog?.management?.canImport == false)
        #expect(store.compatibilityMessage == catalog.toolsNotice)
        #expect(store.compatibilityMessage?.contains("Update Hermes") == false)
    }

    @Test func skillsLoadAcceptsOfficialMCPToolFilterObjectWithoutInventingToolCount() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.skillsToolsList] = ["skills": .array([])]
        workspace.responses[.pluginsList] = ["plugins": .array([])]
        workspace.responses[.mcpServersList] = ["servers": .array([
            .object([
                "name": .string("docs"), "transport": .string("stdio"),
                "enabled": .boolean(true),
                "tools": .object(["include": .array([.string("search")])])
            ])
        ])]
        workspace.responses[.toolsetsList] = ["toolsets": .array([])]

        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )

        let catalog = try await client.load(agentID: "studio")

        #expect(catalog.mcpServers.map(\.id) == ["docs"])
        #expect(catalog.mcpServers.first?.toolCount == nil)
    }

    @Test func skillsLoadAcceptsOfficialMultilineCatalogDescriptions() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.skillsToolsList] = ["skills": .array([
            .object([
                "name": .string("daily"),
                "description": .string("Daily workflow\nSecond line\twith detail"),
                "category": .string("productivity"), "enabled": .boolean(true)
            ])
        ])]
        workspace.responses[.pluginsList] = ["plugins": .array([
            .object([
                "key": .string("calendar"), "name": .string("Calendar"),
                "description": .string("Calendar tools\nSecond line"),
                "status": .string("enabled")
            ])
        ])]
        workspace.responses[.mcpServersList] = ["servers": .array([])]
        workspace.responses[.toolsetsList] = ["toolsets": .array([
            .object([
                "name": .string("browser"), "label": .string("Browser"),
                "description": .string("Browser actions\nSecond line"),
                "platform": .string("native"), "enabled": .boolean(true),
                "tools": .array([])
            ])
        ])]

        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )

        let catalog = try await client.load(agentID: "studio")

        #expect(catalog.skills.first?.description == "Daily workflow\nSecond line\twith detail")
        #expect(catalog.plugins.first?.description == "Calendar tools\nSecond line")
        #expect(catalog.tools.first?.description == "Browser actions\nSecond line")
    }

    @Test func skillContentUsesOfficialContentResponseAndComputesDigestWithoutHostPath() async throws {
        let workspace = try CapabilityWorkspace()
        let content = "---\nname: daily\n---\nDo the daily work.\n"
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        workspace.responses[.skillsToolsGet] = [
            "name": .string("daily"), "content": .string(content),
            "path": .string("/private/hermes/skills/daily/SKILL.md")
        ]
        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )

        let document = try await client.skill(id: "daily", agentID: "studio")
        #expect(document.agentID == "studio")
        #expect(document.skillID == "daily")
        #expect(document.content == content)
        #expect(document.sha256 == digest)
        #expect(workspace.calls.first?.payload == ["profile": .string("studio"), "name": .string("daily")])
    }

    @Test func skillCreateAndUpdateReadBackAuthoritativeContent() async throws {
        let workspace = try CapabilityWorkspace()
        let created = "---\nname: daily\n---\nFirst.\n"
        let updated = "---\nname: daily\n---\nSecond.\n"
        workspace.responses[.skillsToolsCreate] = ["success": .boolean(true), "name": .string("daily")]
        workspace.responses[.skillsToolsUpdate] = ["success": .boolean(true), "name": .string("daily")]
        workspace.sequence[.skillsToolsGet] = [
            ["name": .string("daily"), "content": .string(created), "path": .string("/host/private")],
            ["name": .string("daily"), "content": .string(created), "path": .string("/host/private")],
            ["name": .string("daily"), "content": .string(updated), "path": .string("/host/private")]
        ]
        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )

        let first = try await client.createSkill(name: "daily", content: created, category: "work", agentID: "studio")
        let expected = SHA256.hash(data: Data(created.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(first.sha256 == expected)

        let currentDigest = first.sha256
        let second = try await client.updateSkill(
            id: "daily", content: updated, expectedSHA256: currentDigest, agentID: "studio"
        )
        #expect(second.content == updated)
        #expect(workspace.calls.map(\.operation) == [
            .skillsToolsCreate, .skillsToolsGet, .skillsToolsGet, .skillsToolsUpdate, .skillsToolsGet
        ])
        #expect(workspace.calls[0].payload["profile"] == .string("studio"))
        #expect(workspace.calls[0].payload["category"] == .string("work"))
        #expect(workspace.calls[3].payload["name"] == .string("daily"))
    }

    @Test func skillToggleUsesNativeToggleReceiptAndRejectsNonSkillControls() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.skillsToolsList] = ["skills": .array([
            .object(["name": .string("daily"), "description": .string(""), "category": .string(""),
                     "enabled": .boolean(true)])
        ])]
        workspace.responses[.pluginsList] = ["plugins": .array([])]
        workspace.responses[.mcpServersList] = ["servers": .array([])]
        workspace.responses[.toolsetsList] = ["toolsets": .array([])]
        workspace.responses[.skillsToolsUpdate] = [
            "ok": .boolean(true), "name": .string("daily"), "enabled": .boolean(false)
        ]
        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )
        _ = try await client.load(agentID: "studio")
        let control = try await client.control(kind: .skill, id: "daily", agentID: "studio")
        let result = try await client.setEnabled(false, control: control)

        #expect(result.isEnabled == false)
        #expect(workspace.calls.last?.operation == .skillsToolsUpdate)
        #expect(workspace.calls.last?.payload["enabled"] == .boolean(false))
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.control(kind: .plugin, id: "calendar", agentID: "studio")
        }
    }

    @Test func unsupportedImportDoesNotSendSkillBytesToAnInventedRoute() async throws {
        let workspace = try CapabilityWorkspace()
        let client = DirectHermesSkillsAndToolsClient(
            workspace: workspace, owner: workspace.initialOwner,
            currentOwner: { workspace.owner }
        )
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.importSkill(
                data: Data("archive".utf8), kind: "zip", category: nil, agentID: "studio"
            )
        }
        #expect(workspace.calls.isEmpty)
    }

    @Test func personalityLoadExposesOnlyConfiguredCustomDefinitionsAndActiveName() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.personalitiesList] = [
            "display": .object(["personality": .string("helpful")]),
            "personalities": .object([
                "reviewer": .object([
                    "description": .string("Reviews code"), "system_prompt": .string("Review carefully."),
                    "tone": .string("precise"), "style": .string("concise")
                ])
            ]),
            "agent": .object(["personalities": .object([
                "writer": .string("Write clearly.")
            ])])
        ]
        let client = DirectHermesPersonalityClient(
            workspace: workspace, owner: workspace.initialOwner, profileID: "studio",
            currentOwner: { workspace.owner }
        )

        let catalog = try await client.load()
        #expect(catalog.activeName == "helpful")
        #expect(catalog.personalities.map(\.name) == ["reviewer", "writer"])
        #expect(catalog.personalities.allSatisfy { !$0.isBuiltIn && $0.isCustomized })
        #expect(catalog.personalities.first?.systemPrompt == "Review carefully.")
        #expect(workspace.calls.first?.payload["profile"] == .string("studio"))
    }

    @Test func personalityActivationUsesOfficialConfigWriteAndReadsBack() async throws {
        let workspace = try CapabilityWorkspace()
        workspace.responses[.personalitiesList] = [
            "display": .object(["personality": .string("reviewer")]),
            "personalities": .object(["reviewer": .object([
                "system_prompt": .string("Review carefully.")
            ])])
        ]
        workspace.sequence[.personalitiesList] = [
            ["display": .object(["personality": .string("reviewer")]),
             "personalities": .object(["reviewer": .object(["system_prompt": .string("Review carefully.")])])],
            ["display": .object(["personality": .string("reviewer")]),
             "personalities": .object(["reviewer": .object(["system_prompt": .string("Review carefully.")])])],
            ["ok": .boolean(true)],
            ["display": .object(["personality": .string("reviewer")]),
             "personalities": .object(["reviewer": .object(["system_prompt": .string("Review carefully.")])])]
        ]
        let client = DirectHermesPersonalityClient(
            workspace: workspace, owner: workspace.initialOwner, profileID: "studio",
            currentOwner: { workspace.owner }
        )
        let before = try await client.load()
        let after = try await client.mutate(PersonalityMutation(
            action: .activate, expectedRevision: before.revision, name: "reviewer", draft: nil
        ))

        #expect(after.activeName == "reviewer")
        #expect(workspace.calls.map(\.operation) == [.personalitiesList, .personalitiesList, .personalitiesList, .personalitiesList])
        #expect(workspace.calls[2].payload["action"] == .string("activate"))
        #expect(workspace.calls[2].payload["config"]?.object?["display"]?.object?["personality"] == .string("reviewer"))
    }

    @Test func personalityDeleteRemainsUnavailableWithoutPublicHermesDelete() async throws {
        let workspace = try CapabilityWorkspace()
        let client = DirectHermesPersonalityClient(
            workspace: workspace, owner: workspace.initialOwner, profileID: "studio",
            currentOwner: { workspace.owner }
        )
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.mutate(PersonalityMutation(
                action: .delete, expectedRevision: 0, name: "reviewer", draft: nil
            ))
        }
        #expect(workspace.calls.isEmpty)
    }

    @Test func personalitySaveUsesConfigDeepMergeAndReadsBackDefinition() async throws {
        let workspace = try CapabilityWorkspace()
        let client = DirectHermesPersonalityClient(
            workspace: workspace, owner: workspace.initialOwner, profileID: "studio",
            currentOwner: { workspace.owner }
        )
        let initial: [String: LoopdyJSONValue] = [
            "display": .object(["personality": .string("")]), "personalities": .object([:])
        ]
        let saved: [String: LoopdyJSONValue] = [
            "display": .object(["personality": .string("")]),
            "agent": .object(["personalities": .object(["reviewer": .object([
                "description": .string("Reviews"), "system_prompt": .string("Review."),
                "tone": .string("precise"), "style": .string("concise")
            ])])])
        ]
        workspace.sequence[.personalitiesList] = [initial, initial, ["ok": .boolean(true)], saved]
        let before = try await client.load()
        let draft = try PersonalityDraft.validated(
            originalName: nil, name: "reviewer", description: "Reviews", systemPrompt: "Review.",
            tone: "precise", style: "concise"
        )
        let after = try await client.mutate(PersonalityMutation(
            action: .save, expectedRevision: before.revision, name: draft.name, draft: draft
        ))
        #expect(after.personalities.map(\.name) == ["reviewer"])
        #expect(workspace.calls.map(\.operation) == [.personalitiesList, .personalitiesList, .personalitiesList, .personalitiesList])
        #expect(workspace.calls[2].payload["action"] == .string("save"))
    }
}

@MainActor
private final class CapabilityWorkspace: WorkspaceOperationPerforming {
    struct Call {
        let operation: WorkspaceOperation
        let payload: [String: LoopdyJSONValue]
    }

    let initialOwner: WorkspaceOwner
    var owner: WorkspaceOwner?
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [String: LoopdyJSONValue]] = [:]
    var sequence: [WorkspaceOperation: [[String: LoopdyJSONValue]]] = [:]

    var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(owner: owner, values: Dictionary(
            uniqueKeysWithValues: WorkspaceCapability.allCases.map { ($0, .available) }
        ))
    }

    init() throws {
        initialOwner = WorkspaceOwner(
            authority: try .fixture(id: "direct-capability-client-tests"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        owner = initialOwner
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: LoopdyJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: LoopdyJSONValue] {
        guard self.owner == owner else { throw WorkspaceClientError.ownerChanged }
        calls.append(Call(operation: operation, payload: payload))
        if var values = sequence[operation], !values.isEmpty {
            let first = values.removeFirst()
            sequence[operation] = values
            return first
        }
        return responses[operation] ?? [:]
    }
}
