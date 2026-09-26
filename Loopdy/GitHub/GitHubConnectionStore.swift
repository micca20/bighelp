import Foundation
import Observation

enum GitHubConnectionState: Equatable, Sendable {
    case notConfigured, disconnected, requestingCode, verifyingPersonalAccessToken
    case awaitingAuthorization(GitHubDevicePrompt)
    case confirmAccount(GitHubIdentity)
    case connected(GitHubIdentity)
    case failed(GitHubError)
}

/// Optional, device-direct provider. Construction makes no network or Keychain requests.
/// The main actor owns all attempts, refresh publication, owner/identity generations
/// and synchronous vault transactions. UI only observes non-credential projections.
@MainActor @Observable
final class GitHubConnectionStore {
    let configuration: GitHubConfiguration?
    private(set) var ownerID: String?
    private(set) var state: GitHubConnectionState
    private(set) var savedIdentities: [GitHubIdentity] = []
    private(set) var savedCredentials: [GitHubSavedCredential] = []
    private(set) var selectedCredential: GitHubSavedCredential?
    private(set) var pendingOrigin: GitHubCredentialOrigin?
    private(set) var selectedIdentity: GitHubIdentity?
    private(set) var generation = UUID()

    @ObservationIgnored private let transport: any GitHubTransport
    @ObservationIgnored let clock: any GitHubClock
    @ObservationIgnored private let vault: any GitHubCredentialVault
    @ObservationIgnored private var selectedRecord: GitHubCredentialRecord?
    @ObservationIgnored private var pendingRecord: GitHubCredentialRecord?
    @ObservationIgnored private var attemptTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<GitHubTokenPair, any Error>?
    @ObservationIgnored private var readCancellations: [UUID: @Sendable () -> Void] = [:]
    @ObservationIgnored private var nextRequestAt: Date = .distantPast
    @ObservationIgnored private var nextSearchAt: Date = .distantPast
    private enum RateLimitScope: Hashable {
        case user(Int)
        case authentication(String?)
    }
    @ObservationIgnored private var rateLimits: [RateLimitScope: GitHubRateLimitBudget] = [:]
    @ObservationIgnored let discoveryCache = GitHubDiscoveryCache()
    var referenceLastCheckedAt: Date? { discoveryCache.lastCheckedAt }
    var referenceDiscoveryRevision: Int { discoveryCache.revision }

    init(
        ownerID: String?, configuration: GitHubConfiguration?,
        transport: any GitHubTransport = GitHubURLSessionTransport(),
        vault: any GitHubCredentialVault = GitHubKeychainVault(),
        clock: any GitHubClock = GitHubSystemClock()
    ) {
        self.ownerID = ownerID
        self.configuration = configuration
        self.transport = transport
        self.vault = vault
        self.clock = clock
        state = .disconnected
    }

    deinit {
        attemptTask?.cancel()
        refreshTask?.cancel()
        for cancel in readCancellations.values { cancel() }
    }

    /// Call synchronously at the Loopdy account boundary, BEFORE exposing the new chat.
    /// Sign-out hides credentials; explicit account deletion uses eraseOwnerCredentials().
    func setOwner(_ ownerID: String?) {
        guard self.ownerID != ownerID else { return }
        invalidate()
        self.ownerID = ownerID
        savedIdentities = []
        savedCredentials = []
        selectedIdentity = nil
        selectedRecord = nil
        state = .disconnected
    }

    /// Local-only and explicitly invoked by connection management. Never selects an identity.
    func loadSavedIdentities() {
        guard ownerID != nil else { return }
        do {
            publishSaved(try storedRecords())
        } catch { state = .failed(.vaultUnavailable) }
    }

    /// A confirmed account is the default for chats without an explicit choice.
    /// An explicit disconnect or a different pinned credential never falls back.
    func referenceCredentialID(savedID: String?, disabled: Bool) -> String? {
        guard !disabled, ownerID != nil, case .connected = state,
              let selectedCredential, savedID == nil || savedID == selectedCredential.id else { return nil }
        return selectedCredential.id
    }

    /// Restore only an unambiguous, owner-scoped local credential. No network.
    func restoreDefaultCredentialIfUnambiguous() {
        guard ownerID != nil, selectedCredential == nil, pendingOrigin == nil else { return }
        do {
            let records = try storedRecords()
            publishSaved(records)
            if records.count == 1, let record = records.first { try select(record) }
        } catch { state = .failed(GitHubError.safe(error)) }
    }

    /// Legacy per-user selection is safe only when exactly one credential exists.
    func selectIdentity(userID: Int) {
        clearSelection()
        do {
            let matches = try storedRecords().filter { $0.identity.id == userID }
            guard matches.count == 1, let record = matches.first else {
                throw GitHubError.credentialSelectionRequired
            }
            try select(record)
        } catch { state = .failed(GitHubError.safe(error)) }
    }

    /// Persist this exact local ID per chat, scoped to its Loopdy owner. Never export it.
    func selectCredential(id: String) {
        clearSelection()
        do {
            guard let record = try storedRecords().first(where: { $0.id == id }) else {
                throw GitHubError.accountNotConfirmed
            }
            try select(record)
        } catch { state = .failed(GitHubError.safe(error)) }
    }

    private func select(_ record: GitHubCredentialRecord) throws {
        try record.validate()
        if let tokens = record.tokens {
            guard !record.refreshPending, tokens.refreshExpiresAt > clock.now() else {
                throw GitHubError.reconnectRequired
            }
        }
        selectedRecord = record
        selectedCredential = record.summary
        selectedIdentity = record.identity
        state = .connected(record.identity)
    }

    /// Independent PAT path: no registration, discovery or vault access before confirmation.
    func connectPersonalAccessToken(_ token: String) async {
        clearSelection()
        state = .verifyingPersonalAccessToken
        let lease = generation
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let currentScope = try self.personalTokenScope()
                let credential = try GitHubPersonalAccessToken(token)
                let response = try await self.send(self.apiRequest(path: "/user", token: credential.value), lease: lease)
                if response.statusCode == 401 { throw GitHubError.personalAccessTokenReplacementRequired }
                try self.requireSuccess(response)
                let identity = try GitHubIdentity.decode(response.data)
                try self.check(lease)
                self.pendingRecord = GitHubCredentialRecord(scope: currentScope, identity: identity, personalAccessToken: credential)
                self.pendingOrigin = .personalAccessToken
                self.state = .confirmAccount(identity)
            } catch {
                guard self.generation == lease else { return }
                self.pendingRecord = nil
                self.pendingOrigin = nil
                self.state = .failed(GitHubError.safe(error))
            }
            if self.generation == lease { self.attemptTask = nil }
        }
        attemptTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func clearSelection() {
        invalidate()
        selectedIdentity = nil
        selectedRecord = nil
        state = .disconnected
    }

    func startConnection() {
        clearSelection()
        guard configuration != nil else { state = .notConfigured; return }
        do { _ = try scope() } catch { state = .failed(.accountNotConfirmed); return }
        state = .requestingCode
        let lease = generation
        attemptTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.authorize(lease: lease) }
            catch {
                guard self.generation == lease else { return }
                self.pendingRecord = nil
                self.state = .failed(GitHubError.safe(error))
            }
            if self.generation == lease { self.attemptTask = nil }
        }
    }

    /// Cancels only connection setup. Closing management must not disconnect a confirmed account.
    func cancelConnection() {
        switch state {
        case .requestingCode, .verifyingPersonalAccessToken, .awaitingAuthorization, .confirmAccount:
            invalidate()
            state = .disconnected
        default: break
        }
    }

    func confirmAccount(userID: Int) {
        guard case .confirmAccount(let identity) = state, identity.id == userID,
              let record = pendingRecord, record.identity.id == userID,
              record.scope == (try? credentialScope(origin: record.origin)),
              record.tokens.map({ $0.accessExpiresAt > clock.now() }) ?? true
        else {
            pendingRecord = nil
            pendingOrigin = nil
            state = .failed(.accountNotConfirmed)
            return
        }
        do {
            try record.validate()
            let existing = try storedRecords()
            guard existing.count < 50 || existing.contains(where: { $0.id == record.id }) else {
                throw GitHubError.vaultUnavailable
            }
            try vault.save(record)
            pendingRecord = nil
            selectedRecord = record
            selectedIdentity = record.identity
            selectedCredential = record.summary
            pendingOrigin = nil
            publishSaved(existing.filter { $0.id != record.id } + [record])
            state = .connected(record.identity)
        } catch {
            pendingRecord = nil
            pendingOrigin = nil
            state = .failed(.vaultUnavailable)
        }
    }

    /// Removes one exact local credential, not every PAT belonging to the same user.
    func disconnectCredential(id: String) throws {
        clearSelection()
        do {
            let records = try storedRecords()
            guard let record = records.first(where: { $0.id == id }) else { throw GitHubError.accountNotConfirmed }
            try vault.remove(recordID: record.id, in: record.scope)
            publishSaved(records.filter { $0.id != id })
        } catch {
            state = .failed(.vaultUnavailable)
            throw GitHubError.vaultUnavailable
        }
    }

    /// Legacy identity-wide disconnect explicitly removes ALL this user's local credentials.
    func disconnect(userID: Int) throws {
        invalidate()
        selectedRecord = nil
        selectedIdentity = nil
        do {
            let records = try storedRecords()
            for record in records where record.identity.id == userID {
                try vault.remove(recordID: record.id, in: record.scope)
            }
            publishSaved(records.filter { $0.identity.id != userID })
            state = .disconnected
        } catch {
            state = .failed(.vaultUnavailable)
            throw GitHubError.vaultUnavailable
        }
    }

    /// Invoke before deleting the current Loopdy account; do not swap owners first.
    func eraseOwnerCredentials() throws {
        invalidate()
        selectedRecord = nil
        selectedIdentity = nil
        do {
            if ownerID != nil {
                for scope in try availableScopes() { try vault.removeAll(in: scope) }
            }
            savedIdentities = []
            savedCredentials = []
            state = .disconnected
        } catch {
            state = .failed(.vaultUnavailable)
            throw GitHubError.vaultUnavailable
        }
    }

    func check(_ lease: UUID) throws {
        try Task.checkCancellation()
        guard generation == lease else { throw GitHubError.cancelled }
    }

    func read<T: Sendable>(
        userID: Int, operation: @escaping @MainActor @Sendable (UUID) async throws -> T
    ) async throws -> T {
        guard selectedIdentity?.id == userID, selectedRecord != nil else { throw GitHubError.accountNotConfirmed }
        guard readCancellations.count < 8 else { throw GitHubError.throttled(until: clock.now().addingTimeInterval(2)) }
        let lease = generation
        let id = UUID()
        let task = Task { try await operation(lease) }
        readCancellations[id] = { task.cancel() }
        defer { readCancellations[id] = nil }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try check(lease)
            return result
        } onCancel: { task.cancel() }
    }

    func authorizedGET(path: String, query: [URLQueryItem] = [], lease: UUID) async throws -> GitHubHTTPResponse {
        let token = try await accessToken(lease: lease)
        try check(lease)
        let request = try apiRequest(path: path, query: query, token: token)
        let response = try await send(request, lease: lease, search: path == "/search/issues")
        if response.statusCode == 401 {
            // Fail closed on revocation. Do not blindly refresh an apparently valid token.
            let failure: GitHubError = selectedRecord?.origin == .personalAccessToken
                ? .personalAccessTokenReplacementRequired : .reconnectRequired
            // Keep the exact saved row available for explicit removal/replacement.
            clearSelection()
            state = .failed(failure)
            throw failure
        }
        try requireSuccess(response)
        return response
    }

    private func scope() throws -> GitHubCredentialScope {
        guard let configuration else { throw GitHubError.notConfigured }
        guard let ownerID, !ownerID.isEmpty, ownerID.utf8.count <= 512 else { throw GitHubError.accountNotConfirmed }
        return GitHubCredentialScope(ownerID: ownerID, clientID: configuration.clientID)
    }

    private func personalTokenScope() throws -> GitHubCredentialScope {
        guard let ownerID, !ownerID.isEmpty, ownerID.utf8.count <= 512 else { throw GitHubError.accountNotConfirmed }
        // Empty client ID is a dedicated PAT namespace, never an OAuth client identity.
        return GitHubCredentialScope(ownerID: ownerID, clientID: "")
    }

    private func credentialScope(origin: GitHubCredentialOrigin) throws -> GitHubCredentialScope {
        if origin == .personalAccessToken { return try personalTokenScope() }
        return try scope()
    }

    private func availableScopes() throws -> [GitHubCredentialScope] {
        var scopes = [try personalTokenScope()]
        if configuration != nil { scopes.append(try scope()) }
        return scopes
    }

    private func storedRecords() throws -> [GitHubCredentialRecord] {
        var records: [GitHubCredentialRecord] = []
        for currentScope in try availableScopes() {
            for record in try vault.records(in: currentScope) {
                guard record.scope == currentScope, record.identity.id > 0,
                      record.identity.login.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}$"#, options: .regularExpression) != nil
                else { throw GitHubError.vaultUnavailable }
                try record.validate()
                records.append(record)
            }
        }
        guard records.count <= 50, Set(records.map(\.id)).count == records.count else {
            throw GitHubError.vaultUnavailable
        }
        return records
    }

    private func publishSaved(_ records: [GitHubCredentialRecord]) {
        savedCredentials = records.map(\.summary).sorted {
            if $0.identity.login != $1.identity.login { return $0.identity.login < $1.identity.login }
            return $0.id < $1.id
        }
        var seen = Set<Int>()
        savedIdentities = savedCredentials.map(\.identity).filter { seen.insert($0.id).inserted }
    }

    private func invalidate() {
        generation = UUID()
        attemptTask?.cancel()
        attemptTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        for cancel in readCancellations.values { cancel() }
        readCancellations = [:]
        pendingRecord = nil
        pendingOrigin = nil
        selectedCredential = nil
        discoveryCache.invalidate()
        // The shared network budget survives account changes and cancellation.
    }

    private func authorize(lease: UUID) async throws {
        let currentScope = try scope()
        let requestedAt = clock.now()
        let codeResponse = try await send(
            oauthRequest(path: "/login/device/code", fields: ["client_id": currentScope.clientID]), lease: lease
        )
        try requireSuccess(codeResponse)
        let code = try GitHubDeviceCode.decode(data: codeResponse.data)
        let expiresAt = requestedAt.addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = TimeInterval(code.interval)
        state = .awaitingAuthorization(GitHubDevicePrompt(
            userCode: code.userCode, verificationURI: code.verificationURI, expiresAt: expiresAt
        ))
        while true {
            if clock.now().addingTimeInterval(interval) >= expiresAt {
                try await clock.sleep(seconds: max(0, expiresAt.timeIntervalSince(clock.now())))
                try check(lease)
                throw GitHubError.expiredCode
            }
            try await clock.sleep(seconds: interval)
            try check(lease)
            guard clock.now() < expiresAt else { throw GitHubError.expiredCode }
            let pollStartedAt = clock.now()
            let response = try await send(oauthRequest(path: "/login/oauth/access_token", fields: [
                "client_id": currentScope.clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]), lease: lease, deadline: expiresAt)
            try requireSuccess(response)
            let object = try GitHubJSON.parse(response.data, limit: 16_384).object()
            if let error = object["error"] {
                // Never reflect error_description/error_uri or any unknown field.
                switch try error.string(max: 100) {
                case "authorization_pending": continue
                case "slow_down":
                    let returned = try object["interval"]?.integer(min: 1, max: 86_400)
                    interval = max(interval + 5, TimeInterval(returned ?? 0))
                    continue
                case "expired_token", "token_expired": throw GitHubError.expiredCode
                case "access_denied": throw GitHubError.authorizationDenied
                case "device_flow_disabled": throw GitHubError.deviceFlowDisabled
                case "incorrect_client_credentials": throw GitHubError.invalidConfiguration
                default: throw GitHubError.invalidResponse
                }
            }
            guard clock.now() < expiresAt else { throw GitHubError.expiredCode }
            let tokens = try GitHubTokenPair.decode(object, now: pollStartedAt)
            let accountResponse = try await send(apiRequest(path: "/user", token: tokens.accessToken), lease: lease)
            try requireSuccess(accountResponse)
            let identity = try GitHubIdentity.decode(accountResponse.data)
            try check(lease)
            pendingRecord = GitHubCredentialRecord(scope: currentScope, identity: identity, tokens: tokens, refreshPending: false)
            pendingOrigin = .deviceFlow
            state = .confirmAccount(identity)
            return
        }
    }

    private func accessToken(lease: UUID) async throws -> String {
        try check(lease)
        guard let record = selectedRecord else { throw GitHubError.accountNotConfirmed }
        try record.validate()
        if let personalAccessToken = record.personalAccessToken { return personalAccessToken.value }
        let tokens = try await accessTokens(lease: lease)
        return tokens.accessToken
    }

    private func accessTokens(lease: UUID) async throws -> GitHubTokenPair {
        try check(lease)
        guard let record = selectedRecord, record.origin == .deviceFlow, let tokens = record.tokens, !record.refreshPending else { throw GitHubError.reconnectRequired }
        if let refreshTask {
            let tokens = try await refreshTask.value
            try check(lease)
            return tokens
        }
        if tokens.accessExpiresAt > clock.now().addingTimeInterval(60) { return tokens }
        guard tokens.refreshExpiresAt > clock.now() else { throw GitHubError.reconnectRequired }
        let task = Task { try await self.rotate(record, lease: lease) }
        refreshTask = task
        do {
            let tokens = try await task.value
            try check(lease)
            refreshTask = nil
            return tokens
        } catch {
            if generation == lease {
                refreshTask = nil
                selectedRecord = nil
                selectedIdentity = nil
                selectedCredential = nil
                discoveryCache.invalidate()
                state = .failed(.reconnectRequired)
            }
            throw generation == lease ? GitHubError.reconnectRequired : GitHubError.cancelled
        }
    }

    private func rotate(_ record: GitHubCredentialRecord, lease: UUID) async throws -> GitHubTokenPair {
        try check(lease)
        guard record.origin == .deviceFlow, let currentTokens = record.tokens else { throw GitHubError.reconnectRequired }
        try vault.save(GitHubCredentialRecord(
            scope: record.scope, identity: record.identity, tokens: currentTokens, refreshPending: true
        ))
        // No client_secret: GitHub explicitly supports secretless refresh for device-origin tokens.
        let rotationStartedAt = clock.now()
        let response = try await send(oauthRequest(path: "/login/oauth/access_token", fields: [
            "client_id": record.scope.clientID, "grant_type": "refresh_token", "refresh_token": currentTokens.refreshToken,
        ]), lease: lease)
        try requireSuccess(response)
        let object = try GitHubJSON.parse(response.data, limit: 16_384).object()
        guard object["error"] == nil else { throw GitHubError.reconnectRequired }
        let tokens = try GitHubTokenPair.decode(object, now: rotationStartedAt)
        let accountResponse = try await send(apiRequest(path: "/user", token: tokens.accessToken), lease: lease)
        try requireSuccess(accountResponse)
        let identity = try GitHubIdentity.decode(accountResponse.data)
        guard identity.id == record.identity.id else { throw GitHubError.identityChanged }
        try check(lease)
        let replacement = GitHubCredentialRecord(scope: record.scope, identity: identity, tokens: tokens, refreshPending: false)
        try vault.save(replacement)
        selectedRecord = replacement
        selectedCredential = replacement.summary
        savedCredentials = savedCredentials.map { $0.id == replacement.id ? replacement.summary : $0 }
        selectedIdentity = identity
        savedIdentities = savedIdentities.map { $0.id == identity.id ? identity : $0 }
        state = .connected(identity)
        return tokens
    }

    private func oauthRequest(path: String, fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: "https://github.com" + path) else { throw GitHubError.invalidInput }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Encode values in the BODY, never URLs. Escape '+' as well as '&' and '='.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        return request
    }

    private func apiRequest(path: String, query: [URLQueryItem] = [], token: String) throws -> URLRequest {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.github.com"
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw GitHubError.invalidInput }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func send(
        _ request: URLRequest, lease: UUID, search: Bool = false, deadline: Date? = nil
    ) async throws -> GitHubHTTPResponse {
        try check(lease)
        try GitHubURLSessionTransport.validate(request)
        let budgetScope: RateLimitScope = selectedIdentity.map { .user($0.id) } ?? .authentication(ownerID)
        while true {
            try check(lease)
            let now = clock.now()
            if let deadline, now >= deadline { throw GitHubError.expiredCode }
            let blockedUntil = rateLimits[budgetScope]?.blockedUntil(search: search) ?? .distantPast
            guard blockedUntil <= now else { throw GitHubError.throttled(until: blockedUntil) }
            let readyAt = max(nextRequestAt, search ? nextSearchAt : now)
            if readyAt <= now {
                nextRequestAt = now.addingTimeInterval(1)
                if search { nextSearchAt = now.addingTimeInterval(2.1) }
                break
            }
            try await clock.sleep(seconds: min(readyAt, deadline ?? readyAt).timeIntervalSince(now))
            // Recheck after sleep: simultaneous/delayed waiters cannot burst at once.
        }
        let response: GitHubHTTPResponse
        do { response = try await transport.send(request) }
        catch { throw GitHubError.safe(error) }
        try check(lease)
        guard response.url == request.url, !(300...399).contains(response.statusCode),
              response.data.count <= GitHubURLSessionTransport.maximumResponseBytes
        else { throw GitHubError.invalidResponse }
        // The identity response may consume the last primary request before account
        // confirmation. Carry its budget into that user rather than losing it at select.
        let responseScope: RateLimitScope
        if request.url?.path == "/user", (200...299).contains(response.statusCode),
           let identity = try? GitHubIdentity.decode(response.data) { responseScope = .user(identity.id) }
        else { responseScope = budgetScope }
        if let until = rateLimits[responseScope, default: GitHubRateLimitBudget()].record(response, search: search, now: clock.now()) {
            throw GitHubError.throttled(until: until)
        }
        return response
    }

    private func requireSuccess(_ response: GitHubHTTPResponse) throws {
        switch response.statusCode {
        case 200...299:
            // Production transport requires JSON MIME. Injected DTO transports may omit it;
            // an explicitly supplied wrong MIME is still rejected before strict JSON decoding.
            if let type = response.header("Content-Type"),
               type.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) != "application/json" {
                throw GitHubError.invalidResponse
            }
        case 401: throw GitHubError.reconnectRequired
        case 403: throw GitHubError.accessUnavailable
        case 404: throw GitHubError.notFound
        default: throw GitHubError.networkUnavailable
        }
    }
}
