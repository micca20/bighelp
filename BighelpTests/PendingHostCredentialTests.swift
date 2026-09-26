import Foundation
import Testing
@testable import Bighelp

@MainActor
struct PendingHostCredentialTests {
    private func connection() throws -> DirectHermesSavedConnection {
        .init(endpoint: try DirectHermesEndpoint(address: "https://onboarding.example.test:9443"),
              authentication: .dashboardSession(token: "[REDACTED]", automatic: false))
    }

    @Test func pendingAuthenticationNeverCreatesAKeychainItem() throws {
        let service = "app.loopdy.test.pending." + UUID().uuidString
        let pending = DirectHermesKeychainVault(service: service, stagesUntilCommit: true)
        let disk = DirectHermesKeychainVault(service: service)
        defer { try? disk.delete() }
        let saved = try connection()
        try pending.save(saved)
        #expect(try pending.load() == saved)
        #expect(try disk.load() == nil)
        pending.invalidate()
        #expect(throws: DirectHermesError.self) { try pending.load() }
        #expect(try disk.load() == nil)
    }

    @Test func verifiedCommitPersistsAndSubsequentRotationUsesKeychain() throws {
        let service = "app.loopdy.test.committed." + UUID().uuidString
        let pending = DirectHermesKeychainVault(service: service, stagesUntilCommit: true)
        let disk = DirectHermesKeychainVault(service: service)
        defer { try? disk.delete() }
        var saved = try connection()
        try pending.save(saved)
        try pending.bindIdentity(saved.identity)
        #expect(try disk.load() == nil)
        try pending.commitStagedCredentials()
        #expect(try disk.load() == saved)
        #expect(pending.requiresRegistryReference)
        saved.authentication = .dashboardSession(token: "[REDACTED]-rotated-test", automatic: false)
        try pending.save(saved)
        #expect(try disk.load() == saved)
        try pending.delete()
        #expect(try disk.load() == nil)
    }

    @Test func discardedOrEmptyPendingVaultCannotBeCommitted() throws {
        let service = "app.loopdy.test.discarded." + UUID().uuidString
        let pending = DirectHermesKeychainVault(service: service, stagesUntilCommit: true)
        let disk = DirectHermesKeychainVault(service: service)
        defer { try? disk.delete() }
        #expect(throws: DirectHermesError.self) { try pending.commitStagedCredentials() }
        try pending.save(connection())
        try pending.delete()
        #expect(try pending.load() == nil)
        #expect(try disk.load() == nil)
        #expect(throws: DirectHermesError.self) { try pending.commitStagedCredentials() }
    }
}
