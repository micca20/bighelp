import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpLinkProductionClientTests {
    @Test func productionClientUsesOnlyTheVaultDeviceIdentityForSignedOperations() async throws {
        let credentials = Self.credentials
        let vault = BighelpLinkMemoryCredentialVault()
        try vault.save(credentials)
        let api = DeviceAPIStub(device: Self.phone)
        let client = BighelpLinkProductionClient(
            api: api,
            vault: vault,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        _ = try await client.listDevices()
        _ = try await client.renameDevice(id: "mobile-device", name: "Travel iPhone", expectedRevision: 1)
        try await client.unpairDevice(id: "old-device", expectedRevision: 3)

        #expect(api.credentialDeviceIDs == ["mobile-device", "mobile-device", "mobile-device"])
    }

    @Test func qrPairingReferenceAndAccountKeyAreForwardedToTheSignedApproval() async throws {
        let vault = BighelpLinkMemoryCredentialVault()
        try vault.save(Self.credentials)
        let api = DeviceAPIStub(device: Self.host)
        let client = BighelpLinkProductionClient(
            api: api,
            vault: vault,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        let reference = BighelpLinkPairingReference(
            flowID: "flow_fixture_0123456789012345",
            code: "ABC123"
        )

        let challenge = try await client.beginPairing()
        let host = try await client.completePairing(reference: reference)

        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_788_000_600))
        #expect(host.id == "host-device")
        #expect(api.pairingReference == reference)
        #expect(api.pairingHostName == "Hermes host")
    }

    private static let credentials = BighelpLinkRuntimeCredentials(
        deviceID: "mobile-device",
        authorizationEpoch: 1,
        signingPrivateKey: P256.Signing.PrivateKey(),
        accountKey: Data(repeating: 0x99, count: 32)
    )

    private static let phone = BighelpLinkDevice(
        id: "mobile-device",
        name: "This iPhone",
        kind: .phone,
        isCurrentDevice: true,
        connection: .online,
        pushState: nil,
        lastSeenAt: nil,
        revision: 1
    )

    private static let phoneReady = BighelpLinkDevice(
        id: "mobile-device",
        name: "This iPhone",
        kind: .phone,
        isCurrentDevice: true,
        connection: .online,
        pushState: nil,
        pushRevision: 5,
        lastSeenAt: nil,
        revision: 1
    )

    private static let host = BighelpLinkDevice(
        id: "host-device",
        name: "Hermes host",
        kind: .hermesHost,
        isCurrentDevice: false,
        connection: .online,
        pushState: nil,
        lastSeenAt: nil,
        revision: 1
    )
}

@MainActor
private final class DeviceAPIStub: BighelpLinkDeviceAPI {
    let device: BighelpLinkDevice
    private(set) var credentialDeviceIDs: [String] = []
    private(set) var pairingReference: BighelpLinkPairingReference?
    private(set) var pairingHostName: String?

    init(device: BighelpLinkDevice) { self.device = device }

    func listDevices(credentials: BighelpLinkRuntimeCredentials) async throws -> [BighelpLinkDevice] {
        credentialDeviceIDs.append(credentials.deviceID)
        return [device]
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int,
        credentials: BighelpLinkRuntimeCredentials
    ) async throws -> BighelpLinkDevice {
        credentialDeviceIDs.append(credentials.deviceID)
        return device
    }

    func unpairDevice(
        id: String,
        expectedRevision: Int,
        credentials: BighelpLinkRuntimeCredentials
    ) async throws {
        credentialDeviceIDs.append(credentials.deviceID)
    }

    func approvePairing(
        reference: BighelpLinkPairingReference,
        hostName: String,
        credentials: BighelpLinkRuntimeCredentials
    ) async throws -> BighelpLinkDevice {
        pairingReference = reference
        pairingHostName = hostName
        return device
    }

}
