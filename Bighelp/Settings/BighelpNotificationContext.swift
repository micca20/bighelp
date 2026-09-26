import Foundation
import SwiftUI

struct BighelpNotificationTestReceipt: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case accepted, failed }
    let id: String
    let state: State
    let providerStatus: String
}

struct BighelpNotificationContext: Sendable {
    let scope: String
    let isCurrent: @MainActor @Sendable () -> Bool
    let refresh: @MainActor @Sendable () async throws -> BighelpNotificationRuntimeSnapshot
    /// Compatibility seam for callers that refresh provider registration
    /// independently. Notification Settings intentionally does not expose it as
    /// enrollment; selected-host enrollment uses HostNotificationSetupModel.
    let register: @MainActor @Sendable () async throws -> BighelpNotificationRuntimeSnapshot
    let test: @MainActor @Sendable () async throws -> BighelpNotificationTestReceipt

    @MainActor
    static func make(
        service: BighelpManagedNotificationService,
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
    static func make(accountAPI: BighelpLinkAPI, credentials: BighelpLinkRuntimeCredentials,
                     scope: String, isCurrent: @escaping @MainActor @Sendable () -> Bool) -> Self {
        let broker = BighelpNotificationBrokerClient(legacyAPI: accountAPI)
        let notificationCredentials = BighelpManagedNotificationCredentials.legacy(credentials)
        return Self(scope: scope, isCurrent: isCurrent, refresh: {
            guard isCurrent() else { throw CancellationError() }
            try await BighelpBuzzKitRuntime.shared.identify(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            _ = try await BighelpBuzzKitRuntime.shared.refreshProviderReadiness(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            return .current
        }, register: {
            guard isCurrent() else { throw CancellationError() }
            try await BighelpBuzzKitRuntime.shared.identify(accountAPI: broker, credentials: notificationCredentials)
            guard isCurrent() else { throw CancellationError() }
            try await BighelpBuzzKitRuntime.shared.registerCurrentDevice()
            guard isCurrent() else { throw CancellationError() }
            return .current
        }, test: {
            guard isCurrent() else { throw CancellationError() }
            let body = try JSONEncoder().encode(BighelpJSONValue.object([
                "version": .integer(1), "requestId": .string(UUID().uuidString.lowercased()),
            ]))
            let response = try await broker.managedNotificationRequest(
                path: BighelpManagedNotificationService.root + "/buzzkit/test", method: "POST",
                body: body, credentials: notificationCredentials
            )
            guard isCurrent() else { throw CancellationError() }
            struct Envelope: Decodable { let version: Int; let test: BighelpNotificationTestReceipt }
            let result = try ManagedNotificationValidation.decode(Envelope.self, from: response)
            guard result.version == 1, !result.test.id.isEmpty, result.test.id.utf8.count <= 128,
                  result.test.providerStatus.utf8.count <= 64 else { throw DirectHermesError.invalidResponse }
            return result.test
        })
    }
}

private struct BighelpNotificationContextKey: EnvironmentKey {
    static let defaultValue: BighelpNotificationContext? = nil
}
extension EnvironmentValues {
    var bighelpNotificationContext: BighelpNotificationContext? {
        get { self[BighelpNotificationContextKey.self] }
        set { self[BighelpNotificationContextKey.self] = newValue }
    }
}
