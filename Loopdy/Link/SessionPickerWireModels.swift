import Foundation

enum LoopdyLinkPickerKind: String, Codable, Equatable, Sendable {
    case model
    case reasoning
}

struct LoopdyLinkPickerOpenRequest: Encodable, Equatable, Sendable {
    let version = 1
    let type = "picker.open"
    let requestID: String
    let sessionID: String
    let agentID: String
    let kind: LoopdyLinkPickerKind
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case requestID = "requestId"
        case sessionID = "sessionId"
        case agentID = "agentId"
        case kind
        case sentAt
    }
}

struct LoopdyLinkPickerSelection: Encodable, Equatable, Sendable {
    let version = 1
    let type = "picker.select"
    let pickerID: String
    let sessionID: String
    let kind: LoopdyLinkPickerKind
    let provider: String?
    let model: String?
    let value: String?
    let sentAt: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case pickerID = "pickerId"
        case sessionID = "sessionId"
        case kind
        case provider
        case model
        case value
        case sentAt
    }

    init(
        pickerID: String,
        sessionID: String,
        kind: LoopdyLinkPickerKind,
        provider: String?,
        model: String?,
        value: String?,
        sentAt: Int,
        nativeCoordinate: NativeSessionRuntimePickerCoordinate? = nil
    ) throws {
        let hasValidChoice = switch kind {
        case .model:
            provider.flatMap { LoopdyLinkPickerValidation.identifier($0, maximum: 128) } != nil
                && model.flatMap { LoopdyLinkPickerValidation.modelIdentifier($0, maximum: 256) } != nil
                && value == nil
        case .reasoning:
            provider == nil
                && model == nil
                && value.flatMap { LoopdyLinkPickerValidation.identifier($0, maximum: 64) } != nil
        }
        guard
            LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
            nativeCoordinate.map({ DirectHermesSessionValidation.same($0.workspace.sessionID, sessionID) })
                ?? LoopdyLinkSessionCoordinate.isValid(sessionID),
            hasValidChoice,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
        self.pickerID = pickerID
        self.sessionID = sessionID
        self.kind = kind
        self.provider = provider
        self.model = model
        self.value = value
        self.sentAt = sentAt
    }

    func encode(to encoder: any Encoder) throws {
        guard LoopdyLinkSessionCoordinate.isValid(sessionID) else { throw LoopdyLinkWireError.invalidValue }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(pickerID, forKey: .pickerID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        switch kind {
        case .model:
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
        case .reasoning:
            try container.encode(value, forKey: .value)
        }
        try container.encode(sentAt, forKey: .sentAt)
    }
}

struct LoopdyLinkModelProvider: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let isCurrent: Bool
    let isCustom: Bool
    let models: [String]

    init(
        id: String,
        name: String,
        isCurrent: Bool,
        isCustom: Bool,
        models: [String]
    ) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.isCustom = isCustom
        self.models = models
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case isCurrent
        case isCustom
        case models
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        models = try container.decode([String].self, forKey: .models)
        guard
            LoopdyLinkPickerValidation.identifier(id, maximum: 128) != nil,
            LoopdyLinkPickerValidation.label(name, maximum: 80) != nil,
            (1...50).contains(models.count),
            Set(models).count == models.count,
            models.allSatisfy({ LoopdyLinkPickerValidation.modelIdentifier($0, maximum: 256) != nil })
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

struct LoopdyLinkModelPicker: Decodable, Equatable, Sendable {
    let pickerID: String
    let sessionID: String
    let currentModel: String
    let currentProvider: String
    let providers: [LoopdyLinkModelProvider]
    let sentAt: Int
    let nativeCoordinate: NativeSessionRuntimePickerCoordinate?

    /// Native UI projections use a bounded catalog independently of Link wire limits.
    init(
        pickerID: String, nativeCoordinate: NativeSessionRuntimePickerCoordinate,
        currentModel: String, currentProvider: String,
        providers: [LoopdyLinkModelProvider], sentAt: Int
    ) throws {
        guard LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
              LoopdyLinkPickerValidation.modelIdentifier(currentModel, maximum: 256) != nil,
              LoopdyLinkPickerValidation.identifier(currentProvider, maximum: 128) != nil,
              providers.count <= 128,
              Set(providers.map(\.id)).count == providers.count,
              providers.reduce(0, { $0 + $1.models.count }) <= 20_000,
              providers.allSatisfy({
                  LoopdyLinkPickerValidation.identifier($0.id, maximum: 128) != nil
                      && LoopdyLinkPickerValidation.label($0.name, maximum: 800) != nil
                      && $0.models.count <= 10_000
                      && Set($0.models).count == $0.models.count
                      && $0.models.allSatisfy { LoopdyLinkPickerValidation.modelIdentifier($0, maximum: 256) != nil }
              }),
              sentAt > 0 else { throw LoopdyLinkWireError.invalidValue }
        self.pickerID = pickerID
        self.sessionID = nativeCoordinate.workspace.sessionID
        self.nativeCoordinate = nativeCoordinate
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.providers = providers
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case pickerID = "pickerId"
        case sessionID = "sessionId"
        case currentModel
        case currentProvider
        case providers
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "picker.model"
        else { throw LoopdyLinkWireError.invalidValue }
        pickerID = try container.decode(String.self, forKey: .pickerID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        currentModel = try container.decode(String.self, forKey: .currentModel)
        currentProvider = try container.decode(String.self, forKey: .currentProvider)
        providers = try container.decode([LoopdyLinkModelProvider].self, forKey: .providers)
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        nativeCoordinate = nil
        guard
            LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            LoopdyLinkPickerValidation.modelIdentifier(currentModel, maximum: 256) != nil,
            LoopdyLinkPickerValidation.identifier(currentProvider, maximum: 128) != nil,
            (1...32).contains(providers.count),
            Set(providers.map(\.id)).count == providers.count,
            providers.reduce(0, { $0 + $1.models.count }) <= 800,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

struct LoopdyLinkChoice: Decodable, Equatable, Identifiable, Sendable {
    var id: String { value }
    let value: String
    let label: String
    let isCurrent: Bool

    init(value: String, label: String, isCurrent: Bool) throws {
        guard LoopdyLinkPickerValidation.identifier(value, maximum: 64) != nil,
              LoopdyLinkPickerValidation.label(label, maximum: 96) != nil else {
            throw LoopdyLinkWireError.invalidValue
        }
        self.value = value
        self.label = label
        self.isCurrent = isCurrent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case label
        case isCurrent
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        label = try container.decode(String.self, forKey: .label)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        guard
            LoopdyLinkPickerValidation.identifier(value, maximum: 64) != nil,
            LoopdyLinkPickerValidation.label(label, maximum: 96) != nil
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

struct LoopdyLinkChoicePicker: Decodable, Equatable, Sendable {
    let pickerID: String
    let sessionID: String
    let kind: LoopdyLinkPickerKind
    let title: String
    let choices: [LoopdyLinkChoice]
    let sentAt: Int
    let nativeCoordinate: NativeSessionRuntimePickerCoordinate?

    init(pickerID: String, nativeCoordinate: NativeSessionRuntimePickerCoordinate, kind: LoopdyLinkPickerKind,
         title: String, choices: [LoopdyLinkChoice], sentAt: Int) throws {
        guard kind == .reasoning,
              LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
              LoopdyLinkPickerValidation.label(title, maximum: 240) != nil,
              (1...16).contains(choices.count), Set(choices.map(\.value)).count == choices.count,
              sentAt > 0 else { throw LoopdyLinkWireError.invalidValue }
        self.pickerID = pickerID
        self.sessionID = nativeCoordinate.workspace.sessionID
        self.nativeCoordinate = nativeCoordinate
        self.kind = kind
        self.title = title
        self.choices = choices
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case pickerID = "pickerId"
        case sessionID = "sessionId"
        case kind
        case title
        case choices
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "picker.choice"
        else { throw LoopdyLinkWireError.invalidValue }
        pickerID = try container.decode(String.self, forKey: .pickerID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(LoopdyLinkPickerKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        choices = try container.decode([LoopdyLinkChoice].self, forKey: .choices)
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        nativeCoordinate = nil
        guard
            kind == .reasoning,
            LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            LoopdyLinkPickerValidation.label(title, maximum: 240) != nil,
            (1...16).contains(choices.count),
            Set(choices.map(\.value)).count == choices.count,
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

struct LoopdyLinkPickerResult: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Equatable, Sendable {
        case completed
        case failed
        case expired
    }

    let pickerID: String
    let sessionID: String
    let kind: LoopdyLinkPickerKind
    let status: Status
    let message: String
    let sentAt: Int

    init(pickerID: String, nativeCoordinate: NativeSessionRuntimePickerCoordinate, kind: LoopdyLinkPickerKind,
         status: Status, message: String, sentAt: Int) throws {
        guard LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
              !message.isEmpty, message.count <= 2_000,
              !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              sentAt > 0 else { throw LoopdyLinkWireError.invalidValue }
        self.pickerID = pickerID
        self.sessionID = nativeCoordinate.workspace.sessionID
        self.kind = kind
        self.status = status
        self.message = message
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case type
        case pickerID = "pickerId"
        case sessionID = "sessionId"
        case kind
        case status
        case message
        case sentAt
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try container.decode(Int.self, forKey: .version) == 1,
            try container.decode(String.self, forKey: .type) == "picker.result"
        else { throw LoopdyLinkWireError.invalidValue }
        pickerID = try container.decode(String.self, forKey: .pickerID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(LoopdyLinkPickerKind.self, forKey: .kind)
        status = try container.decode(Status.self, forKey: .status)
        message = try container.decode(String.self, forKey: .message)
        sentAt = try container.decode(Int.self, forKey: .sentAt)
        guard
            LoopdyLinkPickerValidation.opaque(pickerID, minimum: 16, maximum: 128),
            LoopdyLinkSessionCoordinate.isValid(sessionID),
            !message.isEmpty,
            message.count <= 2_000,
            !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            sentAt > 0
        else { throw LoopdyLinkWireError.invalidValue }
    }
}

enum LoopdyLinkPicker: Equatable, Sendable {
    case model(LoopdyLinkModelPicker)
    case choice(LoopdyLinkChoicePicker)

    var model: LoopdyLinkModelPicker? {
        guard case .model(let value) = self else { return nil }
        return value
    }

    var choice: LoopdyLinkChoicePicker? {
        guard case .choice(let value) = self else { return nil }
        return value
    }
}
