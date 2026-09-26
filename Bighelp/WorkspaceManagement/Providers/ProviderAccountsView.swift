import Observation
import SwiftUI

@MainActor @Observable
final class ProviderAccountsStore {
    let hostName: String
    let profileID: String
    let servingProfileID: String?

    private(set) var snapshot: DirectHermesProviderSnapshot?
    private(set) var oauthSession: DirectHermesOAuthSession?
    private(set) var credentialValidation: DirectHermesProviderValidation?
    private(set) var endpointValidation: DirectHermesProviderValidation?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false

    @ObservationIgnored private let client: DirectHermesProviderClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var oauthPollTask: Task<Void, Never>?
    @ObservationIgnored private var latestSetupInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var consumedSetupInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var setupRefreshTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        servingProfileID: String? = nil,
        client: DirectHermesProviderClient
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.servingProfileID = servingProfileID
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }
    var canManageServingState: Bool { servingProfileID == profileID && ownsScope }
    var hasActiveOAuthSession: Bool { oauthSession?.status == .pending }

    func load() async {
        await load(preservingMessages: false)
    }

    func receiveSetupInvalidation(revision: UInt64) {
        guard ownsScope, revision > latestSetupInvalidationRevision else { return }
        latestSetupInvalidationRevision = revision
        scheduleSetupRefreshIfNeeded()
    }

    private func load(preservingMessages: Bool) async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        if !preservingMessages {
            errorMessage = nil
            successMessage = nil
        }
        defer {
            if generation == request { isLoading = false }
            scheduleSetupRefreshIfNeeded()
        }
        do {
            let value = try await client.loadSnapshot(
                profileID: profileID,
                servingProfileID: servingProfileID,
                includeServingCredentialPools: canManageServingState
            )
            guard canPublish(request) else { return }
            snapshot = value
        } catch is CancellationError {
        } catch {
            guard canPublish(request) else { return }
            if !preservingMessages || (errorMessage == nil && successMessage == nil) {
                errorMessage = Self.message(error)
            }
        }
    }

    func refresh() async {
        guard operationTitle == nil else { return }
        isLoading = false
        await load()
    }

    func retire() {
        isRetired = true
        generation = UUID()
        setupRefreshTask?.cancel()
        setupRefreshTask = nil
        latestSetupInvalidationRevision = 0
        consumedSetupInvalidationRevision = 0
        oauthPollTask?.cancel()
        oauthPollTask = nil
        oauthSession = nil
        credentialValidation = nil
        endpointValidation = nil
        snapshot = nil
        isLoading = false
        operationTitle = nil
        errorMessage = nil
        successMessage = nil
    }

    func clearCredentialValidation() { credentialValidation = nil }
    func clearEndpointValidation() { endpointValidation = nil }

    func testCredential(key: String, value: String, companionAPIKey: String = "") async {
        guard begin("Testing credential") else { return }
        defer { finish() }
        do {
            let result = try await client.validateCredential(
                profileID: profileID, key: key, value: value, companionAPIKey: companionAPIKey
            )
            guard ownsScope else { return }
            credentialValidation = result
            successMessage = result.isAccepted
                ? (result.isReachable ? "Hermes confirmed that the provider accepted this credential." : "Hermes has no live probe for this credential type.")
                : nil
            errorMessage = result.isAccepted ? nil : (result.message.isEmpty ? "The provider did not accept this credential." : result.message)
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func replaceCredential(key: String, value: String, companionAPIKey: String = "") async -> Bool {
        guard begin("Replacing credential") else { return false }
        defer { finish() }
        do {
            _ = try await client.replaceCredential(
                profileID: profileID, key: key, value: value, companionAPIKey: companionAPIKey
            )
            guard ownsScope else { return false }
            credentialValidation = nil
            try await reloadAfterMutation(message: "Hermes replaced the credential and confirmed its presence.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func deleteCredential(key: String) async -> Bool {
        guard begin("Removing credential") else { return false }
        defer { finish() }
        do {
            try await client.deleteCredential(profileID: profileID, key: key)
            guard ownsScope else { return false }
            credentialValidation = nil
            try await reloadAfterMutation(message: "Hermes removed the credential and its provider mirrors.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func testEndpoint(_ draft: DirectHermesCustomEndpointDraft) async {
        guard begin("Testing endpoint") else { return }
        defer { finish() }
        do {
            let result = try await client.validateCustomEndpoint(draft)
            guard ownsScope else { return }
            endpointValidation = result
            successMessage = result.isAccepted ? "Hermes reached the endpoint and found \(result.models.count) model(s)." : nil
            errorMessage = result.isAccepted ? nil : (result.message.isEmpty ? "The endpoint test failed." : result.message)
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func saveEndpoint(_ draft: DirectHermesCustomEndpointDraft) async -> Bool {
        guard begin("Saving endpoint") else { return false }
        defer { finish() }
        do {
            _ = try await client.saveCustomEndpoint(profileID: profileID, draft: draft)
            guard ownsScope else { return false }
            endpointValidation = nil
            try await reloadAfterMutation(message: "Hermes saved the custom endpoint and confirmed its profile state.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func activateEndpoint(id: String) async {
        guard begin("Activating endpoint") else { return }
        defer { finish() }
        do {
            try await client.activateCustomEndpoint(profileID: profileID, endpointID: id)
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes made this endpoint the profile default.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func deleteEndpoint(id: String) async -> Bool {
        guard begin("Removing endpoint") else { return false }
        defer { finish() }
        do {
            try await client.deleteCustomEndpoint(profileID: profileID, endpointID: id)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes removed the custom endpoint and detached its profile default.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func startOAuth(providerID: String) async -> DirectHermesOAuthSession? {
        guard !hasActiveOAuthSession, begin("Starting sign-in") else { return nil }
        defer { finish() }
        do {
            let session = try await client.startOAuth(profileID: profileID, providerID: providerID)
            guard ownsScope else { return nil }
            oauthSession = session
            if session.flow == .deviceCode { startPolling(session) }
            return session
        } catch is CancellationError {
            return nil
        } catch {
            guard ownsScope else { return nil }
            errorMessage = Self.message(error)
            return nil
        }
    }

    func submitOAuthCode(_ code: String) async -> Bool {
        guard let session = oauthSession, session.flow == .pkce, session.status == .pending,
              begin("Completing sign-in") else { return false }
        defer { finish() }
        do {
            let completed = try await client.submitOAuthCode(
                profileID: profileID, session: session, code: code
            )
            guard ownsScope, oauthSession?.id == session.id else { return false }
            oauthSession = completed
            guard completed.status == .approved else {
                errorMessage = completed.errorMessage ?? "Provider sign-in was not accepted."
                return false
            }
            try await reloadAfterMutation(message: "Hermes confirmed the provider sign-in and profile account state.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope, oauthSession?.id == session.id else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func cancelOAuth() async {
        guard let session = oauthSession, begin("Cancelling sign-in") else { return }
        oauthPollTask?.cancel()
        oauthPollTask = nil
        defer { finish() }
        do {
            try await client.cancelOAuth(profileID: profileID, sessionID: session.id)
            guard ownsScope else { return }
            oauthSession = nil
            successMessage = "Sign-in was cancelled before Hermes saved an account."
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func disconnectOAuth(providerID: String) async {
        guard begin("Disconnecting account") else { return }
        defer { finish() }
        do {
            try await client.disconnectOAuth(profileID: profileID, providerID: providerID)
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes disconnected the provider account.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func addPoolCredential(providerID: String, apiKey: String, label: String) async -> Bool {
        guard canManageServingState, begin("Adding account credential") else { return false }
        defer { finish() }
        do {
            try await client.addServingCredentialPoolEntry(
                profileID: profileID, servingProfileID: servingProfileID,
                providerID: providerID, apiKey: apiKey,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
            )
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes added and confirmed the serving-profile account credential.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func deletePoolCredential(providerID: String, entry: DirectHermesCredentialPool.Entry) async {
        guard canManageServingState, begin("Removing account credential") else { return }
        defer { finish() }
        do {
            try await client.deleteServingCredentialPoolEntry(
                profileID: profileID, servingProfileID: servingProfileID,
                providerID: providerID, entry: entry
            )
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes removed the account credential and confirmed that it did not return.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    private func startPolling(_ initial: DirectHermesOAuthSession) {
        oauthPollTask?.cancel()
        oauthPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var current = initial
            while !Task.isCancelled, self.ownsScope, current.status == .pending, Date.now < current.expiresAt {
                do { try await Task.sleep(for: .seconds(current.pollInterval)) }
                catch { return }
                do {
                    current = try await self.client.pollOAuth(profileID: self.profileID, session: current)
                    guard self.ownsScope, self.oauthSession?.id == current.id else { return }
                    if current.status != .pending {
                        self.oauthSession = .init(
                            id: current.id, providerID: current.providerID, flow: current.flow,
                            userCode: "", verificationURL: current.verificationURL,
                            expiresAt: current.expiresAt, pollInterval: current.pollInterval,
                            status: current.status, errorMessage: current.errorMessage,
                            completionReason: current.completionReason, accountEmail: current.accountEmail,
                            selectedModel: current.selectedModel
                        )
                        self.oauthPollTask = nil
                        if current.status == .approved {
                            try await self.reloadAfterMutation(message: "Hermes confirmed the provider sign-in.")
                        } else {
                            self.errorMessage = current.errorMessage ?? "Provider sign-in ended with status \(current.status.rawValue)."
                        }
                        return
                    }
                    self.oauthSession = current
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsScope else { return }
                    self.errorMessage = Self.message(error)
                    return
                }
            }
            guard !Task.isCancelled, self.ownsScope,
                  self.oauthSession?.id == current.id, current.status == .pending else { return }
            self.oauthSession = .init(
                id: current.id, providerID: current.providerID, flow: current.flow,
                userCode: "", verificationURL: current.verificationURL,
                expiresAt: current.expiresAt, pollInterval: current.pollInterval,
                status: .expired, errorMessage: "The provider sign-in code expired.",
                completionReason: current.completionReason, accountEmail: nil,
                selectedModel: current.selectedModel
            )
            self.oauthPollTask = nil
            self.errorMessage = "The provider sign-in code expired. Start a new sign-in to continue."
        }
    }

    private func reloadAfterMutation(message: String) async throws {
        let value = try await client.loadSnapshot(
            profileID: profileID, servingProfileID: servingProfileID,
            includeServingCredentialPools: canManageServingState
        )
        guard ownsScope else { throw CancellationError() }
        snapshot = value
        errorMessage = nil
        successMessage = message
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() {
        operationTitle = nil
        scheduleSetupRefreshIfNeeded()
    }

    private func scheduleSetupRefreshIfNeeded() {
        guard ownsScope, setupRefreshTask == nil, !isBusy,
              latestSetupInvalidationRevision != consumedSetupInvalidationRevision else { return }
        setupRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.drainSetupRefreshes()
        }
    }

    private func drainSetupRefreshes() async {
        defer {
            setupRefreshTask = nil
            scheduleSetupRefreshIfNeeded()
        }
        while ownsScope, !isBusy, !Task.isCancelled,
              latestSetupInvalidationRevision != consumedSetupInvalidationRevision {
            let revision = latestSetupInvalidationRevision
            await load(preservingMessages: true)
            guard ownsScope, !Task.isCancelled else { return }
            consumedSetupInvalidationRevision = revision
        }
    }

    private func canPublish(_ request: UUID) -> Bool { ownsScope && generation == request && !Task.isCancelled }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this provider operation. Refresh before trying it again."
    }
}

@MainActor
struct ProviderAccountsView: View {
    private struct PoolRemoval: Identifiable {
        let providerID: String
        let entry: DirectHermesCredentialPool.Entry
        var id: String { "\(providerID.utf8.count):\(providerID)\(entry.id)" }
    }

    let store: ProviderAccountsStore
    @State private var addingEndpoint = false
    @State private var addingPoolCredential = false
    @State private var disconnectOAuthID: String?
    @State private var poolRemoval: PoolRemoval?
    @State private var oauthCode = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if store.ownsScope {
                Form {
                    scopeSection
                    statusSections
                    if let snapshot = store.snapshot {
                        if snapshot.setup != nil || snapshot.runtime != nil { runtimeSection(snapshot) }
                        if let portal = snapshot.portal { portalSection(portal) }
                        oauthSection(snapshot.oauthProviders)
                        credentialSection(snapshot.credentials)
                        supportedProvidersSection(snapshot.providers)
                        endpointsSection(snapshot.customEndpoints)
                        poolsSection(snapshot.credentialPools)
                        SkippedPartsNote(parts: snapshot.skippedParts)
                    }
                }
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Provider accounts unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("The selected host changed. Reopen Provider Accounts from the current workspace.")
                )
            }
        }
        .navigationTitle("Provider Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.snapshot == nil { await store.load() } }
        .sheet(isPresented: $addingEndpoint) {
            NavigationStack {
                ProviderEndpointEditorView(store: store, endpoint: nil) { addingEndpoint = false }
            }
        }
        .sheet(isPresented: $addingPoolCredential) {
            NavigationStack {
                ProviderPoolCredentialEditorView(store: store) { addingPoolCredential = false }
            }
        }
        .confirmationDialog(
            "Disconnect provider account?", isPresented: Binding(
                get: { disconnectOAuthID != nil },
                set: { if !$0 { disconnectOAuthID = nil } }
            ), titleVisibility: .visible
        ) {
            if let id = disconnectOAuthID {
                Button("Disconnect", role: .destructive) {
                    disconnectOAuthID = nil
                    Task { await store.disconnectOAuth(providerID: id) }
                }
            }
            Button("Cancel", role: .cancel) { disconnectOAuthID = nil }
        } message: {
            Text("Hermes will remove its saved OAuth account for this profile. Existing sessions are not changed.")
        }
        .confirmationDialog(
            "Remove this account credential?", isPresented: Binding(
                get: { poolRemoval != nil },
                set: { if !$0 { poolRemoval = nil } }
            ), titleVisibility: .visible
        ) {
            if let removal = poolRemoval {
                Button("Remove", role: .destructive) {
                    poolRemoval = nil
                    Task {
                        await store.deletePoolCredential(
                            providerID: removal.providerID, entry: removal.entry
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { poolRemoval = nil }
        } message: {
            Text("Hermes will remove the selected credential-pool entry and suppress its backing source when required so it does not return on refresh.")
        }
        .onChange(of: store.oauthSession?.id) { _, _ in oauthCode = "" }
        .onDisappear { oauthCode = "" }
        .accessibilityIdentifier("providers.accounts")
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: {
            Text("Applies to")
        } footer: {
            Text("Saved credentials stay on this host and are never displayed in bighelp.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading provider accounts") }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isBusy)
            }
            .accessibilityIdentifier("providers.error")
        }
        if let message = store.successMessage {
            Section { Label(message, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("providers.confirmed")
        }
    }

    private func runtimeSection(_ snapshot: DirectHermesProviderSnapshot) -> some View {
        Section("New chats") {
            if let setup = snapshot.setup {
                LabeledContent("Provider configured", value: setup.providerConfigured == true ? "Yes" : "No")
            }
            if let runtime = snapshot.runtime {
                LabeledContent("New sessions", value: runtime.isUsable ? "Ready" : "Needs attention")
            }
            if let provider = snapshot.runtime?.providerID { LabeledContent("Effective provider", value: provider) }
            if let model = snapshot.runtime?.modelID { LabeledContent("Effective model", value: model) }
            if let error = snapshot.runtime?.errorMessage, !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func portalSection(_ portal: DirectHermesPortalStatus) -> some View {
        Section("Nous account") {
            LabeledContent("Account", value: portal.isLoggedIn ? (portal.isFreeTier ? "Free tier" : "Connected") : "Not connected")
            if let tier = portal.accountTier { LabeledContent("Tier", value: tier) }
            ForEach(portal.features) { feature in LabeledContent(feature.label, value: feature.state) }
            if let url = portal.subscriptionURL {
                Button("Manage subscription", systemImage: "arrow.up.right.square") { openURL(url) }
            }
        }
    }

    private func supportedProvidersSection(_ providers: [DirectHermesProviderDescriptor]) -> some View {
        Section("Advanced · Provider support") {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.name)
                        Spacer()
                        if provider.isAuthenticated == true {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Authenticated")
                        }
                    }
                    Text([provider.authType, "\(provider.modelCount) models"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("providers.supported.\(provider.id)")
            }
        }
    }

    private func credentialSection(_ credentials: [DirectHermesProviderCredential]) -> some View {
        Section("API keys") {
            let rows = credentials.filter { !$0.isChannelManaged && ($0.category == "provider" || $0.providerID != nil || $0.isCustom) }
            ForEach(rows) { credential in
                NavigationLink {
                    ProviderCredentialEditorView(store: store, credentialID: credential.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credential.providerName ?? credential.id)
                        Text(credential.isSet ? "Configured on Hermes" : "Not configured")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("providers.credential.\(credential.id)")
            }
            if rows.isEmpty { Text("No provider key fields were reported.").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func oauthSection(_ providers: [DirectHermesOAuthProvider]) -> some View {
        Section("Connected accounts") {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.name)
                        Spacer()
                        Text(provider.status.isLoggedIn ? "Connected" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let label = provider.status.sourceLabel, provider.status.isLoggedIn {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    if provider.status.isLoggedIn, provider.canDisconnect {
                        Button("Disconnect") { disconnectOAuthID = provider.id }
                            .disabled(store.isBusy)
                    } else if provider.flow == .deviceCode || provider.flow == .pkce {
                        Button("Sign in") {
                            Task {
                                if let session = await store.startOAuth(providerID: provider.id) {
                                    openURL(session.verificationURL)
                                }
                            }
                        }
                        .disabled(store.isBusy || store.hasActiveOAuthSession)
                    } else if let docs = provider.documentationURL {
                        Button("Open provider instructions", systemImage: "arrow.up.right.square") { openURL(docs) }
                    }
                    if let hint = provider.disconnectHint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("providers.oauth.\(provider.id)")
            }
            if let session = store.oauthSession { oauthSessionView(session) }
        }
    }

    private func oauthSessionView(_ session: DirectHermesOAuthSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.status == .pending ? "Waiting for authorization" : "Sign-in: \(session.status.rawValue)")
                .font(.headline)
            if session.flow == .deviceCode, !session.userCode.isEmpty {
                Text(session.userCode).font(.title3.monospaced()).textSelection(.enabled).privacySensitive()
                    .accessibilityLabel("Provider verification code")
            }
            Button("Open sign-in page", systemImage: "arrow.up.right.square") { openURL(session.verificationURL) }
            if session.status == .pending {
                if session.flow == .deviceCode {
                    ProgressView()
                } else if session.flow == .pkce {
                    SecureField("Authorization code", text: $oauthCode)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("providers.oauth.completion-code")
                    Button("Complete sign-in") {
                        let submitted = oauthCode
                        oauthCode = ""
                        Task { _ = await store.submitOAuthCode(submitted) }
                    }
                    .disabled(
                        oauthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || oauthCode.utf8.count > 16_384 || store.isBusy
                    )
                    Text("The code goes directly to Hermes and is cleared immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Cancel sign-in", role: .cancel) { Task { await store.cancelOAuth() } }
                    .disabled(store.isBusy)
            }
        }
        .accessibilityIdentifier("providers.oauth.session")
    }

    private func endpointsSection(_ endpoints: [DirectHermesCustomEndpoint]) -> some View {
        Section("Advanced · Custom endpoints") {
            ForEach(endpoints) { endpoint in
                NavigationLink {
                    ProviderEndpointEditorView(store: store, endpoint: endpoint)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(endpoint.name)
                            if endpoint.isCurrent { Image(systemName: "checkmark").accessibilityLabel("Profile default") }
                        }
                        Text(endpoint.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            Button("Add endpoint", systemImage: "plus") { addingEndpoint = true }.disabled(store.isBusy)
        }
    }

    @ViewBuilder
    private func poolsSection(_ pools: [DirectHermesCredentialPool]) -> some View {
        if store.canManageServingState {
            Section {
                ForEach(pools) { pool in
                    DisclosureGroup(pool.id) {
                        ForEach(pool.entries) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.label)
                                    Text(entry.source).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    poolRemoval = .init(providerID: pool.id, entry: entry)
                                }
                                .disabled(store.isBusy)
                            }
                        }
                    }
                }
                Button("Add account credential", systemImage: "plus") { addingPoolCredential = true }
                    .disabled(store.isBusy)
            } header: {
                Text("Advanced · Credential pools")
            } footer: {
                Text("Entries belong to the host’s serving profile. Saved values are never shown.")
            }
        }
    }
}

@MainActor
private struct ProviderCredentialEditorView: View {
    let store: ProviderAccountsStore
    let credentialID: String
    @State private var value = ""
    @State private var confirmReplace = false
    @State private var confirmDelete = false

    private var credential: DirectHermesProviderCredential? {
        store.snapshot?.credentials.first { $0.id == credentialID }
    }

    var body: some View {
        Form {
            if let credential {
                Section("Credential") {
                    LabeledContent("Field", value: credential.id)
                    LabeledContent("Provider", value: credential.providerName ?? credential.providerID ?? "Other")
                    LabeledContent("Status", value: credential.isSet ? "Configured" : "Not configured")
                    if !credential.description.isEmpty { Text(credential.description).font(.footnote) }
                }
                Section {
                    SecureField("New value", text: $value)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("providers.credential.value")
                    Button("Test with provider") {
                        Task { await store.testCredential(key: credential.id, value: value) }
                    }
                    .disabled(value.isEmpty || value.utf8.count > 16_384 || store.isBusy)
                    Button("Review replacement") { confirmReplace = true }
                        .disabled(value.isEmpty || value.utf8.count > 16_384 || store.isBusy)
                    if credential.isSet {
                        Button("Remove credential", role: .destructive) { confirmDelete = true }
                            .disabled(store.isBusy)
                    }
                } header: {
                    Text("New value")
                } footer: {
                    Text("Replace validates before saving. The saved value is never read back.")
                }
            } else {
                ContentUnavailableView("Credential unavailable", systemImage: "key.slash")
            }
        }
        .navigationTitle(credential?.providerName ?? "Credential")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: value) { _, _ in store.clearCredentialValidation() }
        .onDisappear { value = "" }
        .confirmationDialog("Replace this credential?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Validate and replace") {
                let submitted = value
                Task {
                    if await store.replaceCredential(key: credentialID, value: submitted) { value = "" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will test this value, replace the selected profile's saved credential, and reconcile provider mirrors.")
        }
        .confirmationDialog("Remove this credential?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { if await store.deleteCredential(key: credentialID) { value = "" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will remove the environment value and matching provider mirrors. OAuth and unrelated pooled accounts remain separate.")
        }
    }
}

@MainActor
private struct ProviderEndpointEditorView: View {
    let store: ProviderAccountsStore
    let endpoint: DirectHermesCustomEndpoint?
    let onDone: (() -> Void)?

    @State private var name: String
    @State private var baseURL: String
    @State private var model: String
    @State private var contextLength: String
    @State private var discoversModels: Bool
    @State private var makeDefault = false
    @State private var apiKey = ""
    @State private var removeSavedKey = false
    @State private var confirmSave = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(store: ProviderAccountsStore, endpoint: DirectHermesCustomEndpoint?, onDone: (() -> Void)? = nil) {
        self.store = store
        self.endpoint = endpoint
        self.onDone = onDone
        _name = State(initialValue: endpoint?.name ?? "")
        _baseURL = State(initialValue: endpoint?.baseURL ?? "")
        _model = State(initialValue: endpoint?.defaultModel ?? "")
        _contextLength = State(initialValue: endpoint?.contextLength.map(String.init) ?? "")
        _discoversModels = State(initialValue: endpoint?.discoversModels ?? true)
    }

    private var draft: DirectHermesCustomEndpointDraft {
        .init(
            id: endpoint?.id, name: name, baseURL: baseURL, model: model,
            models: endpoint?.models ?? [], contextLength: Int(contextLength),
            discoversModels: discoversModels, makeDefault: makeDefault,
            apiKey: removeSavedKey ? "" : (apiKey.isEmpty ? nil : apiKey)
        )
    }

    var body: some View {
        Form {
            Section("Basics") {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Default model", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Make profile default", isOn: $makeDefault)
            }
            Section("Advanced") {
                TextField("Context length (optional)", text: $contextLength).keyboardType(.numberPad)
                Toggle("Discover models", isOn: $discoversModels)
            }
            Section {
                SecureField(endpoint?.hasCredential == true ? "Replacement key (optional)" : "API key (optional)", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                if endpoint?.hasCredential == true {
                    Toggle("Remove saved key", isOn: $removeSavedKey).disabled(!apiKey.isEmpty)
                }
            } header: {
                Text("Credential")
            } footer: {
                Text("Blank preserves the saved key. Removing it is explicit; tests use only a key entered here.")
            }
            Section("Actions") {
                Button("Test endpoint") { Task { await store.testEndpoint(draft) } }
                    .disabled(!valid || store.isBusy)
                Button(endpoint == nil ? "Review new endpoint" : "Review changes") { confirmSave = true }
                    .disabled(!valid || store.isBusy)
                if let endpoint {
                    Button(endpoint.isCurrent ? "Profile default" : "Make profile default") {
                        Task { await store.activateEndpoint(id: endpoint.id) }
                    }
                    .disabled(endpoint.isCurrent || store.isBusy)
                    Button("Delete endpoint", role: .destructive) { confirmDelete = true }
                        .disabled(store.isBusy)
                }
            }
        }
        .navigationTitle(endpoint?.name ?? "New Endpoint")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onDone != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone?() } }
            }
        }
        .onChange(of: apiKey) { _, _ in store.clearEndpointValidation() }
        .onChange(of: baseURL) { _, _ in store.clearEndpointValidation() }
        .onDisappear { apiKey = "" }
        .confirmationDialog("Save this endpoint?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") {
                let submitted = draft
                Task {
                    if await store.saveEndpoint(submitted) {
                        apiKey = ""
                        if let onDone { onDone() } else { dismiss() }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will merge these fields into the selected profile's endpoint entry. Hidden hand-edited fields remain on the host.")
        }
        .confirmationDialog("Delete this endpoint?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let endpoint {
                Button("Delete", role: .destructive) {
                    Task {
                        if await store.deleteEndpoint(id: endpoint.id) {
                            if let onDone { onDone() } else { dismiss() }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will remove this endpoint, its managed key, and any matching main-model endpoint mirror. Other provider settings remain.")
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey.utf8.count <= 16_384
            && (contextLength.isEmpty || (Int(contextLength) ?? 0) > 0)
    }
}

@MainActor
private struct ProviderPoolCredentialEditorView: View {
    let store: ProviderAccountsStore
    let onDone: () -> Void
    @State private var providerID = ""
    @State private var label = ""
    @State private var apiKey = ""
    @State private var confirm = false

    private var providers: [DirectHermesProviderDescriptor] { store.snapshot?.providers ?? [] }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $providerID) {
                    Text("Choose a provider").tag("")
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
                TextField("Account label (optional)", text: $label)
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            } header: { Text("Account") } footer: {
                Text("The key is sent once to the serving profile and is never read back into bighelp.")
            }
            Section {
                Button("Review account credential") { confirm = true }
                    .disabled(providerID.isEmpty || apiKey.isEmpty || apiKey.utf8.count > 16_384 || store.isBusy)
            }
        }
        .navigationTitle("Add Account Credential")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) } }
        .onDisappear { apiKey = "" }
        .confirmationDialog("Add this account credential?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Add") {
                let submitted = apiKey
                Task {
                    if await store.addPoolCredential(providerID: providerID, apiKey: submitted, label: label) {
                        apiKey = ""
                        onDone()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will add a separate credential-pool entry for this provider on the serving profile.")
        }
    }
}
