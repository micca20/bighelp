import CryptoKit
import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyNotificationIdentityInstallationScopeTests {
    @Test
    func legacyLinkPresenceStillResolvesNotificationOnlyCredentials() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let legacyVault = LoopdyLinkMemoryCredentialVault()
        let legacy = LoopdyLinkRuntimeCredentials(
            deviceID: "legacy-account-device",
            authorizationEpoch: 7,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x5a, count: 32)
        )
        try legacyVault.save(legacy)
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: legacyVault,
            transport: transport
        )

        let credentials = try await coordinator.resolveForEnrollment()

        #expect(credentials.authority == .notificationOnly)
        #expect(credentials.subscriberScope == "notification-instance")
        #expect(credentials.deviceID != legacy.deviceID)
        #expect(transport.legacyRetirementRequests == 1)
        #expect(transport.requestOrder == ["retire-legacy", "bootstrap"])
        #expect(transport.bootstrapRequests == 1)
        #expect(try legacyVault.load() == legacy, "Notification setup must preserve Link chat credentials")
        #expect(try coordinator.current() == credentials)
    }

    @Test
    func currentDoesNotAuthorizeLegacyLinkCredentialsAsNotificationIdentity() throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let legacyVault = LoopdyLinkMemoryCredentialVault()
        try legacyVault.save(.init(
            deviceID: "legacy-account-device",
            authorizationEpoch: 3,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x33, count: 32)
        ))
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: legacyVault,
            transport: NotificationBootstrapTransport()
        )

        #expect(try coordinator.current() == nil)
    }

    @Test
    func failedLegacyRetirementBlocksReplacementBootstrap() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let legacyVault = LoopdyLinkMemoryCredentialVault()
        let legacy = LoopdyLinkRuntimeCredentials(
            deviceID: "legacy-account-device",
            authorizationEpoch: 9,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x44, count: 32)
        )
        try legacyVault.save(legacy)
        let transport = NotificationBootstrapTransport()
        transport.legacyRetirementError = DirectHermesError.invalidResponse
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: legacyVault,
            transport: transport
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.resolveForEnrollment()
        }
        #expect(transport.legacyRetirementRequests == 1)
        #expect(transport.bootstrapRequests == 0)
        #expect(notificationVault.value == .none)
        #expect(try legacyVault.load() == legacy)

        transport.legacyRetirementError = nil
        let recovered = try await coordinator.resolveForEnrollment()
        #expect(recovered.authority == .notificationOnly)
        #expect(transport.legacyRetirementRequests == 2)
        #expect(transport.bootstrapRequests == 1)
        #expect(try coordinator.current() == recovered)
        #expect(try legacyVault.load() == legacy)
    }

    @Test
    func everyEnrollmentResolutionRetiresLegacyAuthorityEvenWithActiveInstallation() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let legacyVault = LoopdyLinkMemoryCredentialVault()
        let legacy = LoopdyLinkRuntimeCredentials(
            deviceID: "legacy-account-device",
            authorizationEpoch: 11,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x55, count: 32)
        )
        try legacyVault.save(legacy)
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: legacyVault,
            transport: transport
        )

        let first = try await coordinator.resolveForEnrollment()
        let second = try await coordinator.resolveForEnrollment()

        #expect(second == first)
        #expect(transport.legacyRetirementRequests == 2)
        #expect(transport.bootstrapRequests == 1)
        #expect(transport.requestOrder == ["retire-legacy", "bootstrap", "retire-legacy"])
        #expect(try legacyVault.load() == legacy, "Repeated retirement must preserve Link chat credentials")
    }

    @Test
    func explicitEnrollmentReplacesOnlyAnAuthoritativelyRevokedInstallation() async throws {
        let revoked = LoopdyManagedNotificationCredentials(
            authority: .notificationOnly,
            deviceID: UUID().uuidString.lowercased(),
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey()
        )
        let notificationVault = MemoryNotificationIdentityVault(value: .current(.active(revoked)))
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: LoopdyLinkMemoryCredentialVault(),
            transport: transport
        )

        let replacement = try await coordinator.replaceRevokedForEnrollment(expected: revoked)

        #expect(replacement.deviceID != revoked.deviceID)
        #expect(replacement.authorizationEpoch == 1)
        #expect(transport.bootstrapRequests == 1)
        #expect(try coordinator.current() == replacement)
    }

    @Test
    func failedLegacyRetirementBlocksExistingInstallationResolution() async throws {
        let active = LoopdyManagedNotificationCredentials(
            authority: .notificationOnly,
            deviceID: UUID().uuidString.lowercased(),
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey()
        )
        let original = LoopdyNotificationIdentityLoad.current(.active(active))
        let notificationVault = MemoryNotificationIdentityVault(value: original)
        let legacyVault = LoopdyLinkMemoryCredentialVault()
        let legacy = LoopdyLinkRuntimeCredentials(
            deviceID: "legacy-account-device",
            authorizationEpoch: 12,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x66, count: 32)
        )
        try legacyVault.save(legacy)
        let transport = NotificationBootstrapTransport()
        transport.legacyRetirementError = DirectHermesError.invalidResponse
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: legacyVault,
            transport: transport
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.resolveForEnrollment()
        }

        #expect(transport.legacyRetirementRequests == 1)
        #expect(transport.bootstrapRequests == 0)
        #expect(notificationVault.value == original)
        #expect(try legacyVault.load() == legacy)
    }

    @Test
    func currentRejectsLegacyAuthorityInNotificationVault() throws {
        let legacy = LoopdyManagedNotificationCredentials(
            authority: .legacyAccount,
            deviceID: "legacy-account-device",
            authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey()
        )
        let notificationVault = MemoryNotificationIdentityVault(value: .current(.active(legacy)))
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: LoopdyLinkMemoryCredentialVault(),
            transport: NotificationBootstrapTransport()
        )

        #expect(throws: DirectHermesError.invalidCredentials) {
            _ = try coordinator.current()
        }
    }

    @Test
    func erasePreservesLegacyAuthorityWhenItCannotSafelyRevoke() async throws {
        let legacy = LoopdyManagedNotificationCredentials(
            authority: .legacyAccount,
            deviceID: "legacy-account-device",
            authorizationEpoch: 2,
            signingPrivateKey: P256.Signing.PrivateKey()
        )
        let original = LoopdyNotificationIdentityLoad.current(.active(legacy))
        let notificationVault = MemoryNotificationIdentityVault(value: original)
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: LoopdyLinkMemoryCredentialVault(),
            transport: NotificationBootstrapTransport()
        )

        await #expect(throws: DirectHermesError.invalidCredentials) {
            try await coordinator.erase()
        }
        #expect(notificationVault.value == original,
                "Unknown legacy authority must remain durable when authoritative revocation is unavailable")
    }

    @Test
    func concurrentEnrollmentResolutionsShareOneBootstrap() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        transport.suspendBootstrapResponses()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: LoopdyLinkMemoryCredentialVault(),
            transport: transport
        )

        let first = Task { @MainActor in try await coordinator.resolveForEnrollment() }
        await transport.waitForBootstrapRequests(1)

        let secondStarted = IdentityOperationStartSignal()
        let second = Task { @MainActor in
            secondStarted.signal()
            return try await coordinator.resolveForEnrollment()
        }
        await secondStarted.wait()

        let requestsWhileFirstWasSuspended = transport.bootstrapRequests
        transport.resumeAllBootstrapResponses()
        let firstCredentials = try await first.value
        let secondCredentials = try await second.value

        #expect(requestsWhileFirstWasSuspended == 1,
                "A concurrent resolver must join or wait for the suspended bootstrap")
        #expect(transport.bootstrapRequests == 1)
        #expect(firstCredentials == secondCredentials)
        #expect(try coordinator.current() == firstCredentials)
    }

    @Test
    func eraseWaitsForSuspendedBootstrapAndLeavesNoActiveIdentity() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        transport.suspendBootstrapResponses()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            legacyVault: LoopdyLinkMemoryCredentialVault(),
            transport: transport
        )

        let resolution = Task { @MainActor in try await coordinator.resolveForEnrollment() }
        await transport.waitForBootstrapRequests(1)

        let eraseStarted = IdentityOperationStartSignal()
        let erasure = Task { @MainActor in
            eraseStarted.signal()
            try await coordinator.erase()
        }
        await eraseStarted.wait()

        let requestsWhileResolutionWasSuspended = transport.bootstrapRequests
        if requestsWhileResolutionWasSuspended == 1 {
            transport.resumeBootstrapResponse(at: 0)
            _ = try await resolution.value
            try await erasure.value
        } else {
            // Drive the old race deterministically: erasure's recovery finishes
            // and deletes first, then the original resolver completes and saves.
            transport.resumeBootstrapResponse(at: 1)
            try await erasure.value
            transport.resumeBootstrapResponse(at: 0)
            _ = try await resolution.value
        }

        #expect(requestsWhileResolutionWasSuspended == 1,
                "Erasure must serialize behind an already-started bootstrap")
        #expect(notificationVault.value == .none,
                "A bootstrap started before erasure must not restore active credentials afterward")
        #expect(try coordinator.current() == nil)
    }

    @Test
    func versionLessIdentityErrorBodyStillSurfacesServerCode() async throws {
        let transport = IdentityErrorTransport()
        let legacyAPI = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.app")!,
            transport: transport,
            managedNotificationTransport: transport
        )
        let broker = LoopdyNotificationBrokerClient(
            legacyAPI: legacyAPI,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nonce: { "fixture-nonce" }
        )
        let credentials = LoopdyManagedNotificationCredentials(
            authority: .notificationOnly,
            deviceID: UUID().uuidString.lowercased(),
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey()
        )

        do {
            _ = try await broker.managedNotificationRequest(
                path: LoopdyManagedNotificationService.root + "/buzzkit/identity",
                method: "GET",
                body: nil,
                credentials: credentials
            )
            Issue.record("Expected the identity request to fail")
        } catch let error as LoopdyLinkAPIError {
            guard case .requestFailed(let status, let code) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(status == 410)
            #expect(code == "notification_credentials_revoked",
                    "The revoked-credentials code must survive so enrollment can retry with fresh credentials")
        }
    }

    private func makeCoordinator(
        notificationVault: MemoryNotificationIdentityVault,
        legacyVault: LoopdyLinkMemoryCredentialVault,
        transport: NotificationBootstrapTransport
    ) -> LoopdyNotificationIdentityCoordinator {
        let legacyAPI = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.app")!,
            transport: transport,
            managedNotificationTransport: transport
        )
        let broker = LoopdyNotificationBrokerClient(
            legacyAPI: legacyAPI,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nonce: { "fixture-nonce" }
        )
        return LoopdyNotificationIdentityCoordinator(
            vault: notificationVault,
            legacyVault: legacyVault,
            broker: broker,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }
}

@MainActor
private final class MemoryNotificationIdentityVault: LoopdyNotificationIdentityVault {
    var value: LoopdyNotificationIdentityLoad

    init(value: LoopdyNotificationIdentityLoad = .none) {
        self.value = value
    }

    func load() throws -> LoopdyNotificationIdentityLoad { value }
    func save(_ record: LoopdyNotificationIdentityRecord) throws { value = .current(record) }
    func delete() throws { value = .none }
}

@MainActor
private final class NotificationBootstrapTransport: LoopdyLinkHTTPTransport {
    private(set) var bootstrapRequests = 0
    private(set) var legacyRetirementRequests = 0
    private(set) var requestOrder: [String] = []
    var legacyRetirementError: (any Error)?
    private var shouldSuspendBootstrapResponses = false
    private var bootstrapResponseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var bootstrapRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspendBootstrapResponses() {
        shouldSuspendBootstrapResponses = true
    }

    func waitForBootstrapRequests(_ count: Int) async {
        guard bootstrapRequests < count else { return }
        await withCheckedContinuation { continuation in
            bootstrapRequestWaiters.append((count, continuation))
        }
    }

    func resumeBootstrapResponse(at index: Int) {
        bootstrapResponseContinuations.removeValue(forKey: index)?.resume()
    }

    func resumeAllBootstrapResponses() {
        shouldSuspendBootstrapResponses = false
        let continuations = Array(bootstrapResponseContinuations.values)
        bootstrapResponseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == LoopdyManagedNotificationService.root + "/buzzkit/identity",
           request.httpMethod == "DELETE",
           request.value(forHTTPHeaderField: "x-loopdy-device-id") == "legacy-account-device",
           let url = request.url,
           let response = HTTPURLResponse(
             url: url,
             statusCode: 200,
             httpVersion: "HTTP/1.1",
             headerFields: ["Content-Type": "application/json"]
           ) {
            legacyRetirementRequests += 1
            requestOrder.append("retire-legacy")
            if let legacyRetirementError { throw legacyRetirementError }
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "identity": ["scope": "account", "state": "revoked"],
            ], options: [.sortedKeys])
            return (responseBody, response)
        }
        if request.url?.path == LoopdyNotificationBrokerClient.currentInstallationPath,
           request.httpMethod == "DELETE",
           let url = request.url,
           let installationID = request.value(forHTTPHeaderField: "x-loopdy-notification-installation"),
           let response = HTTPURLResponse(
             url: url,
             statusCode: 200,
             httpVersion: "HTTP/1.1",
             headerFields: ["Content-Type": "application/json"]
           ) {
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "installation": ["installationId": installationID, "state": "revoked"],
            ], options: [.sortedKeys])
            return (responseBody, response)
        }
        guard request.url?.path == LoopdyNotificationBrokerClient.bootstrapPath,
              request.httpMethod == "POST",
              let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let installationID = object["installationId"] as? String,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw DirectHermesError.invalidResponse
        }
        let requestIndex = bootstrapRequests
        bootstrapRequests += 1
        requestOrder.append("bootstrap")
        let readyWaiters = bootstrapRequestWaiters.filter { bootstrapRequests >= $0.0 }
        bootstrapRequestWaiters.removeAll { bootstrapRequests >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        if shouldSuspendBootstrapResponses {
            await withCheckedContinuation { continuation in
                bootstrapResponseContinuations[requestIndex] = continuation
            }
        }
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "credential": [
                "scope": "notification-only",
                "installationId": installationID,
                "authorizationEpoch": 1,
            ],
        ], options: [.sortedKeys])
        return (responseBody, response)
    }
}

@MainActor
private final class IdentityErrorTransport: LoopdyLinkHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 410,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        // Error bodies are not guaranteed to carry an envelope version.
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "notification_credentials_revoked"],
        ])
        return (body, response)
    }
}

@MainActor
private final class IdentityOperationStartSignal {
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        didStart = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !didStart else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
