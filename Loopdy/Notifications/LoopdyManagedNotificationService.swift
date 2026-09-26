import Foundation

struct LoopdyManagedNotificationSetupError: Error, LocalizedError, Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case providerBootstrap
        case providerIdentity
        case notificationPermission
        case deviceRegistration
        case providerReadiness
    }

    let stage: Stage
    let code: String?

    init(stage: Stage, code: String? = nil) {
        self.stage = stage
        self.code = code
    }

    /// The diagnostic code is appended when present so a failing stage names
    /// its failure mode in user-visible messages and logs.
    var errorDescription: String? {
        let base: String = switch stage {
        case .providerBootstrap:
            "Notification setup is unavailable. Update bighelp and try again."
        case .providerIdentity:
            "Notification setup failed. Try again."
        case .notificationPermission:
            "Allow notifications for bighelp in Settings, then try again."
        case .deviceRegistration:
            "bighelp could not register this device for notifications. Check notification access and try again."
        case .providerReadiness:
            "The notification provider has not confirmed this device yet. Try again."
        }
        if let code { return "\(base) (code: \(code))" }
        return base
    }
}

@MainActor
protocol LoopdyManagedNotificationProvider: AnyObject {
    func identify(accountAPI: any LoopdyManagedNotificationAccountAPI, credentials: LoopdyManagedNotificationCredentials) async throws
    func registerCurrentDevice() async throws
    func refreshProviderReadiness(
        accountAPI: any LoopdyManagedNotificationAccountAPI,
        credentials: LoopdyManagedNotificationCredentials,
        requiringCurrentRegistration: Bool
    ) async throws -> LoopdyBuzzKitProviderReadiness
    func retireIdentityForLocalErasure() async
}
extension LoopdyBuzzKitRuntime: LoopdyManagedNotificationProvider {}

@MainActor
final class LoopdyManagedNotificationService: HostNotificationSetupServing {
    typealias HostClientFactory = @MainActor (LoopdyConfiguredHost) throws -> any DirectHostNotificationServing
    private let buzzKit: any LoopdyManagedNotificationProvider
    private let identity: LoopdyNotificationIdentityCoordinator
    private let api: any LoopdyManagedNotificationAccountAPI
    private let requestPermission: @MainActor () async throws -> Bool
    let registry: LoopdyHostRegistry
    let ledger: LoopdyManagedNotificationLedger
    let activityKeys: LoopdyManagedActivityKeychain

    private let hostClient: HostClientFactory
    private let now: () -> Date
    private var enrolling = Set<String>()
    private var revocationInFlight = false
    private var opening: UUID?
    private var retiredHosts = Set<String>()
    var activityRuntime: LoopdyManagedNativeActivityRuntime?

    /// Main's exact admitted projection seam. A raw event callback after model
    /// application is not enough to reconstruct parent final/turn ownership.
    var nativeEventObserver: (@MainActor (LoopdyConfiguredHost, DirectHermesEvent) async -> Void)?

    init(identity: LoopdyNotificationIdentityCoordinator, api: any LoopdyManagedNotificationAccountAPI,
         requestPermission: @escaping @MainActor () async throws -> Bool,
         registry: LoopdyHostRegistry, ledger: LoopdyManagedNotificationLedger,
         activityKeys: LoopdyManagedActivityKeychain = LoopdyManagedActivityKeychain(),
         hostClient: @escaping HostClientFactory, now: @escaping () -> Date = Date.init,
         buzzKit: any LoopdyManagedNotificationProvider = LoopdyBuzzKitRuntime.shared) {
        self.buzzKit = buzzKit
        self.identity = identity; self.api = api
        self.requestPermission = requestPermission
        self.registry = registry; self.ledger = ledger; self.activityKeys = activityKeys
        self.hostClient = hostClient; self.now = now
    }

    func enroll(host: LoopdyConfiguredHost, connection: DirectHermesSavedConnection,
                isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult {
        var host = host
        var credentials = try await identity.resolveForEnrollment()
        guard isCurrent(), registry.accountScope == host.accountScope,
              let current = registry.hosts.first(where: { $0.id == host.id }),
              current.principalIdentity == host.principalIdentity else {
            registry.notificationSetupError = "The selected Hermes instance changed while notification identity was being prepared."
            return .prerequisitesRequired
        }
        host = current
        func persistBinding() throws {
            let binding = LoopdyHostNotificationBinding(
                deviceID: credentials.deviceID,
                authorizationEpoch: credentials.authorizationEpoch
            )
            if host.notificationBinding != nil && host.notificationBinding != binding {
                try removeLocalEnrollment(host: host)
            }
            host.notificationBinding = binding
            try registry.update(host)
        }
        try persistBinding()
        retiredHosts.remove(host.notificationScope + ":" + host.hostConnectionID)
        try requireCurrent(host, credentials: credentials)
        try ledger.pruneExpiredRevocations(accountScope: host.notificationScope, now: timestamp)
        let profile = registry.workspace(for: host).selectedProfile
        guard ManagedNotificationValidation.profile(profile), connection.endpoint == host.endpoint,
              DirectHermesIdentity.matches(connection.identity, host.principalIdentity) else { throw DirectHermesError.identityChanged }
        let key = LoopdyManagedNotificationLedger.key(scope: host.notificationScope, host: host.hostConnectionID, profile: profile)
        guard enrolling.insert(key).inserted else { throw DirectHermesError.tooManyRequests }
        defer { enrolling.remove(key) }
        @MainActor func check() throws {
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), registry.workspace(for: host).selectedProfile == profile else { throw DirectHermesError.secureStorageChanged }
        }
        try check()
        do {
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        } catch let error as LoopdyManagedNotificationSetupError
            where error.stage == .providerIdentity && error.code == "notification_credentials_revoked" {
            credentials = try await identity.replaceRevokedForEnrollment(expected: credentials)
            try persistBinding()
            retiredHosts.remove(host.notificationScope + ":" + host.hostConnectionID)
            try requireCurrent(host, credentials: credentials)
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        }
        try check()
        // This is called only by the explicit setup Enable action, never startup.
        let permissionGranted = try await providerOperation(stage: .notificationPermission) {
            try await requestPermission()
        }
        try check()
        guard permissionGranted else {
            throw LoopdyManagedNotificationSetupError(stage: .notificationPermission)
        }
        try check()
        try await providerOperation(stage: .deviceRegistration) {
            try await buzzKit.registerCurrentDevice()
        }
        try check()
        // Explicit enablement requires both this attempt's current registration
        // and provider status readback for that exact subscription before any
        // host grant can be created or claimed.
        _ = try await providerOperation(stage: .providerReadiness) {
            try await buzzKit.refreshProviderReadiness(
                accountAPI: api,
                credentials: credentials,
                requiringCurrentRegistration: true
            )
        }
        try check()
        let client = try hostClient(host)
        let capabilities: LoopdyManagedCapabilities
        do {
            capabilities = try ManagedNotificationValidation.decode(LoopdyManagedCapabilities.self,
                from: await client.request("/capabilities", method: "GET", body: nil, isCurrent: { (try? check()) != nil }))
        } catch DirectHostNotificationError.backendRestartRequired { try check(); return .backendRestartRequired }
        try check(); try capabilities.validate()
        guard capabilities.managedEnrollmentSupported, capabilities.supportsCompletionEnrollment else { return .prerequisitesRequired }
        var record = ledger.record(host: host, profile: profile) ?? LoopdyManagedEnrollmentRecord(
            accountScope: host.notificationScope, accountID: credentials.deviceID, hostConnectionID: host.hostConnectionID,
            profile: profile, creationBody: nil, enrollmentID: UUID().uuidString.lowercased(), grant: nil,
            richLiveActivitySupported: (capabilities.richLiveActivitySupported ?? capabilities.producerCapabilities.richLiveActivity),
            enabled: false, revokePending: false, subscriptions: [])
        if record.revokePending {
            try await reconcilePendingRevocations(); try check()
            guard let recovered = ledger.record(host: host, profile: profile), !recovered.revokePending else {
                throw DirectHermesError.secureStorageChanged
            }
            record = recovered
        }
        if let pin = record.grant {
            guard pin.hostPublicKey == capabilities.hostPublicKey, pin.hostKeyId == capabilities.hostKeyId else {
                throw DirectHermesError.identityChanged
            }
        }
        var listed = try await list(credentials)
        try check()
        for stale in listed where stale.hostPublicKey == capabilities.hostPublicKey
            && stale.hostKeyId == capabilities.hostKeyId && stale.profile == profile
            && stale.state != "revoked" && stale.expiresAt <= timestamp {
            record.grant = stale; record.enabled = false; record.revokePending = true
            try ledger.save(record)
            let body = try ManagedNotificationValidation.data(LoopdyJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(stale.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + stale.grantId, method: "DELETE", body: body, credentials: credentials))
            try check()
            guard deleted.grantId == stale.grantId, deleted.state == "revoked" else { throw DirectHermesError.invalidResponse }
            listed = try await list(credentials); try check()
            guard listed.contains(where: { $0.grantId == stale.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            record.grant = nil; record.creationBody = nil; record.revokePending = false
            record.subscriptions = []; record.enrollmentID = UUID().uuidString.lowercased()
            try ledger.save(record)
        }
        if let old = record.grant, listed.contains(where: { $0.grantId == old.grantId && $0.state == "revoked" }) {
            record.grant = nil; record.creationBody = nil; record.subscriptions = []; record.enabled = false
            record.enrollmentID = UUID().uuidString.lowercased(); try ledger.save(record)
        }
        // An earlier release could persist enabled metadata for the legacy topic
        // layout. Explicit opt-in authorizes replacing that grant; loading saved
        // metadata or opening Settings never widens an existing authority.
        let expectedEvents = capabilities.enrollmentEventTypes
        let obsolete = listed.filter {
            $0.hostPublicKey == capabilities.hostPublicKey && $0.hostKeyId == capabilities.hostKeyId
                && $0.profile == profile && $0.authorizationEpoch == credentials.authorizationEpoch
                && $0.state != "revoked" && $0.expiresAt > timestamp
                && ($0.instanceId != host.hostConnectionID.lowercased() || Set($0.eventTypes) != expectedEvents)
        }
        guard obsolete.count <= 1 else { throw DirectHermesError.invalidResponse }
        if let stale = obsolete.first {
            record.grant = stale; record.enabled = false; record.revokePending = true
            try ledger.save(record)
            let body = try ManagedNotificationValidation.data(LoopdyJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(stale.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + stale.grantId, method: "DELETE", body: body, credentials: credentials))
            try check()
            guard deleted.grantId == stale.grantId, deleted.state == "revoked" else {
                throw DirectHermesError.invalidResponse
            }
            listed = try await list(credentials); try check()
            guard listed.contains(where: { $0.grantId == stale.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            record.grant = nil; record.creationBody = nil; record.revokePending = false
            record.subscriptions = []; record.enrollmentID = UUID().uuidString.lowercased()
            try ledger.save(record)
        }
        let matches = listed.filter { $0.hostPublicKey == capabilities.hostPublicKey && $0.hostKeyId == capabilities.hostKeyId
            && $0.profile == profile && $0.authorizationEpoch == credentials.authorizationEpoch
            && $0.state != "revoked" && $0.expiresAt > timestamp
            && $0.instanceId == host.hostConnectionID.lowercased()
            && ManagedNotificationValidation.validEnrollmentEventTypes($0.eventTypes) }
        guard matches.count <= 1 else { throw DirectHermesError.invalidResponse }
        var grant: LoopdyManagedGrant
        if let existing = matches.first {
            if let pinned = record.grant, pinned.expiresAt > timestamp, pinned.grantId != existing.grantId {
                throw DirectHermesError.identityChanged
            }
            if let pinned = record.grant, !pinned.sameAuthority(as: existing) {
                throw DirectHermesError.identityChanged
            }
            if let frozen = record.creationBody {
                let intent = try JSONDecoder().decode(LoopdyManagedGrantIntent.self, from: frozen)
                guard Set(intent.eventTypes) == Set(existing.eventTypes), intent.expiresAt == existing.expiresAt else {
                    throw DirectHermesError.identityChanged
                }
            }
            grant = existing
        } else {
            if record.creationBody == nil {
                let intent = LoopdyManagedGrantIntent(version: 3, idempotencyKey: UUID().uuidString.lowercased(),
                    instanceId: host.hostConnectionID.lowercased(),
                    hostPublicKey: capabilities.hostPublicKey, hostKeyId: capabilities.hostKeyId, profile: profile,
                    eventTypes: capabilities.enrollmentEventTypes.sorted(),
                    expiresAt: timestamp + 2_592_000)
                record.creationBody = try ManagedNotificationValidation.data(intent)
                try check(); try ledger.save(record) // durable BEFORE cloud mutation
            }
            guard let body = record.creationBody else { throw DirectHermesError.savedConnectionInvalid }
            let intent = try JSONDecoder().decode(LoopdyManagedGrantIntent.self, from: body)
            guard intent.version == 3, ManagedNotificationValidation.uuid(intent.idempotencyKey),
                  intent.instanceId == host.hostConnectionID.lowercased(),
                  intent.hostPublicKey == capabilities.hostPublicKey, intent.hostKeyId == capabilities.hostKeyId,
                  intent.profile == profile, ManagedNotificationValidation.validEnrollmentEventTypes(intent.eventTypes) else {
                throw DirectHermesError.identityChanged
            }
            // Unknown outcome retains these exact bytes; never generates a new key.
            grant = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root, method: "POST", body: body, credentials: credentials))
            try check()
            guard Set(grant.eventTypes) == Set(intent.eventTypes), grant.expiresAt == intent.expiresAt else {
                throw DirectHermesError.identityChanged
            }
        }
        record.richLiveActivitySupported = (capabilities.richLiveActivitySupported ?? capabilities.producerCapabilities.richLiveActivity)
        try validate(grant, host: host, profile: profile, credentials: credentials)
        guard grant.hostKeyId == capabilities.hostKeyId, grant.hostPublicKey == capabilities.hostPublicKey else {
            throw DirectHermesError.identityChanged
        }

        // A grant cannot silently migrate between two configured local hosts.
        guard !ledger.enrollments.contains(where: { $0.grant?.grantId == grant.grantId
            && ($0.accountScope != host.notificationScope || $0.hostConnectionID != host.hostConnectionID) }) else {
            throw DirectHermesError.identityChanged
        }
        record.grant = grant
        try ledger.save(record)
        let claimed = try ManagedNotificationValidation.grant(await client.request("/enroll", method: "POST",
            body: ["version": .integer(1), "idempotencyKey": .string(record.enrollmentID), "grantId": .string(grant.grantId)],
            isCurrent: { (try? check()) != nil }))
        try check()
        guard grant.sameAuthority(as: claimed), claimed.state == "active" else { throw DirectHermesError.invalidResponse }
        let observed = try ManagedNotificationValidation.grant(await client.request("/enrollments/" + grant.grantId,
            method: "GET", body: nil, isCurrent: { (try? check()) != nil }))
        try check()
        guard claimed == observed else { throw DirectHermesError.invalidResponse }
        try await identity.bindWakeRouting(credentials: credentials, grantID: observed.grantId)
        try check()
        grant = observed; record.grant = grant; record.enabled = true
        record.creationBody = nil
        try ledger.save(record)
        // Enrollment from Settings can occur after the selected chat was already
        // opened. Subscribe that exact authenticated session now; later chats use
        // the normal onChatOpened hook.
        if let chat = registry.workspace(for: host).selectedChat {
            try await onChatOpened(host: host, chat: chat)
            try check()
        }
        return .enabled
    }

    func ownsChat(host: LoopdyConfiguredHost, client: DirectHermesConversationClient) -> Bool {
        guard let authority = client.nativeWorkspaceAuthority else {
            return !host.isIndependent && client.journal.owner?.hostIdentity == host.principalIdentity
        }
        guard let saved = try? registry.credentialVault(for: host).load(),
              saved.identity == host.principalIdentity, saved.endpoint == host.endpoint,
              let expected = saved.workspaceAuthority else { return false }
        return authority == expected && client.journal.owner?.hostIdentity == expected.cacheScopeID
    }

    /// Subscription begins only after the actual native chat has opened/recovered.
    func onChatOpened(host: LoopdyConfiguredHost, chat: DirectHermesChat) async throws {
        let profile = chat.client.profile; let session = chat.client.storedID
        // Ordinary chat opening is not notification opt-in. Do not require a
        // notification identity or contact either service without a live grant.
        guard ManagedNotificationValidation.coordinate(session),
              var record = ledger.record(host: host, profile: profile), record.enabled, !record.revokePending,
              let grant = record.grant, grant.state == "active", grant.expiresAt > timestamp else { return }
        let credentials = try self.credentials(for: host)
        guard ownsChat(host: host, client: chat.client) else { return }
        let client = try hostClient(host)
        let loaded = try ManagedNotificationValidation.decode(LoopdyManagedCapabilities.self,
            from: await client.request("/capabilities", method: "GET", body: nil,
                isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil }))
        try loaded.validate()
        guard loaded.hostKeyId == grant.hostKeyId, loaded.hostPublicKey == grant.hostPublicKey,
              loaded.managedEnrollmentSupported, loaded.supportsCompletionEnrollment else {
            throw DirectHermesError.notConnected
        }
        let value = try await client.request("/enrollments/\(grant.grantId)/sessions", method: "PUT", body: [
            "version": .integer(1), "profile": .string(profile), "sessionId": .string(session), "enabled": .boolean(true)
        ], isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil })
        try requireCurrent(host, credentials: credentials)
        guard let object = value.object, object["grantId"]?.string == grant.grantId,
              object["profile"]?.string == profile, object["sessionId"]?.string == session,
              object["sessionReference"]?.string == ManagedNotificationValidation.sessionReference(profile: profile, session: session),
              object["enabled"]?.boolean == true, chat.client.storedID == session,
              let current = ledger.record(host: host, profile: profile), current.enabled,
              current.grant == grant, !current.revokePending else { throw DirectHermesError.invalidResponse }
        record = current; record.subscriptions.insert(session); try ledger.save(record)
    }

    func receive(host: LoopdyConfiguredHost, event: DirectHermesEvent) async {
        guard (try? credentials(for: host)) != nil else { return }
        await nativeEventObserver?(host, event)
    }

    /// The event coordinate comes from the BuzzKit/APNs payload, but authority is
    /// re-established from the local grant ledger and authenticated host readback.
    func openVerifiedEvent(eventID: String, eventType: String,
                           isCurrent: @escaping @MainActor () -> Bool) async throws -> DirectHermesChat {
        let pieces = eventID.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, ManagedNotificationValidation.uuid(String(pieces[0])), pieces[1].utf8.count == 64,
              pieces[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ManagedNotificationValidation.eventTypes.contains(eventType) else { throw DirectHermesError.invalidResponse }
        let matches = ledger.enrollments.filter { record in
            record.enabled && !record.revokePending && record.grant?.grantId == String(pieces[0])
                && record.grant?.eventTypes.contains(eventType) == true
                && (record.grant?.expiresAt ?? 0) > timestamp
        }
        guard matches.count == 1, let record = matches.first,
              let host = registry.hosts.first(where: {
                  $0.notificationScope == record.accountScope
                      && $0.hostConnectionID == record.hostConnectionID
              }) else { throw DirectHermesError.invalidCredentials }
        let credentials = try self.credentials(for: host)
        let generation = registry.generation; let navigation = UUID(); opening = navigation
        defer { if opening == navigation { opening = nil } }
        @MainActor func check() throws {
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), opening == navigation, registry.generation == generation else { throw DirectHermesError.secureStorageChanged }
        }
        let client = try hostClient(host)
        guard let activeGrant = record.grant else { throw DirectHermesError.invalidCredentials }
        let response = try await client.request("/enrollments/\(activeGrant.grantId)/events/\(eventID)", method: "GET", body: nil,
            isCurrent: { (try? check()) != nil })
        try check()
        guard let value = response.object?["event"] else { throw DirectHermesError.invalidResponse }
        let detail = try ManagedNotificationValidation.decode(LoopdyManagedEventDetail.self, from: value)
        let expectedContentKind = eventType == "approval.required" ? "approval"
            : eventType == "clarification.required" ? "clarification"
            : eventType.hasPrefix("scheduled.") ? "scheduled"
            : eventType.hasPrefix("subagent.") ? "subagent"
            : eventType == "session.failed" ? "failure" : "reply"
        guard detail.eventId == eventID, detail.eventType == eventType, detail.profile == record.profile,
              ManagedNotificationValidation.coordinate(detail.sessionId), ManagedNotificationValidation.coordinate(detail.turnId),
              detail.agent.id == detail.profile, !detail.agent.name.isEmpty, detail.agent.name.utf8.count <= 80,
              detail.agent.avatarSha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !detail.content.text.isEmpty, detail.content.text.count <= 1_600,
              detail.content.kind == expectedContentKind,
              detail.occurredAt >= (record.grant?.createdAt ?? Int.max),
              detail.occurredAt <= min(timestamp + 120, record.grant?.expiresAt ?? 0) else { throw DirectHermesError.invalidResponse }
        registry.select(host.id)
        guard registry.selectedHostID == host.id else { throw DirectHermesError.secureStorageChanged }
        let selectedGeneration = registry.generation
        let workspace = registry.workspace(for: host)
        if !workspace.isConnected { await workspace.reconnect() }
        try requireCurrent(host, credentials: credentials)
        guard isCurrent(), opening == navigation, registry.generation == selectedGeneration, registry.selectedHostID == host.id,
              workspace.isConnected else { throw DirectHermesError.notConnected }
        workspace.selectedProfile = detail.profile
        await workspace.loadSessions()
        try requireCurrent(host, credentials: credentials)
        guard isCurrent(), opening == navigation, registry.generation == selectedGeneration, workspace.selectedProfile == detail.profile,
              let summary = workspace.sessions.first(where: { $0.storedID == detail.sessionId && $0.profile == detail.profile }),
              summary.supportsNativeResume else { throw DirectHermesError.invalidResponse }
        await workspace.openSession(summary)
        try requireCurrent(host, credentials: credentials)
        guard isCurrent(), opening == navigation, registry.generation == selectedGeneration, registry.selectedHostID == host.id,
              let chat = workspace.selectedChat, chat.client.profile == detail.profile,
              chat.client.storedID == detail.sessionId else { throw DirectHermesError.invalidResponse }
        return chat
    }

    /// Synchronous removal preserves cloud revoke intent before local retirement.
    /// Main may await revoke(host:) first; offline removal still stops local use.
    func removeLocalEnrollment(host: LoopdyConfiguredHost) throws {
        try ledger.retire(host: host)
        retiredHosts.insert(host.notificationScope + ":" + host.hostConnectionID)
        activityRuntime?.retire(host: host)

    }

    func revoke(host: LoopdyConfiguredHost) async throws {
        _ = try credentials(for: host)
        try removeLocalEnrollment(host: host)
        try await reconcilePendingRevocations()
    }

    /// Account-signed revocation needs no host credential/socket. Invoke on account
    /// readiness and explicit retry, including after a host was removed offline.
    func reconcilePendingRevocations() async throws {
        guard !revocationInFlight else { throw DirectHermesError.tooManyRequests }
        revocationInFlight = true; defer { revocationInFlight = false }
        guard let credentials = try identity.current() else { return }
        let scope = ManagedNotificationValidation.digest(credentials.deviceID + ":" + String(credentials.authorizationEpoch))
        for var record in ledger.enrollments where record.accountScope == scope && record.revokePending {
            if record.grant == nil, let originalBody = record.creationBody {
                // Resolve the original idempotency key, including a lost create
                // response. Never drop an unknown grant just because host removal
                // happened before its ID reached the phone.
                guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                let intent = try JSONDecoder().decode(LoopdyManagedGrantIntent.self, from: originalBody)
                guard [2, 3].contains(intent.version), intent.profile == record.profile,
                      intent.instanceId == nil || intent.instanceId == record.hostConnectionID.lowercased() else {
                    throw DirectHermesError.savedConnectionInvalid
                }
                let candidates = try await list(credentials)
                guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                let matches = candidates.filter { $0.profile == intent.profile && $0.hostKeyId == intent.hostKeyId
                    && $0.hostPublicKey == intent.hostPublicKey && $0.expiresAt == intent.expiresAt
                    && (intent.instanceId == nil || $0.instanceId == intent.instanceId)
                    && $0.authorizationEpoch == credentials.authorizationEpoch }
                if matches.count == 1 { record.grant = matches[0] }
                else {
                    guard matches.isEmpty else { throw DirectHermesError.invalidResponse }
                    record.grant = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                        path: Self.root, method: "POST", body: originalBody, credentials: credentials))
                    guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                }
                guard ledger.enrollments.contains(where: { $0.accountScope == record.accountScope
                    && $0.hostConnectionID == record.hostConnectionID && $0.profile == record.profile
                    && $0.revokePending && $0.creationBody == originalBody && $0.grant == nil }) else { continue }
                try ledger.save(record)
            }
            guard let grant = record.grant else { continue }
            guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
            let body = try ManagedNotificationValidation.data(LoopdyJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(grant.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + grant.grantId, method: "DELETE", body: body, credentials: credentials))
            guard try identity.current() == credentials, deleted.grantId == grant.grantId, deleted.state == "revoked" else {
                throw DirectHermesError.secureStorageChanged
            }
            let readback = try await list(credentials)
            guard try identity.current() == credentials, readback.contains(where: { $0.grantId == grant.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            guard ledger.enrollments.contains(where: { $0.accountScope == record.accountScope
                && $0.hostConnectionID == record.hostConnectionID && $0.profile == record.profile
                && $0.revokePending && $0.grant?.grantId == grant.grantId }) else { continue }
            record.grant = deleted; record.revokePending = false; record.enabled = false; record.creationBody = nil
            try ledger.save(record)
            for owner in ledger.activities where owner.grantID == grant.grantId { try activityKeys.remove(owner.relayActivityID) }
        }
    }

    /// Fence old callbacks synchronously before changing registry/vault ownership.
    /// Cloud device/account revocation belongs to the existing account flow.
    func retireForAccountBoundary() {
        opening = nil
        (api as? LoopdyLinkAPI)?.invalidateManagedNotificationReadiness()
        for host in registry.hosts {
            retiredHosts.insert(host.notificationScope + ":" + host.hostConnectionID)
            activityRuntime?.retire(host: host)
        }
    }
    /// Main calls after its eraser successfully removes this ledger's root AND
    /// managed activity Keychain service, not merely after hiding the account UI.
    func didEraseAccountData() { ledger.didEraseAccountData() }

    /// Explicit notification-data erase. Host grants and the dedicated installation
    /// are still authoritatively revoked, but BuzzKit provider availability is not a
    /// prerequisite for erasing app-owned identity and ledger authority.
    func eraseNotificationIdentity() async throws {
        retireForAccountBoundary()
        try await reconcilePendingRevocations()
        await buzzKit.retireIdentityForLocalErasure()
        try await identity.erase()
        ledger.didEraseAccountData()
    }

    func credentials(for host: LoopdyConfiguredHost) throws -> LoopdyManagedNotificationCredentials {
        guard let credentials = try identity.current() else { throw DirectHermesError.invalidCredentials }
        try requireCurrent(host, credentials: credentials); return credentials
    }
    func requireCurrent(_ host: LoopdyConfiguredHost, credentials: LoopdyManagedNotificationCredentials) throws {
        try Task.checkCancellation()
        guard try identity.current() == credentials, credentials.deviceID == (try host.notificationAccountID()),
              registry.accountScope == host.accountScope,
              host.notificationScope == ManagedNotificationValidation.digest(credentials.deviceID + ":" + String(credentials.authorizationEpoch)),
              !retiredHosts.contains(host.notificationScope + ":" + host.hostConnectionID),
              registry.hosts.contains(where: { $0.id == host.id && $0.principalIdentity == host.principalIdentity
                  && $0.notificationBinding == host.notificationBinding }) else {
            throw DirectHermesError.secureStorageChanged
        }
    }
    func client(for host: LoopdyConfiguredHost) throws -> any DirectHostNotificationServing { try hostClient(host) }
    func accountAPI() -> any LoopdyManagedNotificationAccountAPI { api }
    func notificationContextScope() -> String {
        guard let credentials = try? identity.current() else { return "automatic-notification-identity" }
        return ManagedNotificationValidation.digest(
            [credentials.subscriberScope, credentials.deviceID, String(credentials.authorizationEpoch)].joined(separator: "\0")
        )
    }
    func refreshNotificationIdentity() async throws -> LoopdyNotificationRuntimeSnapshot {
        guard let credentials = try identity.current() else {
            _ = LoopdyBuzzKitRuntime.shared.configureIfPossible()
            return .current
        }
        try await providerOperation(stage: .providerIdentity) {
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        }
        try requireCurrentNotificationIdentity(credentials)
        if let grant = ledger.enrollments.lazy.filter({
            $0.accountID == credentials.deviceID && $0.enabled && !$0.revokePending
        }).compactMap(\.grant).first(where: {
            $0.subscriberScope == credentials.subscriberScope && $0.authorizationEpoch == credentials.authorizationEpoch
                && $0.state == "active" && $0.expiresAt > timestamp
        }) {
            try await identity.bindWakeRouting(credentials: credentials, grantID: grant.grantId)
            try requireCurrentNotificationIdentity(credentials)
        }
        return .current
    }
    func refreshNotificationRuntime() async throws -> LoopdyNotificationRuntimeSnapshot {
        _ = try await refreshNotificationIdentity()
        guard let credentials = try identity.current() else { return .current }
        _ = try await providerOperation(stage: .providerReadiness) {
            try await buzzKit.refreshProviderReadiness(
                accountAPI: api,
                credentials: credentials,
                requiringCurrentRegistration: false
            )
        }
        try requireCurrentNotificationIdentity(credentials)
        return .current
    }
    func sendTestNotification() async throws -> LoopdyNotificationTestReceipt {
        guard let credentials = try identity.current() else { throw DirectHermesError.invalidCredentials }
        let body = try ManagedNotificationValidation.data(LoopdyJSONValue.object([
            "version": .integer(1), "requestId": .string(UUID().uuidString.lowercased()),
        ]))
        let response = try await api.managedNotificationRequest(
            path: Self.root + "/buzzkit/test", method: "POST", body: body, credentials: credentials
        )
        struct Envelope: Decodable { let version: Int; let test: LoopdyNotificationTestReceipt }
        let result = try ManagedNotificationValidation.decode(Envelope.self, from: response)
        guard result.version == 1 else { throw DirectHermesError.invalidResponse }
        return result.test
    }
    private func list(_ credentials: LoopdyManagedNotificationCredentials) async throws -> [LoopdyManagedGrant] {
        try ManagedNotificationValidation.grants(await api.managedNotificationRequest(path: Self.root, method: "GET", body: nil, credentials: credentials))
    }
    private func validate(_ grant: LoopdyManagedGrant, host: LoopdyConfiguredHost, profile: String,
                          credentials: LoopdyManagedNotificationCredentials) throws {
        try grant.validate()
        guard grant.authorizationEpoch == credentials.authorizationEpoch,
              grant.instanceId == host.hostConnectionID.lowercased(),
              grant.subscriberScope == credentials.subscriberScope,
              grant.profile == profile, grant.state != "revoked", grant.expiresAt > timestamp,
              ManagedNotificationValidation.validEnrollmentEventTypes(grant.eventTypes) else { throw DirectHermesError.invalidResponse }
    }
    private func providerOperation<Value>(
        stage: LoopdyManagedNotificationSetupError.Stage,
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as LoopdyManagedNotificationSetupError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw LoopdyManagedNotificationSetupError(stage: stage)
        }
    }
    private func requireCurrentNotificationIdentity(
        _ credentials: LoopdyManagedNotificationCredentials
    ) throws {
        try Task.checkCancellation()
        guard try identity.current() == credentials else {
            throw DirectHermesError.secureStorageChanged
        }
    }
    private var timestamp: Int { Int(now().timeIntervalSince1970) }
    static let root = "/v1/notifications/host-grants"
}
