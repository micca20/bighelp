import Foundation

enum AgentTemplateSection: String, CaseIterable, Identifiable, Sendable {
    case skills
    case mcpServers
    case tools
    case soul
    case config

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skills: "Skills"
        case .mcpServers: "MCP Servers"
        case .tools: "Tools"
        case .soul: "SOUL"
        case .config: "Config"
        }
    }

    var systemImage: String {
        switch self {
        case .skills: "books.vertical"
        case .mcpServers: "server.rack"
        case .tools: "wrench.and.screwdriver"
        case .soul: "text.page"
        case .config: "slider.horizontal.3"
        }
    }

    var help: String {
        switch self {
        case .skills: "A JSON array of independent SKILL.md snapshots."
        case .mcpServers: "A credential-free JSON projection. Environment and header names may remain; their values never do."
        case .tools: "The profile’s toolset selections and the tool names each selection contributes."
        case .soul: "An independent copy of the profile’s SOUL. Editing this does not edit the source profile."
        case .config: "Only the host’s allowlisted, credential-free configuration fields."
        }
    }
}

struct AgentTemplateSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let revision: String
    let derivedAt: Date
    let omissionCount: Int
}

struct AgentTemplateCatalog: Equatable, Sendable {
    let profileID: String
    let storageFolder: String
    let templates: [AgentTemplateSummary]
}

struct AgentTemplateDocument: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    let sourceProfileID: String
    let sourceSnapshotRevision: String
    let derivedAt: Date
    var soul: String
    var skillsJSON: String
    var mcpServersJSON: String
    var toolsJSON: String
    var configJSON: String
    let omissions: [String]
    var revision: String?

    func text(for section: AgentTemplateSection) -> String {
        switch section {
        case .skills: skillsJSON
        case .mcpServers: mcpServersJSON
        case .tools: toolsJSON
        case .soul: soul
        case .config: configJSON
        }
    }

    mutating func setText(_ text: String, for section: AgentTemplateSection) {
        switch section {
        case .skills: skillsJSON = text
        case .mcpServers: mcpServersJSON = text
        case .tools: toolsJSON = text
        case .soul: soul = text
        case .config: configJSON = text
        }
    }
}

@MainActor
protocol AgentProfileTemplateClient: AnyObject {
    func list(profileID: String, owner: WorkspaceOwner) async throws -> AgentTemplateCatalog
    func derive(profileID: String, templateID: UUID, owner: WorkspaceOwner) async throws -> AgentTemplateDocument
    func read(profileID: String, templateID: String, owner: WorkspaceOwner) async throws -> AgentTemplateDocument
    func save(_ document: AgentTemplateDocument, profileID: String,
              expectedRevision: String?, owner: WorkspaceOwner) async throws -> AgentTemplateDocument
}
