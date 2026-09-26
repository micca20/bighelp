import Foundation

struct HermesMessagingEnvironmentField: Identifiable, Equatable, Sendable {
    let key: String
    let label: String
    let description: String
    let help: String
    let documentationURL: URL?
    let isRequired: Bool
    let isSet: Bool
    let isSecret: Bool
    let isAdvanced: Bool

    var id: String { key }
}

struct HermesMessagingPlatform: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let documentationURL: URL?
    let isEnabled: Bool
    let isConfigured: Bool
    let isGatewayRunning: Bool
    let state: String
    let errorMessage: String?
    let ingressURL: URL?
    let environment: [HermesMessagingEnvironmentField]
}

struct HermesMessagingCatalog: Equatable, Sendable {
    let profileID: String
    let platforms: [HermesMessagingPlatform]
}

struct HermesMessagingPlatformTest: Equatable, Sendable {
    let platformID: String
    let succeeded: Bool
    let state: String
    let message: String
}

struct HermesTelegramOnboarding: Equatable, Sendable {
    let pairingID: String
    let status: String
    let suggestedUsername: String?
    let deepLink: URL?
    let qrPayload: String?
    let expiresAt: String
    let botUsername: String?
    let ownerUserID: String?
}

struct HermesWhatsAppOnboarding: Equatable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case bot
        case selfChat = "self-chat"
        var id: Self { self }
        var title: String { self == .bot ? "Bot" : "Self chat" }
    }

    let pairingID: String
    let status: String
    let mode: Mode
    let allowedUsers: String
    let qrPayload: String?
    let expiresAt: String
    let accountID: String?
    let accountName: String?
    let accountPhone: String?
    let errorMessage: String?
}

struct HermesMessagingOnboardingCompletion: Equatable, Sendable {
    let platform: HermesMessagingPlatform
    let needsRestart: Bool
    let restartStarted: Bool
}

@MainActor
protocol HermesMessagingManaging: AnyObject {
    func platforms(profileID: String) async throws -> HermesMessagingCatalog
    func updatePlatform(
        id: String,
        profileID: String,
        enabled: Bool?,
        replacements: [String: String],
        clear: [String]
    ) async throws -> HermesMessagingPlatform
    func testPlatform(id: String, profileID: String) async throws -> HermesMessagingPlatformTest

    func startTelegram(botName: String?) async throws -> HermesTelegramOnboarding
    func telegramStatus(pairingID: String) async throws -> HermesTelegramOnboarding
    func applyTelegram(
        pairingID: String,
        allowedUserIDs: [String],
        profileID: String
    ) async throws -> HermesMessagingOnboardingCompletion
    func cancelTelegram(pairingID: String) async throws

    func startWhatsApp(
        mode: HermesWhatsAppOnboarding.Mode,
        allowedUsers: String,
        profileID: String
    ) async throws -> HermesWhatsAppOnboarding
    func whatsAppStatus(pairingID: String) async throws -> HermesWhatsAppOnboarding
    func applyWhatsApp(
        pairingID: String,
        mode: HermesWhatsAppOnboarding.Mode,
        allowedUsers: String,
        profileID: String
    ) async throws -> HermesMessagingOnboardingCompletion
    func cancelWhatsApp(pairingID: String) async throws
}

/// Owner-bound native adapter for Hermes' fixed messaging control-plane routes.
/// Secret values only enter write bodies supplied by the active view. Catalog
/// decoding deliberately ignores `redacted_value` so credentials cannot enter a
/// retained model, log, cache, or UI label.
@MainActor
final class DirectHermesMessagingClient: HermesMessagingManaging {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func platforms(profileID: String) async throws -> HermesMessagingCatalog {
        let profile = try Self.profile(profileID)
        let value = try await request(.init(
            path: "/api/messaging/platforms",
            method: .get,
            query: [.init(name: "profile", value: profile)]
        ))
        guard let object = value.object,
              let values = object["platforms"]?.array,
              values.count <= 100 else { throw WorkspaceClientError.invalidResponse }
        var ids = Set<String>()
        let platforms = try values.map { value -> HermesMessagingPlatform in
            let platform = try Self.platform(value)
            guard ids.insert(platform.id).inserted else { throw WorkspaceClientError.invalidResponse }
            return platform
        }
        return HermesMessagingCatalog(profileID: profile, platforms: platforms)
    }

    func updatePlatform(
        id: String,
        profileID: String,
        enabled: Bool?,
        replacements: [String: String],
        clear: [String]
    ) async throws -> HermesMessagingPlatform {
        let profile = try Self.profile(profileID)
        let before = try await platforms(profileID: profile)
        let platform = try Self.exactPlatform(id, in: before.platforms)
        guard enabled != nil || !replacements.isEmpty || !clear.isEmpty,
              replacements.count <= 64, clear.count <= 64 else {
            throw WorkspaceClientError.invalidRequest
        }
        let knownKeys = Set(platform.environment.map(\.key))
        guard Set(replacements.keys).isSubset(of: knownKeys), Set(clear).isSubset(of: knownKeys),
              Set(replacements.keys).isDisjoint(with: Set(clear)), Set(clear).count == clear.count else {
            throw WorkspaceClientError.invalidRequest
        }
        for (key, value) in replacements {
            try Self.environmentKey(key)
            try Self.environmentValue(value)
        }
        var body: [String: LoopdyJSONValue] = [
            "profile": .string(profile),
            "env": .object(replacements.mapValues(LoopdyJSONValue.string)),
            "clear_env": .array(clear.map(LoopdyJSONValue.string))
        ]
        if let enabled { body["enabled"] = .boolean(enabled) }
        let receipt = try await request(.init(
            path: "/api/messaging/platforms/\(try Self.pathID(platform.id))",
            method: .put,
            body: body
        ))
        guard let result = receipt.object, result["ok"]?.boolean == true,
              Self.exact(result["platform"]?.string, platform.id) else {
            throw WorkspaceClientError.outcomeUnknown
        }

        let confirmedCatalog = try await platforms(profileID: profile)
        let readback = try Self.exactPlatform(platform.id, in: confirmedCatalog.platforms)
        if let enabled, readback.isEnabled != enabled { throw WorkspaceClientError.outcomeUnknown }
        for key in replacements.keys {
            guard readback.environment.first(where: { Self.exact($0.key, key) })?.isSet == true else {
                throw WorkspaceClientError.outcomeUnknown
            }
        }
        for key in clear {
            guard readback.environment.first(where: { Self.exact($0.key, key) })?.isSet == false else {
                throw WorkspaceClientError.outcomeUnknown
            }
        }
        return readback
    }

    func testPlatform(id: String, profileID: String) async throws -> HermesMessagingPlatformTest {
        let profile = try Self.profile(profileID)
        let catalog = try await platforms(profileID: profile)
        let platform = try Self.exactPlatform(id, in: catalog.platforms)
        let value = try await request(.init(
            path: "/api/messaging/platforms/\(try Self.pathID(platform.id))/test",
            method: .post,
            query: [.init(name: "profile", value: profile)],
            body: [:]
        ))
        guard let object = value.object, let ok = object["ok"]?.boolean,
              let state = Self.optionalText(object["state"], maximum: 128),
              let message = Self.optionalText(object["message"], maximum: 8_192),
              !message.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return .init(platformID: platform.id, succeeded: ok, state: state, message: message)
    }

    func startTelegram(botName: String?) async throws -> HermesTelegramOnboarding {
        var body: [String: LoopdyJSONValue] = [:]
        if let botName {
            let value = botName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 200 else { throw WorkspaceClientError.invalidRequest }
            body["bot_name"] = .string(value)
        }
        let value = try await request(.init(
            path: "/api/messaging/telegram/onboarding/start", method: .post, body: body
        ))
        let started = try Self.telegram(value, pairingID: nil)
        let status = try await telegramStatus(pairingID: started.pairingID)
        return .init(
            pairingID: status.pairingID, status: status.status,
            suggestedUsername: started.suggestedUsername,
            deepLink: started.deepLink, qrPayload: started.qrPayload,
            expiresAt: status.expiresAt.isEmpty ? started.expiresAt : status.expiresAt,
            botUsername: status.botUsername, ownerUserID: status.ownerUserID
        )
    }

    func telegramStatus(pairingID: String) async throws -> HermesTelegramOnboarding {
        let id = try Self.pathID(pairingID)
        return try Self.telegram(await request(.init(
            path: "/api/messaging/telegram/onboarding/\(id)", method: .get
        )), pairingID: id)
    }

    func applyTelegram(
        pairingID: String,
        allowedUserIDs: [String],
        profileID: String
    ) async throws -> HermesMessagingOnboardingCompletion {
        let id = try Self.pathID(pairingID)
        let profile = try Self.profile(profileID)
        guard !allowedUserIDs.isEmpty, allowedUserIDs.count <= 100 else {
            throw WorkspaceClientError.invalidRequest
        }
        var seen = Set<String>()
        for userID in allowedUserIDs {
            guard !userID.isEmpty, userID.utf8.count <= 64,
                  userID.utf8.allSatisfy({ (48...57).contains($0) }),
                  seen.insert(userID).inserted else { throw WorkspaceClientError.invalidRequest }
        }
        let value = try await request(.init(
            path: "/api/messaging/telegram/onboarding/\(id)/apply",
            method: .post,
            body: [
                "allowed_user_ids": .array(allowedUserIDs.map(LoopdyJSONValue.string)),
                "profile": .string(profile)
            ]
        ))
        return try await confirmedCompletion(value, platformID: "telegram", profileID: profile)
    }

    func cancelTelegram(pairingID: String) async throws {
        try await cancelOnboarding(platform: "telegram", pairingID: pairingID)
    }

    func startWhatsApp(
        mode: HermesWhatsAppOnboarding.Mode,
        allowedUsers: String,
        profileID: String
    ) async throws -> HermesWhatsAppOnboarding {
        let profile = try Self.profile(profileID)
        let users = try Self.allowedUsers(allowedUsers)
        let value = try await request(.init(
            path: "/api/messaging/whatsapp/onboarding/start",
            method: .post,
            body: [
                "mode": .string(mode.rawValue), "allowed_users": .string(users),
                "profile": .string(profile)
            ]
        ))
        let started = try Self.whatsApp(value, pairingID: nil)
        return try await whatsAppStatus(pairingID: started.pairingID)
    }

    func whatsAppStatus(pairingID: String) async throws -> HermesWhatsAppOnboarding {
        let id = try Self.pathID(pairingID)
        return try Self.whatsApp(await request(.init(
            path: "/api/messaging/whatsapp/onboarding/\(id)", method: .get
        )), pairingID: id)
    }

    func applyWhatsApp(
        pairingID: String,
        mode: HermesWhatsAppOnboarding.Mode,
        allowedUsers: String,
        profileID: String
    ) async throws -> HermesMessagingOnboardingCompletion {
        let id = try Self.pathID(pairingID)
        let profile = try Self.profile(profileID)
        let users = try Self.allowedUsers(allowedUsers)
        let value = try await request(.init(
            path: "/api/messaging/whatsapp/onboarding/\(id)/apply",
            method: .post,
            query: [.init(name: "profile", value: profile)],
            body: [
                "mode": .string(mode.rawValue), "allowed_users": .string(users),
                "profile": .string(profile)
            ]
        ))
        return try await confirmedCompletion(value, platformID: "whatsapp", profileID: profile)
    }

    func cancelWhatsApp(pairingID: String) async throws {
        try await cancelOnboarding(platform: "whatsapp", pairingID: pairingID)
    }

    private func confirmedCompletion(
        _ value: LoopdyJSONValue,
        platformID: String,
        profileID: String
    ) async throws -> HermesMessagingOnboardingCompletion {
        guard let object = value.object, object["ok"]?.boolean == true,
              Self.exact(object["platform"]?.string, platformID) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let confirmedCatalog = try await platforms(profileID: profileID)
        let platform = try Self.exactPlatform(platformID, in: confirmedCatalog.platforms)
        guard platform.isEnabled, platform.isConfigured else { throw WorkspaceClientError.outcomeUnknown }
        return .init(
            platform: platform,
            needsRestart: object["needs_restart"]?.boolean ?? false,
            restartStarted: object["restart_started"]?.boolean ?? false
        )
    }

    private func cancelOnboarding(platform: String, pairingID: String) async throws {
        let id = try Self.pathID(pairingID)
        let value = try await request(.init(
            path: "/api/messaging/\(platform)/onboarding/\(id)", method: .delete
        ))
        guard value.object?["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        do {
            _ = try await request(.init(path: "/api/messaging/\(platform)/onboarding/\(id)", method: .get))
            throw WorkspaceClientError.outcomeUnknown
        } catch DirectHermesError.unsupportedAuthentication {
            // The authenticated HTTP seam maps an exact 404 status to this legacy
            // transport error. Any network/5xx/decoding error still propagates.
        }
    }

    private func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner) {
            try await http.request(request)
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        _ = rpc // Retain the same authenticated socket/event lifetime as the HTTP client.
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private static func platform(_ value: LoopdyJSONValue) throws -> HermesMessagingPlatform {
        guard let row = value.object,
              let id = optionalText(row["id"], maximum: 128),
              let name = optionalText(row["name"], maximum: 200),
              let description = optionalText(row["description"], maximum: 8_192),
              let enabled = row["enabled"]?.boolean,
              let configured = row["configured"]?.boolean,
              let running = row["gateway_running"]?.boolean,
              let fields = row["env_vars"]?.array,
              fields.count <= 128 else { throw WorkspaceClientError.invalidResponse }
        _ = try pathID(id)
        var keys = Set<String>()
        let environment = try fields.map { value -> HermesMessagingEnvironmentField in
            guard let field = value.object,
                  let key = optionalText(field["key"], maximum: 128),
                  let required = field["required"]?.boolean,
                  let isSet = field["is_set"]?.boolean,
                  let secret = field["is_password"]?.boolean,
                  let advanced = field["advanced"]?.boolean,
                  keys.insert(key).inserted else { throw WorkspaceClientError.invalidResponse }
            try environmentKey(key)
            return .init(
                key: key,
                label: optionalText(field["prompt"], maximum: 200) ?? key,
                description: optionalText(field["description"], maximum: 4_096) ?? "",
                help: optionalText(field["help"], maximum: 4_096) ?? "",
                documentationURL: try optionalHTTPSURL(field["url"]),
                isRequired: required, isSet: isSet, isSecret: secret, isAdvanced: advanced
            )
        }
        return .init(
            id: id, name: name, description: description,
            documentationURL: try optionalHTTPSURL(row["docs_url"]),
            isEnabled: enabled, isConfigured: configured, isGatewayRunning: running,
            state: optionalText(row["state"], maximum: 128) ?? "unknown",
            errorMessage: optionalText(row["error_message"], maximum: 8_192),
            ingressURL: try optionalWebURL(row["ingress_url"]),
            environment: environment
        )
    }

    private static func telegram(_ value: LoopdyJSONValue, pairingID: String?) throws -> HermesTelegramOnboarding {
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        let id = try pathID(pairingID ?? optionalText(object["pairing_id"], maximum: 128) ?? "")
        let status = optionalText(object["status"], maximum: 64) ?? "waiting"
        guard ["waiting", "ready"].contains(status) else { throw WorkspaceClientError.invalidResponse }
        let deepLink = try optionalHTTPSURL(object["deep_link"])
        if let deepLink, !["t.me", "telegram.me"].contains(deepLink.host?.lowercased() ?? "") {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            pairingID: id, status: status,
            suggestedUsername: optionalText(object["suggested_username"], maximum: 200),
            deepLink: deepLink,
            qrPayload: optionalText(object["qr_payload"], maximum: 16_384),
            expiresAt: optionalText(object["expires_at"], maximum: 128) ?? "",
            botUsername: optionalText(object["bot_username"], maximum: 200),
            ownerUserID: optionalText(object["owner_user_id"], maximum: 128)
        )
    }

    private static func whatsApp(_ value: LoopdyJSONValue, pairingID: String?) throws -> HermesWhatsAppOnboarding {
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        let id = try pathID(pairingID ?? optionalText(object["pairing_id"], maximum: 128) ?? "")
        guard let status = optionalText(object["status"], maximum: 64),
              ["installing", "starting", "waiting", "connected", "error", "expired", "cancelled"].contains(status),
              let modeValue = optionalText(object["mode"], maximum: 32),
              let mode = HermesWhatsAppOnboarding.Mode(rawValue: modeValue) else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            pairingID: id, status: status, mode: mode,
            allowedUsers: optionalText(object["allowed_users"], maximum: 8_192) ?? "",
            qrPayload: optionalText(object["qr_payload"], maximum: 65_536),
            expiresAt: optionalText(object["expires_at"], maximum: 128) ?? "",
            accountID: optionalText(object["account_id"], maximum: 512),
            accountName: optionalText(object["account_name"], maximum: 512),
            accountPhone: optionalText(object["account_phone"], maximum: 128),
            errorMessage: optionalText(object["error"], maximum: 8_192)
        )
    }

    private static func exactPlatform(
        _ id: String,
        in platforms: [HermesMessagingPlatform]
    ) throws -> HermesMessagingPlatform {
        let matches = platforms.filter { exact($0.id, id) }
        guard matches.count == 1, let platform = matches.first else {
            throw WorkspaceClientError.conflict
        }
        return platform
    }

    private static func profile(_ value: String) throws -> String {
        try DirectHermesCoreRequestScope.profile(value)
    }

    private static func pathID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func environmentKey(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value.first?.isNumber == false,
              value.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    private static func environmentValue(_ value: String) throws {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    private static func allowedUsers(_ value: String) throws -> String {
        let normalized = value.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "") }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        guard normalized.utf8.count <= 8_192,
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return normalized
    }

    private static func optionalText(_ value: LoopdyJSONValue?, maximum: Int) -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.string, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    private static func optionalHTTPSURL(_ value: LoopdyJSONValue?) throws -> URL? {
        guard let text = optionalText(value, maximum: 4_096), !text.isEmpty else { return nil }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.host?.isEmpty == false,
              let url = components.url else { throw WorkspaceClientError.invalidResponse }
        return url
    }

    private static func optionalWebURL(_ value: LoopdyJSONValue?) throws -> URL? {
        guard let text = optionalText(value, maximum: 4_096), !text.isEmpty else { return nil }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.user == nil, components.password == nil,
              components.host?.isEmpty == false,
              let url = components.url else { throw WorkspaceClientError.invalidResponse }
        return url
    }

    private static func exact(_ lhs: String?, _ rhs: String) -> Bool {
        lhs?.utf8.elementsEqual(rhs.utf8) == true
    }
}
