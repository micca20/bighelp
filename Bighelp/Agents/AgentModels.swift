import Foundation

struct AgentAvatar: Codable, Equatable, Sendable {
    let mimeType: String
    let byteCount: Int
    let sha256: String
    let dataURL: String
}

struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var role: String
    var summary: String
    var instructions: String
    var avatarFileName: String?
    var avatar: AgentAvatar? = nil
    var isDefault: Bool
}

extension AgentProfile {
    static let bighelpLinkDefault = AgentProfile(
        id: "default",
        name: "bighelp",
        role: "Default agent",
        summary: "Your default Hermes agent.",
        instructions: "",
        avatarFileName: nil,
        isDefault: true
    )
}

struct AgentDraft: Codable, Equatable, Sendable {
    var name: String
    var role: String
    var summary: String
    var instructions: String
    var avatarFileName: String?
    var avatar: AgentAvatar? = nil
    var removesAvatar = false
    var isDefault: Bool
    /// Creation-only options forwarded to stock Hermes on the selected host.
    var cloneSourceProfileID: String? = nil
    var skipBundledSkills = false
}

extension AgentDraft {
    private enum CodingKeys: String, CodingKey {
        case name, role, summary, instructions, avatarFileName, avatar, removesAvatar, isDefault
        case cloneSourceProfileID, skipBundledSkills
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decode(String.self, forKey: .role)
        summary = try values.decode(String.self, forKey: .summary)
        instructions = try values.decode(String.self, forKey: .instructions)
        avatarFileName = try values.decodeIfPresent(String.self, forKey: .avatarFileName)
        avatar = try values.decodeIfPresent(AgentAvatar.self, forKey: .avatar)
        removesAvatar = try values.decodeIfPresent(Bool.self, forKey: .removesAvatar) ?? false
        isDefault = try values.decode(Bool.self, forKey: .isDefault)
        cloneSourceProfileID = try values.decodeIfPresent(String.self, forKey: .cloneSourceProfileID)
        skipBundledSkills = try values.decodeIfPresent(Bool.self, forKey: .skipBundledSkills) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(role, forKey: .role)
        try values.encode(summary, forKey: .summary)
        try values.encode(instructions, forKey: .instructions)
        try values.encodeIfPresent(avatarFileName, forKey: .avatarFileName)
        try values.encodeIfPresent(avatar, forKey: .avatar)
        try values.encode(removesAvatar, forKey: .removesAvatar)
        try values.encode(isDefault, forKey: .isDefault)
        try values.encodeIfPresent(cloneSourceProfileID, forKey: .cloneSourceProfileID)
        try values.encode(skipBundledSkills, forKey: .skipBundledSkills)
    }
}

struct AgentDirectoryPartialMutationError: Error, Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case name, role, summary, instructions, avatar
    }

    let committedProfile: AgentProfile
    let unappliedFields: Set<Field>
    let isOutcomeUncertain: Bool

    init(
        committedProfile: AgentProfile,
        unappliedFields: Set<Field> = [.avatar],
        isOutcomeUncertain: Bool = false
    ) {
        self.committedProfile = committedProfile
        self.unappliedFields = unappliedFields
        self.isOutcomeUncertain = isOutcomeUncertain
    }
}

@MainActor
protocol AgentDirectoryClient {
    func list() async throws -> [AgentProfile]
    func create(_ draft: AgentDraft) async throws -> AgentProfile
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile
    func resetForAccountBoundary()
}

extension AgentDirectoryClient {
    func resetForAccountBoundary() {}
}
