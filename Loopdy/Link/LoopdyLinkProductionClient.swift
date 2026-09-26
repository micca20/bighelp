import Foundation

enum LoopdyLinkProductionClientError: Error, Equatable {
    case signedOut
}

@MainActor
final class LoopdyLinkProductionClient: LoopdyLinkDeviceClient {
    private let api: any LoopdyLinkDeviceAPI
    private let vault: any LoopdyLinkCredentialVault
    private let now: () -> Date

    init(
        api: any LoopdyLinkDeviceAPI,
        vault: any LoopdyLinkCredentialVault,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.vault = vault
        self.now = now
    }

    func listDevices() async throws -> [LoopdyLinkDevice] {
        try await api.listDevices(credentials: credentials())
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> LoopdyLinkDevice {
        try await api.renameDevice(
            id: id,
            name: name,
            expectedRevision: expectedRevision,
            credentials: credentials()
        )
    }

    func unpairDevice(id: String, expectedRevision: Int) async throws {
        let established = try credentials()
        try await api.unpairDevice(
            id: id,
            expectedRevision: expectedRevision,
            credentials: established
        )
        if id == established.deviceID {
            try vault.delete()
        }
    }

    func beginPairing() async throws -> LoopdyLinkPairingChallenge {
        _ = try credentials()
        return LoopdyLinkPairingChallenge(
            id: "loopdy-link-host-pairing",
            code: "",
            expiresAt: now().addingTimeInterval(600)
        )
    }

    func completePairing(
        reference: LoopdyLinkPairingReference
    ) async throws -> LoopdyLinkDevice {
        try await api.approvePairing(
            reference: reference,
            hostName: "Hermes host",
            credentials: credentials()
        )
    }

    private func credentials() throws -> LoopdyLinkRuntimeCredentials {
        guard let credentials = try vault.load() else {
            throw LoopdyLinkProductionClientError.signedOut
        }
        return credentials
    }
}
