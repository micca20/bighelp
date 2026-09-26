import Foundation
import SwiftUI

struct LoopdyNotificationTestReceipt: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case accepted, failed }
    let id: String
    let state: State
    let providerStatus: String
}

struct LoopdyNotificationContext: Sendable {
    let scope: String
    let isCurrent: @MainActor @Sendable () -> Bool
    let refresh: @MainActor @Sendable () async throws -> LoopdyNotificationRuntimeSnapshot
    /// Compatibility seam for callers that refresh provider registration
    /// independently. Notification Settings intentionally does not expose it as
    /// enrollment; selected-host enrollment uses HostNotificationSetupModel.
    let register: @MainActor @Sendable () async throws -> LoopdyNotificationRuntimeSnapshot
    let test: @MainActor @Sendable () async throws -> LoopdyNotificationTestReceipt

    @MainActor
    static func make(
        service: LoopdyManagedNotificationService,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) -> Self {
        Self(scope: service.notificationContextScope(), isCurrent: isCurrent, refresh: {
            guard isCurrent() else { throw CancellationError() }
            let snapshot = try await service.refreshNotificationRuntime()
            guard isCurrent() else { throw CancellationError() }
            return snapshot
        }, register: {
            guard isCurrent() else { throw CancellationError() }
            return try await service.refreshNotificationRuntime()
        }, test: {
            guard isCurrent() else { throw CancellationError() }
            let receipt = try await service.sendTestNotification()
            guard isCurrent() else { throw CancellationError() }
            return receipt
        })
    }

    @MainActor
    static func make(accountAPI: LoopdyLinkAPI, credentials: LoopdyLinkRuntimeCredentials,
                     scope: String, isCurrent: @escaping @MainActor @Sendable () -> Bool) -> Self {
        let broker = LoopdyNotificationBrokerClient(legacyAPI: accountAPI)
        let notificationCredentials = LoopdyManagedNotificationCredentials.legacy(credentials)
        return Self(scope: scope, isCurrent: isCurrent, refresh: {
            guard isCurrent() else { throw CancellationError() }
            try await LoopdyBuzzKitRuntime.shared.identify(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            _ = try await LoopdyBuzzKitRuntime.shared.refreshProviderReadiness(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            return .current
        }, register: {
            guard isCurrent() else { throw CancellationError() }
            try await LoopdyBuzzKitRuntime.shared.identify(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            try await LoopdyBuzzKitRuntime.shared.registerCurrentDevice()
            guard isCurrent() else { throw CancellationError() }
            return .current
        }, test: {
            guard isCurrent() else { throw CancellationError() }
            let body = try JSONEncoder().encode(LoopdyJSONValue.object([
                "version": .integer(1), "requestId": .string(UUID().uuidString.lowercased()),
            ]))
            let response = try await broker.managedNotificationRequest(
                path: LoopdyManagedNotificationService.root + "/buzzkit/test", method: "POST",
                body: body, credentials: notificationCredentials
            )
            guard isCurrent() else { throw CancellationError() }
            struct Envelope: Decodable { let version: Int; let test: LoopdyNotificationTestReceipt }
            let result = try ManagedNotificationValidation.decode(Envelope.self, from: response)
            guard result.version == 1, !result.test.id.isEmpty, result.test.id.utf8.count <= 128,
                  result.test.providerStatus.utf8.count <= 64 else { throw DirectHermesError.invalidResponse }
            return result.test
        })
    }
}

private struct LoopdyNotificationContextKey: EnvironmentKey {
    static let defaultValue: LoopdyNotificationContext? = nil
}
extension EnvironmentValues {
    var loopdyNotificationContext: LoopdyNotificationContext? {
        get { self[LoopdyNotificationContextKey.self] }
        set { self[LoopdyNotificationContextKey.self] = newValue }
    }
}
