import Foundation
import Observation

@MainActor @Observable
final class MessagingOnboardingStore {
    enum Onboarding: Equatable, Sendable {
        case telegram(HermesTelegramOnboarding)
        case whatsApp(HermesWhatsAppOnboarding)

        var pairingID: String {
            switch self {
            case .telegram(let value): value.pairingID
            case .whatsApp(let value): value.pairingID
            }
        }

        var canApply: Bool {
            switch self {
            case .telegram(let value): value.status == "ready"
            case .whatsApp(let value): value.status == "connected"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .telegram: false
            case .whatsApp(let value): ["error", "expired", "cancelled"].contains(value.status)
            }
        }
    }

    let hostName: String
    let profileID: String
    private(set) var catalog: HermesMessagingCatalog?
    private(set) var onboarding: Onboarding?
    private(set) var latestTest: HermesMessagingPlatformTest?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false

    @ObservationIgnored private let client: any HermesMessagingManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var latestInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var consumedInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var invalidationRefreshTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        client: any HermesMessagingManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && !isLoading && !isMutating }

    func platform(id: String) -> HermesMessagingPlatform? {
        catalog?.platforms.first { $0.id.utf8.elementsEqual(id.utf8) }
    }

    func load() async {
        await load(preservingMessages: false)
    }

    func refresh() async { await load() }

    func receivePlatformsInvalidation(revision: UInt64) {
        guard ownsScope, revision > latestInvalidationRevision else { return }
        latestInvalidationRevision = revision
        scheduleInvalidationRefreshIfNeeded()
    }

    private func load(preservingMessages: Bool) async {
        guard ownsScope, !isLoading, !isMutating else { return }
        let request = UUID()
        generation = request
        isLoading = true
        if !preservingMessages { errorMessage = nil }
        defer {
            if generation == request { isLoading = false }
            scheduleInvalidationRefreshIfNeeded()
        }
        do {
            let value = try await client.platforms(profileID: profileID)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            catalog = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request else { return }
            if !preservingMessages || (errorMessage == nil && successMessage == nil) {
                errorMessage = Self.message(error)
            }
        }
    }

    func updatePlatform(
        id: String,
        enabled: Bool?,
        replacements: [String: String],
        clear: [String]
    ) async {
        guard let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let platform = try await client.updatePlatform(
                id: id, profileID: profileID, enabled: enabled,
                replacements: replacements, clear: clear
            )
            guard accepts(token) else { return }
            replace(platform)
            successMessage = "Hermes confirmed the messaging configuration."
        } catch { fail(error, token: token, uncertain: true) }
    }

    func testPlatform(id: String) async {
        guard let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let value = try await client.testPlatform(id: id, profileID: profileID)
            guard accepts(token) else { return }
            latestTest = value
            successMessage = value.succeeded ? value.message : nil
            errorMessage = value.succeeded ? nil : value.message
        } catch { fail(error, token: token, uncertain: false) }
    }

    func startTelegram(botName: String?) async {
        guard onboarding == nil, let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let value = try await client.startTelegram(botName: botName)
            guard accepts(token) else { return }
            onboarding = .telegram(value)
            successMessage = nil
        } catch { fail(error, token: token, uncertain: true) }
    }

    func startWhatsApp(mode: HermesWhatsAppOnboarding.Mode, allowedUsers: String) async {
        guard onboarding == nil, let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let value = try await client.startWhatsApp(
                mode: mode, allowedUsers: allowedUsers, profileID: profileID
            )
            guard accepts(token) else { return }
            onboarding = .whatsApp(value)
            successMessage = nil
        } catch { fail(error, token: token, uncertain: true) }
    }

    func pollOnboarding() async {
        guard canAct, let onboarding, !onboarding.isTerminal else { return }
        let token = generation
        do {
            switch onboarding {
            case .telegram(let current):
                let next = try await client.telegramStatus(pairingID: current.pairingID)
                guard accepts(token) else { return }
                self.onboarding = .telegram(.init(
                    pairingID: next.pairingID, status: next.status,
                    suggestedUsername: current.suggestedUsername,
                    deepLink: current.deepLink, qrPayload: current.qrPayload,
                    expiresAt: next.expiresAt.isEmpty ? current.expiresAt : next.expiresAt,
                    botUsername: next.botUsername, ownerUserID: next.ownerUserID
                ))
            case .whatsApp(let current):
                let next = try await client.whatsAppStatus(pairingID: current.pairingID)
                guard accepts(token), next.pairingID.utf8.elementsEqual(current.pairingID.utf8) else { return }
                self.onboarding = .whatsApp(next)
            }
        } catch is CancellationError {
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func applyTelegram(allowedUserIDs: [String]) async {
        guard case .telegram(let current) = onboarding, current.status == "ready",
              let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let result = try await client.applyTelegram(
                pairingID: current.pairingID,
                allowedUserIDs: allowedUserIDs,
                profileID: profileID
            )
            guard accepts(token) else { return }
            replace(result.platform)
            onboarding = nil
            successMessage = result.needsRestart
                ? "Telegram is configured. Restart Hermes to finish connecting it."
                : "Hermes confirmed Telegram is configured."
        } catch { fail(error, token: token, uncertain: true) }
    }

    func applyWhatsApp(mode: HermesWhatsAppOnboarding.Mode, allowedUsers: String) async {
        guard case .whatsApp(let current) = onboarding, current.status == "connected",
              let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            let result = try await client.applyWhatsApp(
                pairingID: current.pairingID, mode: mode,
                allowedUsers: allowedUsers, profileID: profileID
            )
            guard accepts(token) else { return }
            replace(result.platform)
            onboarding = nil
            successMessage = result.needsRestart
                ? "WhatsApp is configured. Restart Hermes to finish connecting it."
                : "Hermes confirmed WhatsApp is configured."
        } catch { fail(error, token: token, uncertain: true) }
    }

    func cancelOnboarding() async {
        guard let current = onboarding, let token = beginMutation() else { return }
        defer { finishMutation(token) }
        do {
            switch current {
            case .telegram(let value): try await client.cancelTelegram(pairingID: value.pairingID)
            case .whatsApp(let value): try await client.cancelWhatsApp(pairingID: value.pairingID)
            }
            guard accepts(token) else { return }
            onboarding = nil
            successMessage = "Hermes confirmed setup was cancelled."
        } catch { fail(error, token: token, uncertain: true) }
    }

    func dismissTerminalOnboarding() {
        guard onboarding?.isTerminal == true else { return }
        onboarding = nil
        errorMessage = nil
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
        latestTest = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil
        latestInvalidationRevision = 0
        consumedInvalidationRevision = 0
        catalog = nil
        onboarding = nil
        latestTest = nil
        errorMessage = nil
        successMessage = nil
        isLoading = false
        isMutating = false
    }

    private func beginMutation() -> UUID? {
        guard canAct else { return nil }
        let token = UUID()
        generation = token
        isMutating = true
        errorMessage = nil
        successMessage = nil
        latestTest = nil
        return token
    }

    private func finishMutation(_ token: UUID) {
        if generation == token { isMutating = false }
        scheduleInvalidationRefreshIfNeeded()
    }

    private func scheduleInvalidationRefreshIfNeeded() {
        guard ownsScope, invalidationRefreshTask == nil, !isLoading, !isMutating,
              latestInvalidationRevision != consumedInvalidationRevision else { return }
        invalidationRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.drainInvalidationRefreshes()
        }
    }

    private func drainInvalidationRefreshes() async {
        defer {
            invalidationRefreshTask = nil
            scheduleInvalidationRefreshIfNeeded()
        }
        while ownsScope, !isLoading, !isMutating, !Task.isCancelled,
              latestInvalidationRevision != consumedInvalidationRevision {
            let revision = latestInvalidationRevision
            await load(preservingMessages: true)
            guard ownsScope, !Task.isCancelled else { return }
            consumedInvalidationRevision = revision
        }
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func replace(_ platform: HermesMessagingPlatform) {
        guard let catalog,
              let index = catalog.platforms.firstIndex(where: { $0.id.utf8.elementsEqual(platform.id.utf8) }) else {
            return
        }
        var platforms = catalog.platforms
        platforms[index] = platform
        self.catalog = .init(profileID: catalog.profileID, platforms: platforms)
    }

    private func fail(_ error: any Error, token: UUID, uncertain: Bool) {
        guard accepts(token) else { return }
        if error is CancellationError {
            if uncertain {
                errorMessage = "The request was interrupted. Refresh before trying again; its outcome may be unknown."
            }
            return
        }
        errorMessage = Self.message(error)
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        return "Hermes could not complete the messaging request. Refresh its current state before trying again."
    }
}
