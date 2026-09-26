import Foundation

struct HermesMemoryStatus: Equatable, Sendable {
    struct BuiltInFiles: Equatable, Sendable {
        let memoryBytes: Int
        let userBytes: Int
    }

    let activeProvider: String
    let providers: [HermesMemoryProvider]
    let builtInFiles: BuiltInFiles
}

struct HermesMemoryProvider: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case needsConfiguration
        case missing
        case unavailable
        case other(String)

        var title: String {
            switch self {
            case .ready: "Ready"
            case .needsConfiguration: "Needs configuration"
            case .missing: "Missing"
            case .unavailable: "Unavailable"
            case .other(let value): value.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    struct Setup: Equatable, Sendable {
        let dependenciesInstalled: Bool
        let packageDependencies: [String]
        let externalDependencyNames: [String]
        let requiredEnvironmentKeys: [String]
        var hasInstallSteps: Bool { !packageDependencies.isEmpty || !externalDependencyNames.isEmpty }
    }

    let name: String
    let description: String
    let isAvailable: Bool
    let isConfigured: Bool
    let state: State
    let setup: Setup
    var id: String { name }
}

struct HermesMemoryProviderConfiguration: Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let value: String
        let label: String
        let description: String?
        var id: String { value }
    }

    struct Field: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case text
            case secret
            case select
            case toggle
            case number
            case integer
            case json
            case unsupported(String)
        }

        let key: String
        let label: String
        let kind: Kind
        let description: String?
        let placeholder: String?
        let isRequired: Bool
        let value: String
        let isSet: Bool
        let options: [Option]
        let minimum: Double?
        let maximum: Double?
        var id: String { key }
        var isSecret: Bool { kind == .secret }
        var isEditable: Bool {
            if case .unsupported = kind { return false }
            return true
        }
    }

    let provider: String
    let label: String
    let documentationURL: URL?
    let fields: [Field]
}

struct HermesMemoryOAuthStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case idle, pending, connected, error
    }

    let state: State
    let isConnected: Bool
    let authenticationKind: String?
}

struct HermesMemorySetupResult: Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let index: Int
        let kind: String
        let name: String
        let status: String
        var id: Int { index }
    }

    let provider: String
    let succeeded: Bool
    let steps: [Step]
    let currentProvider: HermesMemoryProvider?
}

enum HermesMemoryResetTarget: String, CaseIterable, Identifiable, Sendable {
    case all, memory, user
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All built-in memory"
        case .memory: "Learned memory"
        case .user: "User profile memory"
        }
    }
}

struct HermesCuratorStatus: Equatable, Sendable {
    let isEnabled: Bool
    let isPaused: Bool
    let intervalHours: Double?
    let minimumIdleHours: Double?
    let staleAfterDays: Double?
    let archiveAfterDays: Double?
    let lastRunAt: Date?
}

struct HermesCuratorRunReceipt: Equatable, Sendable {
    let processID: Int
    let actionName: String
    let actionID: String?
    let admittedAt: Date

    @MainActor
    func hostReceipt(using client: any HermesHostActionStatusClient) throws -> HermesHostActionReceipt {
        let slot = try client.receipt(forActionName: actionName)
        return .init(
            action: slot.action,
            processID: processID,
            actionID: actionID,
            archivePath: nil,
            admittedAt: admittedAt,
            admission: .launchAcknowledged
        )
    }
}

struct HermesLearningGraph: Equatable, Sendable {
    enum NodeKind: String, Equatable, Sendable { case skill, memory }

    struct Node: Identifiable, Equatable, Sendable {
        let rawID: String
        let label: String
        let kind: NodeKind
        let timestamp: Date?
        let category: String
        let useCount: Int
        let state: String
        let createdBy: String?
        let isPinned: Bool
        let memorySource: String?
        let memoryPreview: String?
        var id: Data { Data(rawID.utf8) }
    }

    struct Edge: Identifiable, Equatable, Sendable {
        let source: String
        let target: String
        var id: Data { Data(source.utf8) + Data([0]) + Data(target.utf8) }
    }

    struct Cluster: Identifiable, Equatable, Sendable {
        let category: String
        let count: Int
        var id: String { category }
    }

    struct Stats: Equatable, Sendable {
        let nodes: Int
        let relatedEdges: Int
        let linkedNodes: Int
        let isolatedPercent: Double
        let categories: Int
        let agentCreated: Int
        let used: Int
        let memoryNodes: Int
        let memorySkillEdges: Int
        let learnedSkills: Int
    }

    let nodes: [Node]
    let edges: [Edge]
    let clusters: [Cluster]
    let stats: Stats
}

struct HermesLearningNodeDetail: Equatable, Sendable {
    let rawID: String
    let kind: HermesLearningGraph.NodeKind
    let label: String
    let content: String
}

struct HermesLearningMutationReceipt: Equatable, Sendable {
    let message: String?
}

struct HermesInsights: Equatable, Sendable {
    let days: Int
    let sessions: Int
    let messages: Int
}

struct HermesLearningTimeline: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        let reveal: Double
        let date: String
        let visible: Int
    }

    struct LegendItem: Identifiable, Equatable, Sendable {
        let glyph: String
        let label: String
        let style: String?
        let color: String?
        var id: String { "\(glyph):\(label)" }
    }

    struct Node: Identifiable, Equatable, Sendable {
        let rawID: String
        let glyph: String
        let label: String
        let fullLabel: String
        let metadata: String
        let body: String
        let style: String
        var id: Data { Data(rawID.utf8) }
    }

    struct Bucket: Identifiable, Equatable, Sendable {
        let index: Int
        let label: String
        let date: String
        let skills: Int
        let memories: Int
        let total: Int
        let category: String?
        let color: String?
        let nodes: [Node]
        var id: Int { index }
    }

    let frames: [Frame]
    let legend: [LegendItem]
    let categories: [LegendItem]
    let buckets: [Bucket]
    let summary: [String]
    let axisStart: String
    let axisEnd: String
    let count: Int
    let columns: Int
    let rows: Int
}

@MainActor
final class DirectHermesMemoryClient {
    let actionStatusClient: (any HermesHostActionStatusClient)?

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let capturedOwner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.rpc = rpc
        self.http = http
        capturedOwner = owner
        self.currentOwner = currentOwner
        self.actionStatusClient = actionStatusClient
    }

    var owner: WorkspaceOwner? { currentOwner() == capturedOwner ? capturedOwner : nil }

    func memoryStatus() async throws -> HermesMemoryStatus {
        try await httpValue(.init(path: "/api/memory", method: .get), decode: MemoryContractDecoder.memoryStatus)
    }

    func setProvider(_ provider: String) async throws -> HermesMemoryStatus {
        let normalized = try Self.providerName(provider, allowsBuiltIn: true)
        let result = try await httpObject(.init(
            path: "/api/memory/provider", method: .put,
            body: ["provider": .string(normalized)]
        ))
        guard result["ok"]?.boolean == true,
              let active = result["active"]?.string,
              active.utf8.elementsEqual(normalized.utf8) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let status = try await memoryStatus()
        guard status.activeProvider.utf8.elementsEqual(normalized.utf8) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return status
    }

    func providerConfiguration(_ provider: String, profile: String?) async throws -> HermesMemoryProviderConfiguration {
        let provider = try Self.providerName(provider)
        let profile = try Self.profile(profile)
        return try await httpValue(.init(
            path: "/api/memory/providers/\(provider)/config", method: .get,
            query: profile.map { [.init(name: "profile", value: $0)] } ?? []
        )) { try MemoryContractDecoder.providerConfiguration($0, expectedProvider: provider) }
    }

    func saveProviderConfiguration(
        _ configuration: HermesMemoryProviderConfiguration,
        drafts: [String: String],
        profile: String?
    ) async throws -> HermesMemoryProviderConfiguration {
        let provider = try Self.providerName(configuration.provider)
        let profile = try Self.profile(profile)
        let values = try Self.providerValues(configuration: configuration, drafts: drafts)
        guard !values.isEmpty else { throw WorkspaceClientError.invalidRequest }
        let result = try await httpObject(.init(
            path: "/api/memory/providers/\(provider)/config", method: .put,
            query: profile.map { [.init(name: "profile", value: $0)] } ?? [],
            body: ["values": .object(values)]
        ))
        guard result["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        let readback = try await providerConfiguration(provider, profile: profile)
        try Self.confirmProviderValues(configuration: configuration, values: values, readback: readback)
        return readback
    }

    func setupProvider(_ provider: String) async throws -> HermesMemorySetupResult {
        let provider = try Self.providerName(provider)
        let result = try await httpValue(.init(
            path: "/api/memory/providers/\(provider)/setup", method: .post,
            body: ["values": .object([:])]
        )) { try MemoryContractDecoder.setupResult($0, expectedProvider: provider) }
        let status = try await memoryStatus()
        let current = status.providers.first { $0.name.utf8.elementsEqual(provider.utf8) }
        guard result.succeeded, current != nil else { throw WorkspaceClientError.outcomeUnknown }
        return .init(provider: result.provider, succeeded: result.succeeded, steps: result.steps, currentProvider: current)
    }

    func startProviderOAuth(_ provider: String, profile: String?) async throws -> HermesMemoryOAuthStatus {
        let provider = try Self.providerName(provider)
        let profile = try Self.profile(profile)
        _ = try await httpValue(.init(
            path: "/api/memory/providers/\(provider)/oauth/start", method: .post,
            query: profile.map { [.init(name: "profile", value: $0)] } ?? []
        ), decode: MemoryContractDecoder.oauthStatus)
        return try await providerOAuthStatus(provider, profile: profile)
    }

    func providerOAuthStatus(_ provider: String, profile: String?) async throws -> HermesMemoryOAuthStatus {
        let provider = try Self.providerName(provider)
        let profile = try Self.profile(profile)
        return try await httpValue(.init(
            path: "/api/memory/providers/\(provider)/oauth/status", method: .get,
            query: profile.map { [.init(name: "profile", value: $0)] } ?? []
        ), decode: MemoryContractDecoder.oauthStatus)
    }

    func reset(_ target: HermesMemoryResetTarget) async throws -> HermesMemoryStatus {
        let result = try await httpObject(.init(
            path: "/api/memory/reset", method: .post,
            body: ["target": .string(target.rawValue)]
        ))
        guard result["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        _ = try MemoryContractDecoder.strings(result["deleted"], maximum: 2, maximumBytes: 32)
        let status = try await memoryStatus()
        switch target {
        case .all:
            guard status.builtInFiles.memoryBytes == 0, status.builtInFiles.userBytes == 0 else {
                throw WorkspaceClientError.outcomeUnknown
            }
        case .memory:
            guard status.builtInFiles.memoryBytes == 0 else { throw WorkspaceClientError.outcomeUnknown }
        case .user:
            guard status.builtInFiles.userBytes == 0 else { throw WorkspaceClientError.outcomeUnknown }
        }
        return status
    }

    func curatorStatus() async throws -> HermesCuratorStatus {
        try await httpValue(.init(path: "/api/curator", method: .get), decode: MemoryContractDecoder.curatorStatus)
    }

    func setCuratorPaused(_ paused: Bool) async throws -> HermesCuratorStatus {
        let result = try await httpObject(.init(
            path: "/api/curator/paused", method: .put,
            body: ["paused": .boolean(paused)]
        ))
        guard result["ok"]?.boolean == true, result["paused"]?.boolean == paused else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let status = try await curatorStatus()
        guard status.isPaused == paused else { throw WorkspaceClientError.outcomeUnknown }
        return status
    }

    func runCurator() async throws -> HermesCuratorRunReceipt {
        try await httpValue(.init(path: "/api/curator/run", method: .post)) {
            let object = try MemoryContractDecoder.object($0)
            guard object["ok"]?.boolean == true,
                  let processID = object["pid"]?.integer, processID > 0,
                  let name = try? MemoryContractDecoder.text(object["name"], maximum: 80),
                  name == "curator-run" else { throw WorkspaceClientError.invalidResponse }
            let actionID = try MemoryContractDecoder.optionalText(object["action_id"], maximum: 128)
            return .init(processID: processID, actionName: name, actionID: actionID, admittedAt: Date())
        }
    }

    func learningGraph(profile: String?) async throws -> HermesLearningGraph {
        let profile = try Self.profile(profile)
        return try await httpValue(.init(
            path: "/api/learning/graph", method: .get,
            query: profile.map { [.init(name: "profile", value: $0)] } ?? [],
            maximumResponseBytes: 4 * 1_024 * 1_024
        ), decode: MemoryContractDecoder.learningGraph)
    }

    func learningNode(_ rawID: String, profile: String?) async throws -> HermesLearningNodeDetail {
        let rawID = try Self.nodeID(rawID)
        let profile = try Self.profile(profile)
        var query = [URLQueryItem(name: "id", value: rawID)]
        if let profile { query.append(.init(name: "profile", value: profile)) }
        return try await httpValue(.init(path: "/api/learning/node", method: .get, query: query)) {
            try MemoryContractDecoder.nodeDetail($0, expectedID: rawID)
        }
    }

    func updateLearningNode(
        _ detail: HermesLearningNodeDetail,
        content: String,
        profile: String?
    ) async throws -> HermesLearningNodeDetail {
        let rawID = try Self.nodeID(detail.rawID)
        let profile = try Self.profile(profile)
        let submitted = try MemoryContractDecoder.inputText(content, maximum: 512_000, empty: false)
        let content = detail.kind == .memory
            ? submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            : submitted
        let result = try await httpObject(.init(
            path: "/api/learning/node", method: .put,
            body: [
                "id": .string(rawID),
                "content": .string(content),
                "profile": profile.map(LoopdyJSONValue.string) ?? .null,
            ]
        ))
        _ = try MemoryContractDecoder.mutation(result)
        let readback = try await learningNode(rawID, profile: profile)
        guard readback.kind == detail.kind, readback.content.utf8.elementsEqual(content.utf8) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return readback
    }

    func deleteLearningNode(_ detail: HermesLearningNodeDetail, profile: String?) async throws -> HermesLearningGraph {
        let rawID = try Self.nodeID(detail.rawID)
        let profile = try Self.profile(profile)
        let before = try await learningGraph(profile: profile)
        guard before.nodes.contains(where: { $0.rawID.utf8.elementsEqual(rawID.utf8) }) else {
            throw WorkspaceClientError.conflict
        }
        let result = try await httpObject(.init(
            path: "/api/learning/node", method: .delete,
            body: [
                "id": .string(rawID),
                "profile": profile.map(LoopdyJSONValue.string) ?? .null,
            ]
        ))
        _ = try MemoryContractDecoder.mutation(result)
        let after = try await learningGraph(profile: profile)
        guard after.nodes.count == before.nodes.count - 1 else { throw WorkspaceClientError.outcomeUnknown }
        if detail.kind == .skill,
           after.nodes.contains(where: { $0.rawID.utf8.elementsEqual(rawID.utf8) }) {
            throw WorkspaceClientError.outcomeUnknown
        }
        return after
    }

    func insights(days: Int = 30, profile: String?) async throws -> HermesInsights {
        guard (1...3_650).contains(days) else { throw WorkspaceClientError.invalidRequest }
        let profile = try Self.profile(profile)
        var params: [String: LoopdyJSONValue] = ["days": .integer(days)]
        if let profile { params["profile"] = .string(profile) }
        return try await rpcValue("insights.get", params: params, decode: MemoryContractDecoder.insights)
    }

    /// This RPC projection is intentionally unscoped because the pinned contract has no
    /// `profile` parameter. Profile-specific screens use `/api/learning/graph` instead.
    func learningFrames(columns: Int = 52, rows: Int = 20, frames: Int = 24) async throws -> HermesLearningTimeline {
        guard (20...160).contains(columns), (8...80).contains(rows), (1...120).contains(frames) else {
            throw WorkspaceClientError.invalidRequest
        }
        return try await rpcValue("learning.frames", params: [
            "cols": .integer(columns), "rows": .integer(rows), "frames": .integer(frames),
        ], decode: MemoryContractDecoder.timeline)
    }

    func rpcLearningNode(_ rawID: String) async throws -> HermesLearningNodeDetail {
        let rawID = try Self.nodeID(rawID)
        return try await rpcValue("learning.detail", params: ["id": .string(rawID)]) {
            try MemoryContractDecoder.nodeDetail($0, expectedID: rawID)
        }
    }

    func rpcUpdateLearningNode(_ detail: HermesLearningNodeDetail, content: String) async throws -> HermesLearningNodeDetail {
        let rawID = try Self.nodeID(detail.rawID)
        let submitted = try MemoryContractDecoder.inputText(content, maximum: 512_000, empty: false)
        let content = detail.kind == .memory
            ? submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            : submitted
        let receipt = try await rpcValue("learning.edit", params: [
            "id": .string(rawID), "content": .string(content),
        ], decode: MemoryContractDecoder.mutation)
        _ = receipt
        let readback = try await rpcLearningNode(rawID)
        guard readback.kind == detail.kind, readback.content.utf8.elementsEqual(content.utf8) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return readback
    }

    func rpcDeleteLearningNode(_ detail: HermesLearningNodeDetail) async throws -> HermesLearningMutationReceipt {
        let rawID = try Self.nodeID(detail.rawID)
        let before = try await learningFrames()
        guard before.buckets.flatMap(\.nodes).contains(where: { $0.rawID.utf8.elementsEqual(rawID.utf8) }) else {
            throw WorkspaceClientError.conflict
        }
        let receipt = try await rpcValue(
            "learning.delete",
            params: ["id": .string(rawID)],
            decode: MemoryContractDecoder.mutation
        )
        let after = try await learningFrames()
        guard after.count == before.count - 1 else { throw WorkspaceClientError.outcomeUnknown }
        if detail.kind == .skill,
           after.buckets.flatMap(\.nodes).contains(where: { $0.rawID.utf8.elementsEqual(rawID.utf8) }) {
            throw WorkspaceClientError.outcomeUnknown
        }
        return receipt
    }

    private func httpObject(_ request: DirectHermesHTTPRequest) async throws -> [String: LoopdyJSONValue] {
        try await httpValue(request, decode: MemoryContractDecoder.object)
    }

    private func httpValue<T>(
        _ request: DirectHermesHTTPRequest,
        decode: (LoopdyJSONValue) throws -> T
    ) async throws -> T {
        try checkOwner()
        do {
            let value = try await http.request(request)
            try checkOwner()
            return try decode(value)
        } catch {
            try checkOwner()
            throw Self.safe(error)
        }
    }

    private func rpcValue<T>(
        _ method: String,
        params: [String: LoopdyJSONValue],
        decode: (LoopdyJSONValue) throws -> T
    ) async throws -> T {
        try checkOwner()
        do {
            let value = try await rpc.request(method, params: params)
            try checkOwner()
            return try decode(value)
        } catch {
            try checkOwner()
            throw Self.safe(error)
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == capturedOwner else { throw WorkspaceClientError.ownerChanged }
    }

    private static func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? WorkspaceClientError { return error }
        if let error = error as? WorkspaceManagementError { return error }
        return WorkspaceClientError.transportUnavailable
    }

    private static func providerName(_ value: String, allowsBuiltIn: Bool = false) throws -> String {
        let normalized = value == "built-in" && allowsBuiltIn ? "" : value
        if normalized.isEmpty, allowsBuiltIn { return "" }
        guard normalized.utf8.count <= 64,
              normalized.first?.isASCII == true,
              normalized.first?.isLetter == true || normalized.first?.isNumber == true,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return normalized
    }

    private static func profile(_ value: String?) throws -> String? {
        guard let value else { return nil }
        return try DirectHermesCoreRequestScope.profile(value)
    }

    private static func nodeID(_ value: String) throws -> String {
        try MemoryContractDecoder.inputText(value, maximum: 512, empty: false)
    }

    private static func providerValues(
        configuration: HermesMemoryProviderConfiguration,
        drafts: [String: String]
    ) throws -> [String: LoopdyJSONValue] {
        var values: [String: LoopdyJSONValue] = [:]
        for field in configuration.fields where field.isEditable {
            guard let draft = drafts[field.key] else { continue }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isRequired, !field.isSecret, trimmed.isEmpty { throw WorkspaceClientError.invalidRequest }
            if field.isSecret, trimmed.isEmpty { continue }
            switch field.kind {
            case .secret, .text, .select:
                if case .select = field.kind,
                   !field.options.contains(where: { $0.value.utf8.elementsEqual(trimmed.utf8) }) {
                    throw WorkspaceClientError.invalidRequest
                }
                values[field.key] = .string(trimmed)
            case .toggle:
                guard let flag = MemoryContractDecoder.boolString(trimmed) else { throw WorkspaceClientError.invalidRequest }
                values[field.key] = .boolean(flag)
            case .number, .integer:
                guard let number = Double(trimmed), number.isFinite,
                      field.minimum.map({ number >= $0 }) ?? true,
                      field.maximum.map({ number <= $0 }) ?? true else { throw WorkspaceClientError.invalidRequest }
                if case .integer = field.kind {
                    guard number.rounded() == number, number >= Double(Int.min), number <= Double(Int.max) else {
                        throw WorkspaceClientError.invalidRequest
                    }
                    values[field.key] = .integer(Int(number))
                } else {
                    values[field.key] = .number(number)
                }
            case .json:
                guard trimmed.utf8.count <= 64_000,
                      let data = trimmed.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(LoopdyJSONValue.self, from: data),
                      decoded.object != nil || decoded.array != nil else { throw WorkspaceClientError.invalidRequest }
                values[field.key] = decoded
            case .unsupported:
                continue
            }
        }
        return values
    }

    private static func confirmProviderValues(
        configuration: HermesMemoryProviderConfiguration,
        values: [String: LoopdyJSONValue],
        readback: HermesMemoryProviderConfiguration
    ) throws {
        guard readback.provider.utf8.elementsEqual(configuration.provider.utf8) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        for (key, submitted) in values {
            guard let original = configuration.fields.first(where: { $0.key == key }),
                  let current = readback.fields.first(where: { $0.key == key }) else {
                throw WorkspaceClientError.outcomeUnknown
            }
            if original.isSecret {
                guard current.isSet, current.value.isEmpty else { throw WorkspaceClientError.outcomeUnknown }
                continue
            }
            let encoded = try providerValues(configuration: readback, drafts: [key: current.value])[key]
            guard encoded == submitted else { throw WorkspaceClientError.outcomeUnknown }
        }
    }
}

private enum MemoryContractDecoder {
    static func object(_ value: LoopdyJSONValue) throws -> [String: LoopdyJSONValue] {
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        return object
    }

    static func text(_ value: LoopdyJSONValue?, maximum: Int, empty: Bool = false) throws -> String {
        guard let value = value?.string, value.utf8.count <= maximum,
              empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return value
    }

    static func optionalText(_ value: LoopdyJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        return try text(value, maximum: maximum, empty: true)
    }

    static func inputText(_ value: String, maximum: Int, empty: Bool) throws -> String {
        guard value.utf8.count <= maximum,
              empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    static func rows(_ value: LoopdyJSONValue?, maximum: Int) throws -> [LoopdyJSONValue] {
        guard let rows = value?.array, rows.count <= maximum else { throw WorkspaceClientError.invalidResponse }
        return rows
    }

    static func strings(_ value: LoopdyJSONValue?, maximum: Int, maximumBytes: Int) throws -> [String] {
        try rows(value, maximum: maximum).map { try text($0, maximum: maximumBytes) }
    }

    static func nonnegativeInteger(_ value: LoopdyJSONValue?) throws -> Int {
        guard let value = value?.integer, value >= 0 else { throw WorkspaceClientError.invalidResponse }
        return value
    }

    static func optionalNumber(_ value: LoopdyJSONValue?) throws -> Double? {
        guard let value, value != .null else { return nil }
        guard let number = value.number, number.isFinite, number >= 0 else { throw WorkspaceClientError.invalidResponse }
        return number
    }

    static func date(_ value: LoopdyJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        if let seconds = value.number {
            guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) else {
                throw WorkspaceClientError.invalidResponse
            }
            return Date(timeIntervalSince1970: seconds)
        }
        let string = try text(value, maximum: 80)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw WorkspaceClientError.invalidResponse }
        return date
    }

    static func memoryStatus(_ value: LoopdyJSONValue) throws -> HermesMemoryStatus {
        let payload = try object(value)
        let active = try text(payload["active"], maximum: 64, empty: true)
        let providers = try rows(payload["providers"], maximum: 100).map(provider)
        guard Set(providers.map(\.id)).count == providers.count else { throw WorkspaceClientError.invalidResponse }
        let files = try object(payload["builtin_files"] ?? .null)
        return .init(
            activeProvider: active,
            providers: providers,
            builtInFiles: .init(
                memoryBytes: try nonnegativeInteger(files["memory"]),
                userBytes: try nonnegativeInteger(files["user"])
            )
        )
    }

    static func provider(_ value: LoopdyJSONValue) throws -> HermesMemoryProvider {
        let row = try object(value)
        let name = try text(row["name"], maximum: 64)
        let rawStatus = try text(row["status"], maximum: 64)
        guard let available = row["available"]?.boolean, let configured = row["configured"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let setupRow = try object(row["setup"] ?? .null)
        guard let dependenciesInstalled = setupRow["dependencies_installed"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let externals = try rows(setupRow["external_dependencies"], maximum: 50).map { value -> String in
            let row = try object(value)
            return try text(row["name"], maximum: 160)
        }
        let state: HermesMemoryProvider.State = switch rawStatus {
        case "ready": .ready
        case "needs_config": .needsConfiguration
        case "missing": .missing
        case "unavailable": .unavailable
        default: .other(rawStatus)
        }
        return .init(
            name: name,
            description: try text(row["description"], maximum: 2_000, empty: true),
            isAvailable: available,
            isConfigured: configured,
            state: state,
            setup: .init(
                dependenciesInstalled: dependenciesInstalled,
                packageDependencies: try strings(setupRow["pip_dependencies"], maximum: 50, maximumBytes: 160),
                externalDependencyNames: externals,
                requiredEnvironmentKeys: try strings(setupRow["required_env"], maximum: 50, maximumBytes: 160)
            )
        )
    }

    static func providerConfiguration(
        _ value: LoopdyJSONValue,
        expectedProvider: String
    ) throws -> HermesMemoryProviderConfiguration {
        let payload = try object(value)
        let name = try text(payload["name"], maximum: 64)
        guard name.utf8.elementsEqual(expectedProvider.utf8) else { throw WorkspaceClientError.invalidResponse }
        let fields = try rows(payload["fields"], maximum: 100).map(providerField)
        guard Set(fields.map(\.id)).count == fields.count else { throw WorkspaceClientError.invalidResponse }
        var docsURL: URL?
        if let string = try optionalText(payload["docs_url"], maximum: 2_048), !string.isEmpty,
           let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil {
            docsURL = url
        }
        return .init(
            provider: name,
            label: try text(payload["label"], maximum: 160),
            documentationURL: docsURL,
            fields: fields
        )
    }

    static func providerField(_ value: LoopdyJSONValue) throws -> HermesMemoryProviderConfiguration.Field {
        let row = try object(value)
        let key = try text(row["key"], maximum: 128)
        guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else {
            throw WorkspaceClientError.invalidResponse
        }
        let rawKind = try text(row["kind"], maximum: 32).lowercased()
        let kind: HermesMemoryProviderConfiguration.Field.Kind = switch rawKind {
        case "text", "url": .text
        case "secret", "password": .secret
        case "select": .select
        case "bool", "boolean": .toggle
        case "number": .number
        case "integer": .integer
        case "json": .json
        default: .unsupported(rawKind)
        }
        let options = try rows(row["options"], maximum: 100).map { value -> HermesMemoryProviderConfiguration.Option in
            if let raw = value.string { return .init(value: raw, label: raw, description: nil) }
            let option = try object(value)
            let raw = try text(option["value"], maximum: 256)
            return .init(
                value: raw,
                label: (try optionalText(option["label"], maximum: 256)).flatMap { $0.isEmpty ? nil : $0 } ?? raw,
                description: try optionalText(option["description"], maximum: 1_000)
            )
        }
        guard Set(options.map(\.id)).count == options.count else { throw WorkspaceClientError.invalidResponse }
        let isSet = row["is_set"]?.boolean ?? false
        let required = row["required"]?.boolean ?? false
        return .init(
            key: key,
            label: try text(row["label"], maximum: 256),
            kind: kind,
            description: try optionalText(row["description"], maximum: 2_000),
            placeholder: try optionalText(row["placeholder"], maximum: 1_000),
            isRequired: required,
            value: try text(row["value"], maximum: 64_000, empty: true),
            isSet: isSet,
            options: options,
            minimum: try optionalNumber(row["minimum"]),
            maximum: try optionalNumber(row["maximum"])
        )
    }

    static func boolString(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }
    }

    static func setupResult(_ value: LoopdyJSONValue, expectedProvider: String) throws -> HermesMemorySetupResult {
        let payload = try object(value)
        let provider = try text(payload["provider"], maximum: 64)
        guard provider.utf8.elementsEqual(expectedProvider.utf8), let succeeded = payload["ok"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let steps = try rows(payload["results"], maximum: 100).enumerated().map { index, value -> HermesMemorySetupResult.Step in
            let row = try object(value)
            return .init(
                index: index,
                kind: try text(row["kind"], maximum: 80),
                name: try text(row["name"], maximum: 256),
                status: try text(row["status"], maximum: 80)
            )
        }
        return .init(provider: provider, succeeded: succeeded, steps: steps, currentProvider: nil)
    }

    static func oauthStatus(_ value: LoopdyJSONValue) throws -> HermesMemoryOAuthStatus {
        let payload = try object(value)
        let raw = try text(payload["state"], maximum: 32)
        guard let state = HermesMemoryOAuthStatus.State(rawValue: raw),
              let connected = payload["connected"]?.boolean else { throw WorkspaceClientError.invalidResponse }
        return .init(
            state: state,
            isConnected: connected,
            authenticationKind: try optionalText(payload["auth"], maximum: 80)
        )
    }

    static func curatorStatus(_ value: LoopdyJSONValue) throws -> HermesCuratorStatus {
        let payload = try object(value)
        guard let enabled = payload["enabled"]?.boolean, let paused = payload["paused"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            isEnabled: enabled,
            isPaused: paused,
            intervalHours: try optionalNumber(payload["interval_hours"]),
            minimumIdleHours: try optionalNumber(payload["min_idle_hours"]),
            staleAfterDays: try optionalNumber(payload["stale_after_days"]),
            archiveAfterDays: try optionalNumber(payload["archive_after_days"]),
            lastRunAt: try date(payload["last_run_at"])
        )
    }

    static func learningGraph(_ value: LoopdyJSONValue) throws -> HermesLearningGraph {
        let payload = try object(value)
        let memoryCards = try rows(payload["memory"], maximum: 2_000).map { value -> (String, String) in
            let row = try object(value)
            _ = try text(row["source"], maximum: 32)
            _ = try text(row["title"], maximum: 256, empty: true)
            return (
                try text(row["source"], maximum: 32),
                try text(row["body"], maximum: 1_200, empty: true)
            )
        }
        let nodes = try rows(payload["nodes"], maximum: 2_000).map { value -> HermesLearningGraph.Node in
            let row = try object(value)
            let rawID = try text(row["id"], maximum: 512)
            let rawKind = try text(row["kind"], maximum: 32)
            guard let kind = HermesLearningGraph.NodeKind(rawValue: rawKind),
                  let useCount = row["useCount"]?.integer, useCount >= 0,
                  let pinned = row["pinned"]?.boolean else { throw WorkspaceClientError.invalidResponse }
            let preview: String?
            if kind == .memory,
               rawID.hasPrefix("memory:"),
               let index = Int(rawID.split(separator: ":").last ?? ""),
               memoryCards.indices.contains(index) {
                preview = memoryCards[index].1
            } else {
                preview = nil
            }
            return .init(
                rawID: rawID,
                label: try text(row["label"], maximum: 256, empty: true),
                kind: kind,
                timestamp: try date(row["timestamp"]),
                category: try text(row["category"], maximum: 128),
                useCount: useCount,
                state: try text(row["state"], maximum: 80),
                createdBy: try optionalText(row["createdBy"], maximum: 80),
                isPinned: pinned,
                memorySource: try optionalText(row["memorySource"], maximum: 32),
                memoryPreview: preview
            )
        }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw WorkspaceClientError.invalidResponse }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = try rows(payload["edges"], maximum: 10_000).map { value -> HermesLearningGraph.Edge in
            let row = try object(value)
            let source = try text(row["source"], maximum: 512)
            let target = try text(row["target"], maximum: 512)
            guard nodeIDs.contains(Data(source.utf8)), nodeIDs.contains(Data(target.utf8)) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .init(source: source, target: target)
        }
        guard Set(edges.map(\.id)).count == edges.count else { throw WorkspaceClientError.invalidResponse }
        let clusters = try rows(payload["clusters"], maximum: 200).map { value -> HermesLearningGraph.Cluster in
            let row = try object(value)
            return .init(
                category: try text(row["category"], maximum: 128),
                count: try nonnegativeInteger(row["count"])
            )
        }
        guard Set(clusters.map(\.id)).count == clusters.count else { throw WorkspaceClientError.invalidResponse }
        let stats = try object(payload["stats"] ?? .null)
        let isolated = try optionalNumber(stats["isolated_pct"])
        guard let isolated, isolated <= 100 else { throw WorkspaceClientError.invalidResponse }
        return .init(
            nodes: nodes,
            edges: edges,
            clusters: clusters,
            stats: .init(
                nodes: try nonnegativeInteger(stats["nodes"]),
                relatedEdges: try nonnegativeInteger(stats["related_edges"]),
                linkedNodes: try nonnegativeInteger(stats["linked_nodes"]),
                isolatedPercent: isolated,
                categories: try nonnegativeInteger(stats["categories"]),
                agentCreated: try nonnegativeInteger(stats["agent_created"]),
                used: try nonnegativeInteger(stats["used"]),
                memoryNodes: try nonnegativeInteger(stats["memory_nodes"]),
                memorySkillEdges: try nonnegativeInteger(stats["memory_skill_edges"]),
                learnedSkills: try nonnegativeInteger(stats["learned_skills"])
            )
        )
    }

    static func nodeDetail(_ value: LoopdyJSONValue, expectedID: String) throws -> HermesLearningNodeDetail {
        let payload = try object(value)
        guard payload["ok"]?.boolean == true else { throw WorkspaceClientError.rejected(code: "learning_node") }
        let rawID = try text(payload["id"], maximum: 512)
        let rawKind = try text(payload["kind"], maximum: 32)
        guard rawID.utf8.elementsEqual(expectedID.utf8),
              let kind = HermesLearningGraph.NodeKind(rawValue: rawKind) else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            rawID: rawID,
            kind: kind,
            label: try text(payload["label"], maximum: 256, empty: true),
            content: try text(payload["content"], maximum: 512_000, empty: true)
        )
    }

    static func mutation(_ value: LoopdyJSONValue) throws -> HermesLearningMutationReceipt {
        try mutation(try object(value))
    }

    static func mutation(_ payload: [String: LoopdyJSONValue]) throws -> HermesLearningMutationReceipt {
        guard let ok = payload["ok"]?.boolean else { throw WorkspaceClientError.invalidResponse }
        guard ok else { throw WorkspaceClientError.rejected(code: "learning_mutation") }
        return .init(message: try optionalText(payload["message"], maximum: 2_000))
    }

    static func insights(_ value: LoopdyJSONValue) throws -> HermesInsights {
        let payload = try object(value)
        let days = try nonnegativeInteger(payload["days"])
        guard days > 0 else { throw WorkspaceClientError.invalidResponse }
        return .init(
            days: days,
            sessions: try nonnegativeInteger(payload["sessions"]),
            messages: try nonnegativeInteger(payload["messages"])
        )
    }

    static func timeline(_ value: LoopdyJSONValue) throws -> HermesLearningTimeline {
        let payload = try object(value)
        let frames = try rows(payload["frames"], maximum: 120).map { value -> HermesLearningTimeline.Frame in
            let row = try object(value)
            guard let reveal = row["reveal"]?.number, reveal.isFinite, reveal >= 0,
                  let visible = row["visible"]?.integer, visible >= 0 else {
                throw WorkspaceClientError.invalidResponse
            }
            let grid = try rows(row["grid"], maximum: 100)
            for gridRow in grid { _ = try rows(gridRow, maximum: 400) }
            if let labels = row["labels"], labels != .null {
                for label in try rows(labels, maximum: 2_000) { _ = try object(label) }
            }
            return .init(reveal: reveal, date: try text(row["date"], maximum: 80), visible: visible)
        }
        let legend = try timelineLegend(payload["legend"])
        let categories = try timelineLegend(payload["categories"])
        let buckets = try rows(payload["buckets"], maximum: 2_000).map(timelineBucket)
        guard Set(buckets.map(\.id)).count == buckets.count else { throw WorkspaceClientError.invalidResponse }
        let axis = try object(payload["axis"] ?? .null)
        return .init(
            frames: frames,
            legend: legend,
            categories: categories,
            buckets: buckets,
            summary: try strings(payload["summary"], maximum: 100, maximumBytes: 2_000),
            axisStart: try text(axis["start"], maximum: 80),
            axisEnd: try text(axis["end"], maximum: 80),
            count: try nonnegativeInteger(payload["count"]),
            columns: try nonnegativeInteger(payload["cols"]),
            rows: try nonnegativeInteger(payload["rows"])
        )
    }

    static func timelineLegend(_ value: LoopdyJSONValue?) throws -> [HermesLearningTimeline.LegendItem] {
        let items = try rows(value, maximum: 200).map { value -> HermesLearningTimeline.LegendItem in
            let row = try object(value)
            return .init(
                glyph: try text(row["glyph"], maximum: 32),
                label: try text(row["label"], maximum: 256),
                style: try optionalText(row["style"], maximum: 80),
                color: try optionalText(row["color"], maximum: 32)
            )
        }
        guard Set(items.map(\.id)).count == items.count else { throw WorkspaceClientError.invalidResponse }
        return items
    }

    static func timelineBucket(_ value: LoopdyJSONValue) throws -> HermesLearningTimeline.Bucket {
        let row = try object(value)
        let nodes = try rows(row["nodes"], maximum: 2_000).map { value -> HermesLearningTimeline.Node in
            let node = try object(value)
            return .init(
                rawID: try text(node["id"], maximum: 512),
                glyph: try text(node["glyph"], maximum: 32),
                label: try text(node["label"], maximum: 256, empty: true),
                fullLabel: try text(node["fullLabel"], maximum: 512, empty: true),
                metadata: try text(node["meta"], maximum: 1_000, empty: true),
                body: try text(node["body"], maximum: 4_000, empty: true),
                style: try text(node["style"], maximum: 80)
            )
        }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw WorkspaceClientError.invalidResponse }
        return .init(
            index: try nonnegativeInteger(row["index"]),
            label: try text(row["label"], maximum: 256),
            date: try text(row["date"], maximum: 80),
            skills: try nonnegativeInteger(row["skills"]),
            memories: try nonnegativeInteger(row["memories"]),
            total: try nonnegativeInteger(row["total"]),
            category: try optionalText(row["category"], maximum: 128),
            color: try optionalText(row["color"], maximum: 32),
            nodes: nodes
        )
    }
}
