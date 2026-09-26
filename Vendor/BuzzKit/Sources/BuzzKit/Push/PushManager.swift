import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

actor PushManager {
    private let configuration: BuzzKit.Configuration
    private let api: ClientAPI
    private let identity: IdentityStore
    private let store: KeyValueStore
    private let tracker: EventTracker
    private let logger: BKLogger
    private let subscriptionWork = SerialWorkQueue()
    private var tokenContinuations: [CheckedContinuation<String, Error>] = []
    private var completedRegistration: CompletedRegistration?

    private struct CompletedRegistration {
        let identity: Identity
        let token: String
        let environment: BuzzKit.PushEnvironment
        let subscription: SubscriptionDTO
    }

    init(
        configuration: BuzzKit.Configuration,
        api: ClientAPI,
        identity: IdentityStore,
        store: KeyValueStore,
        tracker: EventTracker,
        logger: BKLogger
    ) {
        self.configuration = configuration
        self.api = api
        self.identity = identity
        self.store = store
        self.tracker = tracker
        self.logger = logger
    }

    #if canImport(UserNotifications)
    func registerForPush(provisional: Bool = false) async throws -> Bool {
        guard !(await identity.isRetired) else { throw BuzzKitError.notIdentified }
        let center = UNUserNotificationCenter.current()
        var options: UNAuthorizationOptions = [.alert, .badge, .sound]
        if provisional { options.insert(.provisional) }
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: options)
        } catch {
            throw BuzzKitError.permissionDenied
        }
        await trackPermissionState()
        do {
            let token = try await requestDeviceToken()
            _ = try await registerSubscription(token: token)
        } catch {
            logger.warn("Device token registration failed: \(error)")
            if granted { throw BuzzKitError.network(underlying: error) }
        }
        return granted
    }

    func synchronizeOnLaunch() async {
        if await identity.isRetired {
            do {
                try await reconcileRetiredIdentity()
            } catch {
                logger.debug("Retired push subscription cleanup deferred: \(error)")
            }
            // Retirement suspends automatic registration. A later explicit identify
            // owns both reactivation and any token registration for the new identity.
            return
        }
        await trackPermissionState()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            || store.string(StorageKey.deviceToken) != nil
        else { return }
        do {
            let token = try await requestDeviceToken()
            _ = try await registerSubscription(token: token)
        } catch {
            logger.debug("Silent token refresh skipped: \(error)")
        }
    }

    func trackPermissionState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = describe(settings.authorizationStatus)
        let previous = store.string(StorageKey.permissionStatus)
        guard previous != status else { return }
        store.set(status, for: StorageKey.permissionStatus)
        if previous != nil || status == "authorized" || status == "denied" {
            await tracker.trackSystem(EventNames.permissionChanged, data: ["status": .string(status)])
        }
        await syncPermissionAttribute(status)
    }

    private func syncPermissionAttribute(_ status: String) async {
        guard !(await identity.isRetired) else { return }
        let current = await identity.current
        do {
            _ = try await api.identify(
                IdentifyBody(
                    externalId: current.externalId,
                    email: nil,
                    identityHash: current.identityHash,
                    attributes: nil,
                    pushPermission: status
                )
            )
        } catch {
            logger.debug("Permission attribute sync deferred: \(error)")
        }
    }

    private func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        default: return "notDetermined"
        }
    }
    #endif

    func requestDeviceToken() async throws -> String {
        if let cached = store.string(StorageKey.deviceToken) {
            requestRemoteRegistration()
            return cached
        }
        return try await withCheckedThrowingContinuation { continuation in
            tokenContinuations.append(continuation)
            requestRemoteRegistration()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.timeOutTokenWait()
            }
        }
    }

    private nonisolated func requestRemoteRegistration() {
        #if canImport(UIKit) && !os(watchOS)
        Task { @MainActor in
            AppDelegateSwizzler.installIfNeeded(swizzles: BuzzKit.instanceIfConfigured?.configuration.automaticPushHandling ?? true)
            SystemOpener.sharedApplication?.registerForRemoteNotifications()
        }
        #endif
    }

    func handleDeviceToken(_ data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        let previous = store.string(StorageKey.deviceToken)
        store.set(token, for: StorageKey.deviceToken)
        let continuations = tokenContinuations
        tokenContinuations = []
        for continuation in continuations {
            continuation.resume(returning: token)
        }
        guard !(await identity.isRetired) else { return }
        if continuations.isEmpty, previous != token || store.string(StorageKey.subscriptionId) == nil {
            do {
                _ = try await registerSubscription(token: token)
            } catch {
                logger.error("Push subscription registration failed after token rotation: \(error)")
            }
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        let continuations = tokenContinuations
        tokenContinuations = []
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        logger.warn("Remote notification registration failed: \(error)")
    }

    private func timeOutTokenWait() {
        guard !tokenContinuations.isEmpty else { return }
        let continuations = tokenContinuations
        tokenContinuations = []
        for continuation in continuations {
            continuation.resume(throwing: BuzzKitError.network(underlying: URLError(.timedOut)))
        }
    }

    func identify(
        externalId: String,
        email: String?,
        identityHash: String?,
        attributes: [String: JSONValue]?,
        subscribe: [BuzzKit.Channel: Bool]
    ) async throws -> Bool {
        try await subscriptionWork.submit { [self] in
            try await performIdentify(
                externalId: externalId,
                email: email,
                identityHash: identityHash,
                attributes: attributes,
                subscribe: subscribe
            )
        }
    }

    func logout() async throws {
        try await subscriptionWork.submit { [self] in
            try await performLogout()
        }
    }

    func reconcileRetiredIdentity() async throws {
        try await subscriptionWork.submit { [self] in
            try await performRetiredIdentityCleanup()
        }
    }

    func registerDeviceToken(_ data: Data) async throws -> BuzzKit.PushSubscriptionRegistration {
        let token = data.map { String(format: "%02x", $0) }.joined()
        store.set(token, for: StorageKey.deviceToken)
        return try await registerSubscription(token: token)
    }

    func reregister() async throws -> BuzzKit.PushSubscriptionRegistration? {
        guard let token = store.string(StorageKey.deviceToken) else { return nil }
        return try await registerSubscription(token: token)
    }

    func unregisterCurrentSubscription() async throws {
        try await subscriptionWork.submit { [self] in
            try await performUnregisterCurrentSubscription()
        }
    }

    private func registerSubscription(token: String) async throws -> BuzzKit.PushSubscriptionRegistration {
        try await subscriptionWork.submit { [self] in
            try await performRegisterSubscription(token: token)
        }
    }

    private func performLogout() async throws {
        _ = await identity.retire()
        try await performRetiredIdentityCleanup()
    }

    private func performIdentify(
        externalId: String,
        email: String?,
        identityHash: String?,
        attributes: [String: JSONValue]?,
        subscribe: [BuzzKit.Channel: Bool]
    ) async throws -> Bool {
        var expected = await identity.snapshot
        if !expected.isRetired,
           !expected.current.isAnonymous,
           expected.current.externalId != externalId {
            // Fence A durably before its DELETE. If the request, process, or app dies,
            // A remains masked while the original SDK fields retain cleanup ownership.
            expected = await identity.retire()
        }
        if expected.isRetired {
            try await performRetiredIdentityCleanup()
            expected = await identity.snapshot
            guard expected.isRetired else { throw CancellationError() }
        }
        try Task.checkCancellation()

        let subscribeByChannel = Dictionary(uniqueKeysWithValues: subscribe.map { ($0.key.rawValue, $0.value) })
        let subscriber = try await api.identify(
            IdentifyBody(
                externalId: externalId,
                email: email,
                identityHash: identityHash,
                attributes: attributes,
                subscribe: subscribeByChannel.isEmpty ? nil : subscribeByChannel,
                device: DeviceContext.current(store: store)
            )
        )
        try Task.checkCancellation()
        guard subscriber.externalId == externalId,
              identityHash == nil || subscriber.verified else {
            throw BuzzKitError.invalidResponse
        }
        guard let (_, changed) = await identity.identify(
            externalId: externalId,
            identityHash: identityHash,
            ifUnchangedFrom: expected
        ) else {
            throw CancellationError()
        }
        if changed, let token = store.string(StorageKey.deviceToken) {
            _ = try await performRegisterSubscription(token: token)
        }
        return changed
    }

    private func performUnregisterCurrentSubscription() async throws {
        let snapshot = await identity.snapshot
        guard !snapshot.isRetired else {
            try await performRetiredIdentityCleanup()
            return
        }
        guard let subscriptionId = store.string(StorageKey.subscriptionId) else { return }
        try await deleteSubscription(
            id: subscriptionId,
            authority: snapshot.current,
            requiringRetirement: nil
        )
    }

    private func performRetiredIdentityCleanup() async throws {
        let expected = await identity.snapshot
        guard expected.isRetired else { return }
        let subscriptionId = store.string(StorageKey.subscriptionId)
        // A retired marker with neither a named identity nor a subscription is the
        // durable clean/suspended state, not another cleanup operation.
        guard expected.externalId != nil || subscriptionId != nil else { return }
        guard let authority = expected.retirementIdentity else { throw CancellationError() }
        if let subscriptionId {
            do {
                try await deleteSubscription(
                    id: subscriptionId,
                    authority: authority,
                    requiringRetirement: expected
                )
            } catch BuzzKitError.api(let code, _) where Self.retiredAuthorityIsUnusable(code) {
                // The retired hash was signed with a rotated tenant secret, or the
                // provider already removed the subscription. Retrying can never
                // succeed, so it must not block every later identify. The backend
                // owns server-side cleanup of subscriptions it can no longer reach.
                guard await identity.snapshot == expected else { throw CancellationError() }
                logger.warn("Dropping unrecoverable retired subscription \(subscriptionId) (\(code))")
                store.set(nil as String?, for: StorageKey.subscriptionId)
                completedRegistration = nil
            }
        }
        guard await identity.completeRetirement(ifUnchangedFrom: expected) else {
            throw CancellationError()
        }
    }

    /// Provider refusals that mean a retired identity can never authorize its own
    /// cleanup, so retrying would wedge every later identify forever.
    static func retiredAuthorityIsUnusable(_ code: String) -> Bool {
        ["invalid_identity_hash", "not_found", "subscription_not_found", "subscriber_not_found"].contains(code)
    }

    private func deleteSubscription(
        id subscriptionId: String,
        authority: Identity,
        requiringRetirement expectedRetirement: IdentitySnapshot?
    ) async throws {
        let deleted = try await api.deleteSubscription(
            id: subscriptionId,
            identity: authority.subscriberIdentity
        )
        try Task.checkCancellation()
        guard deleted.id == subscriptionId, deleted.deleted == true else {
            throw BuzzKitError.invalidResponse
        }
        if let expectedRetirement {
            guard await identity.snapshot == expectedRetirement else { throw CancellationError() }
        } else {
            let current = await identity.snapshot
            guard !current.isRetired, current.current == authority else { throw CancellationError() }
        }
        store.set(nil as String?, for: StorageKey.subscriptionId)
        completedRegistration = nil
    }

    private func performRegisterSubscription(
        token: String
    ) async throws -> BuzzKit.PushSubscriptionRegistration {
        let expected = await identity.snapshot
        guard !expected.isRetired else { throw BuzzKitError.notIdentified }
        let current = expected.current
        let environment = configuration.pushEnvironment ?? PushEnvironmentDetector.detect()
        store.set(environment.rawValue, for: StorageKey.deviceTokenEnvironment)
        if let completedRegistration,
           completedRegistration.identity == current,
           completedRegistration.token == token,
           completedRegistration.environment == environment {
            return try registration(
                completedRegistration.subscription,
                externalId: current.externalId,
                token: token,
                environment: environment
            )
        }

        let subscription = try await api.registerSubscription(
            RegisterSubscriptionBody(
                externalId: current.externalId,
                channel: "push",
                platform: "ios",
                token: token,
                environment: environment == .sandbox ? "sandbox" : nil,
                identityHash: current.identityHash,
                pushPermission: store.string(StorageKey.permissionStatus),
                device: DeviceContext.current(store: store)
            )
        )
        let result = try registration(
            subscription,
            externalId: current.externalId,
            token: token,
            environment: environment
        )
        let latest = await identity.snapshot
        guard latest == expected else {
            // A synchronous retirement can fence an already-running registration.
            // Preserve its exact returned ID under the existing subscription key so
            // the queued retired cleanup owns the only provider mutation to undo.
            if latest.isRetired, latest.retirementIdentity == current {
                store.set(subscription.id, for: StorageKey.subscriptionId)
                completedRegistration = nil
            }
            throw CancellationError()
        }
        store.set(subscription.id, for: StorageKey.subscriptionId)
        completedRegistration = CompletedRegistration(
            identity: current,
            token: token,
            environment: environment,
            subscription: subscription
        )
        logger.info("Push subscription \(subscription.id) registered for \(current.externalId)")
        try Task.checkCancellation()
        return result
    }

    private func registration(
        _ subscription: SubscriptionDTO,
        externalId: String,
        token: String,
        environment: BuzzKit.PushEnvironment
    ) throws -> BuzzKit.PushSubscriptionRegistration {
        let responseEnvironment = subscription.environment ?? BuzzKit.PushEnvironment.production.rawValue
        guard !subscription.id.isEmpty, subscription.id.utf8.count <= 128,
              subscription.channel == "push",
              subscription.platform == "ios",
              subscription.endpoint == token,
              subscription.enabled,
              subscription.status == "active",
              subscription.deleted != true,
              responseEnvironment == environment.rawValue else {
            throw BuzzKitError.invalidResponse
        }
        return BuzzKit.PushSubscriptionRegistration(
            id: subscription.id,
            externalId: externalId,
            endpoint: token,
            environment: environment
        )
    }
}
