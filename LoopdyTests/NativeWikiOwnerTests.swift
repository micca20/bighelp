import Foundation
import Testing
@testable import Loopdy

@MainActor
struct NativeWikiOwnerTests {
    @Test func legacyLinkEncodingAndProtectedFilenameInputRemainExact() throws {
        let owner = WikiOwner(accountID: "account", hostID: "host", profileID: "default", deviceID: "device", authorizationEpoch: "7")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(owner)
        let expected = #"{"accountID":"account","authorizationEpoch":"7","deviceID":"device","hostID":"host","profileID":"default"}"#
        #expect(data == Data(expected.utf8))
        #expect(try JSONDecoder().decode(WikiOwner.self, from: data) == owner)
        #expect(owner.deviceID == "device")
        #expect(owner.authorizationEpoch == "7")
        #expect(!owner.isNative)
    }

    @Test func nativeOwnerHasNoInventedAccountDeviceOrEpochInItsEncoding() throws {
        let owner = try native()
        let data = try JSONEncoder().encode(owner)
        let object = try JSONDecoder().decode([String: LoopdyJSONValue].self, from: data)
        #expect(Set(object.keys) == ["authorityKind", "endpointID", "providerID", "principalID", "profileID"])
        #expect(object["authorityKind"] == .string("native_principal"))
        #expect(owner.deviceID == nil)
        #expect(owner.authorizationEpoch == nil)
        #expect(owner.accountID.hasPrefix("native-wiki-"))
        #expect(try JSONDecoder().decode(WikiOwner.self, from: data) == owner)
    }

    @Test func nativeNamespaceSeparatesHostProviderPersonAndProfile() throws {
        let owner = try native()
        let person = try native(person: "another")
        let provider = try native(provider: "another-provider")
        let host = try native(endpoint: "https://another.example")
        let profile = try native(profile: "writing")
        #expect(Set([owner, person, provider, host, profile]).count == 5)
        #expect(Set([owner.accountID, person.accountID, provider.accountID, host.accountID]).count == 4)
        #expect(owner.accountID == profile.accountID)
    }

    @Test func opaqueNativePrincipalsUseByteExactEquality() throws {
        let composed = try native(person: "caf\u{00E9}")
        let decomposed = try native(person: "cafe\u{0301}")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(composed.accountID != decomposed.accountID)
    }

    @Test func nativeOwnerCannotBeManufacturedFromLinkOrFixtureAuthority() throws {
        let fixture = try WorkspaceAuthority.fixture(id: "not-a-native-login")
        #expect(throws: WikiError.ownerChanged) { try WikiOwner.native(authority: fixture, profileID: "default") }
    }

    @Test func hybridOrFutureAuthorityCannotDecodeAsLegacyLink() throws {
        var payload = try JSONDecoder().decode([String: LoopdyJSONValue].self, from: JSONEncoder().encode(native()))
        payload["deviceID"] = .string("fake-device")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WikiOwner.self, from: JSONEncoder().encode(payload))
        }
        payload.removeValue(forKey: "deviceID")
        payload["authorityKind"] = .string("future")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WikiOwner.self, from: JSONEncoder().encode(payload))
        }
    }

    @Test func sharedNativeCodecAddsOnlyAgentCoordinateNotLinkFraming() async throws {
        let owner = try native()
        let probe = NativeWikiRequestProbe(owner: owner)
        let client = WikiLinkClient(owner: owner, nativeRequest: probe.request, currentOwner: { probe.currentOwner })
        #expect(try await client.roots().first?.wikiId == "wiki_notes")
        #expect(probe.calls.count == 1)
        #expect(probe.calls[0].operation == .wikiRoots)
        #expect(probe.calls[0].payload == ["agentId": .string("default")])
    }

    @Test func nativeCodecRejectsLegacyOwnerBeforeRequest() async throws {
        let owner = WikiOwner(accountID: "a", hostID: "h", profileID: "default", deviceID: "d", authorizationEpoch: "1")
        let probe = NativeWikiRequestProbe(owner: owner)
        let client = WikiLinkClient(owner: owner, nativeRequest: probe.request, currentOwner: { probe.currentOwner })
        await #expect(throws: WikiError.ownerChanged) { try await client.roots() }
        #expect(probe.calls.isEmpty)
    }

    @Test func lateNativeResponseCannotCrossPrincipalReplacement() async throws {
        let owner = try native()
        let probe = NativeWikiRequestProbe(owner: owner)
        probe.replacement = try native(person: "another")
        let client = WikiLinkClient(owner: owner, nativeRequest: probe.request, currentOwner: { probe.currentOwner })
        await #expect(throws: WikiError.ownerChanged) { try await client.roots() }
    }

    @Test func nativeErrorsPreserveSafeAuthorityConflictAndUncertainSaveMeaning() {
        #expect(WikiError.safe(WorkspaceClientError.rejected(code: "WIKI_AUTHORITY_CONFLICT")) == .remote("WIKI_AUTHORITY_CONFLICT"))
        #expect(WikiError.safe(WorkspaceClientError.outcomeUnknown) == .remote("OPERATION_UNCONFIRMED"))
        #expect(WikiError.remote("WIKI_AUTHORITY_CONFLICT").localizedDescription.contains("will not adopt"))
    }

    private func native(person: String = "synthetic-person", provider: String = "password",
                        endpoint: String = "https://hermes.example", profile: String = "default") throws -> WikiOwner {
        try .native(authority: .direct(endpointIdentity: endpoint, providerID: provider, userID: person), profileID: profile)
    }
}

@MainActor
private final class NativeWikiRequestProbe {
    struct Call { let operation: LoopdyLinkWorkspaceOperation; let payload: [String: LoopdyJSONValue] }
    var currentOwner: WikiOwner?
    var replacement: WikiOwner?
    var calls: [Call] = []

    init(owner: WikiOwner) { currentOwner = owner }

    func request(_ operation: LoopdyLinkWorkspaceOperation, _ payload: [String: LoopdyJSONValue]) async throws -> [String: LoopdyJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        if let replacement { currentOwner = replacement }
        return ["roots": .array([.object([
            "wikiId": .string("wiki_notes"), "name": .string("Notes"), "writable": .boolean(true),
            "sourceKind": .string("files"), "generation": .string(String(repeating: "a", count: 32)),
            "folderPath": .string("/notes"), "supportsCreation": .boolean(true)
        ])])]
    }
}
