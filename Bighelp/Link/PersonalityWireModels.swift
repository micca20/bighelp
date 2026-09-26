import Foundation

struct BighelpLinkPersonalityRequest: Encodable, Equatable, Sendable {
    enum Action: String, Codable, Equatable, Sendable {
        case catalog
        case save
        case delete
        case activate
    }

    let version = 1
    let requestID: String
    let action: Action
    let expectedRevision: Int?
    let name: String?
    let draft: PersonalityDraft?
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case action
        case expectedRevision
        case name
        case draft = "definition"
        case sentAt
    }

    init(
        requestID: String,
        action: Action,
        expectedRevision: Int?,
        name: String?,
        draft: PersonalityDraft?,
        sentAt: Int
    ) throws {
        guard
            BighelpLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            sentAt > 0
        else { throw BighelpLinkWireError.invalidValue }
        switch action {
        case .catalog:
            guard expectedRevision == nil, name == nil, draft == nil else {
                throw BighelpLinkWireError.invalidValue
            }
        case .save:
            guard let expectedRevision, expectedRevision >= 0,
                  let name, let draft, name == draft.name else {
                throw BighelpLinkWireError.invalidValue
            }
        case .delete:
            guard let expectedRevision, expectedRevision >= 0,
                  let name, !name.isEmpty, draft == nil else {
                throw BighelpLinkWireError.invalidValue
            }
        case .activate:
            guard let expectedRevision, expectedRevision >= 0, draft == nil else {
                throw BighelpLinkWireError.invalidValue
            }
        }
        self.requestID = requestID
        self.action = action
        self.expectedRevision = expectedRevision
        self.name = name
        self.draft = draft
        self.sentAt = sentAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(
            action == .catalog ? "personalities.catalog.request" : "personalities.mutate",
            forKey: .type
        )
        try container.encode(requestID, forKey: .requestID)
        if action != .catalog {
            try container.encode(action, forKey: .action)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(draft, forKey: .draft)
        }
        try container.encode(sentAt, forKey: .sentAt)
    }
}

struct BighelpLinkPersonalityCatalog: Decodable, Equatable, Sendable {
    let requestID: String
    let catalog: PersonalityCatalog
    let sentAt: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case requestID = "requestId"
        case revision
        case activeName
        case personalities
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try BighelpLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw BighelpLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "personalities.catalog"
        else { throw BighelpLinkWireError.invalidValue }
        requestID = try container.decode(String.self, forKey: .requestID)
        let revision = try container.decode(Int.self, forKey: .revision)
        let activeName = try container.decode(String.self, forKey: .activeName)
        let personalities = try container.decode(
            [PersonalityDefinition].self,
            forKey: .personalities
        )
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        let names = personalities.map(\.name)
        guard
            BighelpLinkPickerValidation.opaque(requestID, minimum: 16, maximum: 128),
            revision >= 0,
            activeName.isEmpty || BighelpLinkPickerValidation.opaque(
                activeName,
                minimum: 1,
                maximum: 64
            ),
            personalities.count <= 100,
            Set(names).count == names.count,
            activeName.isEmpty || names.contains(activeName),
            sentAt > 0
        else { throw BighelpLinkWireError.invalidValue }
        catalog = PersonalityCatalog(
            revision: revision,
            activeName: activeName,
            personalities: personalities
        )
    }
}
