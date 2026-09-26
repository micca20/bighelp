import Foundation
import Testing
@testable import Bighelp

struct WorkspaceFoundationTests {
    private func owner(_ authority: WorkspaceAuthority,
                       authenticationGeneration: UUID = UUID(),
                       connectionGeneration: UUID = UUID()) -> WorkspaceOwner {
        WorkspaceOwner(authority: authority, authenticationGeneration: authenticationGeneration,
                       connectionGeneration: connectionGeneration)
    }

    @Test func endpointAndPrincipalOwnIndependentCaches() throws {
        let first = try WorkspaceAuthority.direct(endpointIdentity: "https://EXAMPLE.test:443/",
                                                  providerID: "password", userID: "person")
        let normalized = try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                                       providerID: "password", userID: "person")
        let otherPerson = try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                                       providerID: "password", userID: "other")
        let otherHost = try WorkspaceAuthority.direct(endpointIdentity: "https://other.test",
                                                     providerID: "password", userID: "person")
        #expect(first == normalized)
        #expect(first.cacheScopeID != otherPerson.cacheScopeID)
        #expect(first.cacheScopeID != otherHost.cacheScopeID)
        #expect(first.cacheScopeID.count == 64)
        #expect(try JSONDecoder().decode(WorkspaceAuthority.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test func transportAndAuthorizationAreNotDisplayAliases() throws {
        let direct = try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                                   providerID: "password", userID: "person")
        let link = try WorkspaceAuthority.link(origin: "https://example.test", deviceID: "person",
                                               deviceAuthorizationEpoch: 1, hostID: "host",
                                               hostAuthorizationEpoch: 1)
        let revoked = try WorkspaceAuthority.link(origin: "https://example.test", deviceID: "person",
                                                  deviceAuthorizationEpoch: 2, hostID: "host",
                                                  hostAuthorizationEpoch: 1)
        #expect(direct.cacheScopeID != link.cacheScopeID)
        #expect(link.cacheScopeID != revoked.cacheScopeID)
    }

    @Test func opaquePrincipalIdentityIsByteExactRatherThanDisplayEquivalent() throws {
        let composed = try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                                     providerID: "password", userID: "caf\u{e9}")
        let decomposed = try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                                       providerID: "password", userID: "cafe\u{301}")
        #expect(composed != decomposed)
        #expect(composed.cacheScopeID != decomposed.cacheScopeID)
        #expect(Set([composed, decomposed]).count == 2)
    }

    @Test func reconnectRetainsCacheButInvalidatesCapabilitySnapshot() throws {
        let authority = try WorkspaceAuthority.fixture(id: "test-host")
        let initial = owner(authority)
        let reconnected = owner(authority, authenticationGeneration: initial.authenticationGeneration)
        let capabilities = WorkspaceCapabilities(owner: initial, values: [.groupsSend: .available])
        #expect(initial.cacheScopeID == reconnected.cacheScopeID)
        #expect(initial != reconnected)
        #expect(capabilities.supports(.groupsSend, owner: initial))
        #expect(!capabilities.supports(.groupsSend, owner: reconnected))
        #expect(capabilities.availability(for: .groupsRead, owner: initial) == .unknown)
    }

    @Test func capabilitiesRespectProfileAndDisconnectedOwnership() throws {
        let initial = owner(try .fixture(id: "test-host"))
        let capabilities = WorkspaceCapabilities(
            owner: initial, values: [.profilesEdit: .available],
            profileValues: ["restricted": [.profilesEdit: .unavailable(.policyRestricted)]]
        )
        #expect(capabilities.supports(.profilesEdit, owner: initial, profileID: "default"))
        #expect(!capabilities.supports(.profilesEdit, owner: initial, profileID: "restricted"))
        #expect(!WorkspaceCapabilities.disconnected.supports(.profilesEdit, owner: initial))
    }

    @Test(arguments: ["", " person", "person\n", String(repeating: "a", count: 513)])
    func malformedPrincipalCannotOwnWorkspace(value: String) {
        #expect(throws: WorkspaceClientError.self) {
            try WorkspaceAuthority.direct(endpointIdentity: "https://example.test",
                                          providerID: "password", userID: value)
        }
    }

    @Test func decodingCannotSmuggleLinkEpochIntoDirectPrincipal() throws {
        let invalid = Data("""
        {"kind":"direct","endpointIdentity":"https://example.test","principalID":"person",
         "providerID":"password","hostID":"https://example.test","deviceAuthorizationEpoch":1}
        """.utf8)
        #expect(throws: WorkspaceClientError.self) {
            try JSONDecoder().decode(WorkspaceAuthority.self, from: invalid)
        }
    }

    @Test func operationCatalogIsFiniteAndUnambiguous() {
        #expect(Set(WorkspaceOperation.allCases.map(\.rawValue)).count == WorkspaceOperation.allCases.count)
        #expect(WorkspaceOperation(rawValue: "arbitrary.execute") == nil)
        #expect(WorkspaceOperation.subagentsList.rawValue == "subagent.list")
        #expect(WorkspaceOperation.groupsLog.rawValue == "groups.log")
    }
}
