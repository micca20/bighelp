import CryptoKit
import Foundation

@MainActor
final class DirectHermesAgentTemplateClient: AgentProfileTemplateClient {
    private static let feature = "native-agent-templates-v1"
    private static let maximumPayloadBytes = 1_048_576

    private let http: any DirectHermesNativeHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private lazy var native = DirectHermesNativePluginClient(
        http: http, owner: owner, currentOwner: currentOwner
    )

    init(http: any DirectHermesNativeHTTP, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func list(profileID: String, owner expectedOwner: WorkspaceOwner) async throws -> AgentTemplateCatalog {
        let profile = try checkedProfile(profileID, owner: expectedOwner)
        let response = try await request("list", body: ["agentId": .string(profile)], mutation: false)
        guard response["agentId"]?.string == profile,
              let folder = response["storageFolder"]?.string,
              folder == Self.storageFolder(profile),
              let rows = response["templates"]?.array, rows.count <= 256 else {
            throw WorkspaceClientError.invalidResponse
        }
        try Self.safeText(folder, maximumBytes: 256)
        var ids = Set<String>()
        let templates = try rows.map { value -> AgentTemplateSummary in
            guard let row = value.object,
                  let id = row["id"]?.string,
                  let title = row["title"]?.string,
                  let revision = row["revision"]?.string,
                  let timestamp = row["derivedAt"]?.integer,
                  let omissions = row["omissionCount"]?.integer,
                  ids.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            try Self.templateID(id)
            try Self.revision(revision)
            try Self.safeText(title, maximumBytes: 480)
            guard timestamp > 0, timestamp <= 9_999_999_999,
                  omissions >= 0, omissions <= 256 else { throw WorkspaceClientError.invalidResponse }
            return AgentTemplateSummary(
                id: id, title: title, revision: revision,
                derivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                omissionCount: omissions
            )
        }
        return AgentTemplateCatalog(profileID: profile, storageFolder: folder, templates: templates)
    }

    func derive(profileID: String, templateID: UUID,
                owner expectedOwner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        let profile = try checkedProfile(profileID, owner: expectedOwner)
        let id = templateID.uuidString.lowercased()
        let response = try await request("derive", body: [
            "agentId": .string(profile), "templateId": .string(id),
        ], mutation: false)
        guard response["agentId"]?.string == profile, response["revision"] == .null,
              let template = response["template"]?.object else {
            throw WorkspaceClientError.invalidResponse
        }
        return try decode(template, revision: nil, expectedProfile: profile, expectedID: id)
    }

    func read(profileID: String, templateID: String,
              owner expectedOwner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        let profile = try checkedProfile(profileID, owner: expectedOwner)
        try Self.templateID(templateID)
        let response = try await request("read", body: [
            "agentId": .string(profile), "templateId": .string(templateID),
        ], mutation: false)
        guard response["agentId"]?.string == profile,
              response["storageFolder"]?.string == Self.storageFolder(profile),
              let revision = response["revision"]?.string,
              let template = response["template"]?.object else {
            throw WorkspaceClientError.invalidResponse
        }
        try Self.revision(revision)
        return try decode(template, revision: revision, expectedProfile: profile, expectedID: templateID)
    }

    func save(_ document: AgentTemplateDocument, profileID: String,
              expectedRevision: String?, owner expectedOwner: WorkspaceOwner) async throws -> AgentTemplateDocument {
        let profile = try checkedProfile(profileID, owner: expectedOwner)
        guard document.sourceProfileID == profile else { throw WorkspaceClientError.invalidRequest }
        try Self.templateID(document.id)
        if let expectedRevision { try Self.revision(expectedRevision) }
        let body: [String: LoopdyJSONValue] = [
            "agentId": .string(profile),
            "template": .object(try encode(document)),
            "expectedRevision": expectedRevision.map(LoopdyJSONValue.string) ?? .null,
        ]
        do {
            let response = try await request("save", body: body, mutation: true)
            guard response["agentId"]?.string == profile,
                  response["storageFolder"]?.string == Self.storageFolder(profile),
                  let revision = response["revision"]?.string,
                  let template = response["template"]?.object else {
                throw WorkspaceClientError.outcomeUnknown
            }
            try Self.revision(revision)
            let saved = try decode(template, revision: revision, expectedProfile: profile, expectedID: document.id)
            guard Self.sameEditableContent(saved, document) else { throw WorkspaceClientError.outcomeUnknown }
            return saved
        } catch WorkspaceClientError.outcomeUnknown {
            // A lost POST result is reconciled by exact authenticated readback.
            // A different or absent document is not proof that the write failed.
            if let recovered = try? await read(
                profileID: profile, templateID: document.id, owner: expectedOwner
            ), Self.sameEditableContent(recovered, document) {
                return recovered
            }
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    private func request(_ operation: String, body: [String: LoopdyJSONValue],
                         mutation: Bool) async throws -> [String: LoopdyJSONValue] {
        try check(owner)
        let value = LoopdyJSONValue.object(body)
        try DirectHermesWire.validateValueSize(value, limit: Self.maximumPayloadBytes)
        guard try JSONEncoder().encode(value).count <= Self.maximumPayloadBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        let context = try await native.loadContext()
        guard context.owner == owner, context.features.contains(Self.feature) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let guardValue = try DirectHermesNativeRequestGuard(etag: context.etag)
        let request = DirectHermesHTTPRequest(
            path: "/api/plugins/loopdy/native/agent-templates/" + operation,
            method: .post,
            body: body,
            maximumResponseBytes: Self.maximumPayloadBytes
        )
        let response: DirectHermesHTTP.Response
        do {
            response = try await http.nativeResponse(request, requestGuard: guardValue)
            try check(owner)
        } catch {
            try check(owner)
            if mutation { throw WorkspaceClientError.outcomeUnknown }
            throw error
        }
        let echoedID = response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID")
        if let echoedID, echoedID != guardValue.requestIDHeader {
            throw mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse
        }
        guard (200...299).contains(response.http.statusCode) else {
            if [401, 403, 412, 428].contains(response.http.statusCode) {
                _ = try? await native.loadContext(force: true)
            }
            throw responseError(response, mutation: mutation)
        }
        guard echoedID == guardValue.requestIDHeader,
              response.http.value(forHTTPHeaderField: "ETag") == guardValue.etag else {
            throw mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse
        }
        do { return try response.object() }
        catch { throw mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse }
    }

    private func decode(_ raw: [String: LoopdyJSONValue], revision: String?,
                        expectedProfile: String, expectedID: String) throws -> AgentTemplateDocument {
        let keys: Set<String> = [
            "schemaVersion", "id", "title", "source", "soul", "skills",
            "mcpServers", "tools", "config", "omissions",
        ]
        guard Set(raw.keys) == keys, raw["schemaVersion"]?.integer == 1,
              let id = raw["id"]?.string, id == expectedID,
              let title = raw["title"]?.string,
              let source = raw["source"]?.object,
              let soul = raw["soul"]?.string,
              let skills = raw["skills"], skills.array != nil,
              let mcp = raw["mcpServers"], mcp.array != nil,
              let tools = raw["tools"], tools.array != nil,
              let config = raw["config"], config.object != nil,
              let omissions = raw["omissions"]?.array,
              let sourceProfile = source["profileId"]?.string,
              sourceProfile == expectedProfile,
              let sourceRevision = source["snapshotRevision"]?.string,
              let timestamp = source["derivedAt"]?.integer,
              timestamp > 0, timestamp <= 9_999_999_999 else {
            throw WorkspaceClientError.invalidResponse
        }
        try Self.templateID(id)
        try Self.revision(sourceRevision)
        try Self.safeText(title, maximumBytes: 480)
        try Self.safeText(soul, maximumBytes: 256_000)
        guard omissions.count <= 256 else { throw WorkspaceClientError.capacityExceeded }
        let omissionStrings = try omissions.map { value -> String in
            guard let text = value.string else { throw WorkspaceClientError.invalidResponse }
            try Self.safeText(text, maximumBytes: 256)
            return text
        }
        return AgentTemplateDocument(
            id: id,
            title: title,
            sourceProfileID: sourceProfile,
            sourceSnapshotRevision: sourceRevision,
            derivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            soul: soul,
            skillsJSON: try Self.pretty(skills),
            mcpServersJSON: try Self.pretty(mcp),
            toolsJSON: try Self.pretty(tools),
            configJSON: try Self.pretty(config),
            omissions: omissionStrings,
            revision: revision
        )
    }

    private func encode(_ document: AgentTemplateDocument) throws -> [String: LoopdyJSONValue] {
        try Self.safeText(document.title, maximumBytes: 480)
        try Self.safeText(document.soul, maximumBytes: 256_000)
        try Self.revision(document.sourceSnapshotRevision)
        let skills = try Self.skills(document.skillsJSON)
        let mcp = try Self.json(document.mcpServersJSON, expected: .array)
        let tools = try Self.json(document.toolsJSON, expected: .array)
        let config = try Self.json(document.configJSON, expected: .object)
        return [
            "schemaVersion": .integer(1),
            "id": .string(document.id),
            "title": .string(document.title),
            "source": .object([
                "profileId": .string(document.sourceProfileID),
                "snapshotRevision": .string(document.sourceSnapshotRevision),
                "derivedAt": .integer(Int(document.derivedAt.timeIntervalSince1970)),
            ]),
            "soul": .string(document.soul),
            "skills": skills,
            "mcpServers": mcp,
            "tools": tools,
            "config": config,
            "omissions": .array(document.omissions.map(LoopdyJSONValue.string)),
        ]
    }

    private enum JSONShape { case array, object }

    /// Skill content is editable text; its integrity field is derived data, not
    /// a second value the user must keep synchronized by hand.
    private static func skills(_ text: String) throws -> LoopdyJSONValue {
        let value = try json(text, expected: .array)
        guard let rows = value.array, rows.count <= 128 else {
            throw WorkspaceClientError.capacityExceeded
        }
        return .array(try rows.map { value in
            guard var row = value.object,
                  Set(row.keys).isSubset(of: ["id", "enabled", "content", "sha256"]),
                  Set(["id", "enabled", "content"]).isSubset(of: row.keys),
                  let content = row["content"]?.string,
                  content.utf8.count <= 100_000 else {
                throw WorkspaceClientError.invalidRequest
            }
            row["sha256"] = .string(SHA256.hash(data: Data(content.utf8)).map {
                String(format: "%02x", $0)
            }.joined())
            return .object(row)
        })
    }

    private static func json(_ text: String, expected: JSONShape) throws -> LoopdyJSONValue {
        guard text.utf8.count <= maximumPayloadBytes,
              let data = text.data(using: .utf8), data.count <= maximumPayloadBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        let value: LoopdyJSONValue
        do { value = try JSONDecoder().decode(LoopdyJSONValue.self, from: data) }
        catch { throw WorkspaceClientError.invalidRequest }
        switch (expected, value) {
        case (.array, .array), (.object, .object): return value
        default: throw WorkspaceClientError.invalidRequest
        }
    }

    private static func pretty(_ value: LoopdyJSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceClientError.capacityExceeded
        }
        return text
    }

    private static func sameEditableContent(_ lhs: AgentTemplateDocument,
                                            _ rhs: AgentTemplateDocument) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.sourceProfileID == rhs.sourceProfileID
            && lhs.sourceSnapshotRevision == rhs.sourceSnapshotRevision
            && Int(lhs.derivedAt.timeIntervalSince1970) == Int(rhs.derivedAt.timeIntervalSince1970)
            && lhs.soul == rhs.soul
            && (try? skills(lhs.skillsJSON)) == (try? skills(rhs.skillsJSON))
            && (try? json(lhs.mcpServersJSON, expected: .array)) == (try? json(rhs.mcpServersJSON, expected: .array))
            && (try? json(lhs.toolsJSON, expected: .array)) == (try? json(rhs.toolsJSON, expected: .array))
            && (try? json(lhs.configJSON, expected: .object)) == (try? json(rhs.configJSON, expected: .object))
            && lhs.omissions == rhs.omissions
    }

    private func checkedProfile(_ value: String, owner expectedOwner: WorkspaceOwner) throws -> String {
        try check(expectedOwner)
        guard !value.isEmpty, value.utf8.count <= 64,
              value.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func check(_ expectedOwner: WorkspaceOwner) throws {
        try Task.checkCancellation()
        guard expectedOwner == owner, currentOwner() == owner,
              owner.authority.kind == .direct else { throw WorkspaceClientError.ownerChanged }
    }

    private static func templateID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            throw WorkspaceClientError.invalidResponse
        }
    }

    private static func storageFolder(_ profile: String) -> String {
        ".loopdy/agent-templates/" + profile
    }

    private static func revision(_ value: String) throws {
        guard value.utf8.count == 71, value.hasPrefix("sha256:"),
              value.dropFirst(7).utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { throw WorkspaceClientError.invalidResponse }
    }

    private static func safeText(_ value: String, maximumBytes: Int) throws {
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(
                    CharacterSet(charactersIn: "\n\r\t")
                  ).contains($0)
              }) else { throw WorkspaceClientError.capacityExceeded }
    }

    private func responseError(_ response: DirectHermesHTTP.Response,
                               mutation: Bool) -> WorkspaceClientError {
        switch response.http.statusCode {
        case 401, 403: return .authenticationRequired
        case 409, 412: return .conflict
        case 413: return .capacityExceeded
        case 428, 501: return .unavailable(.unsupportedOperation)
        case 500...599: return mutation ? .outcomeUnknown : .transportUnavailable
        default: break
        }
        let code = (try? response.object())?["error"]?.object?["code"]?.string
        if let code, !code.isEmpty, code.utf8.count <= 128 {
            return .rejected(code: code)
        }
        return response.http.statusCode == 404
            ? .unavailable(.pluginRequired) : .invalidResponse
    }
}
