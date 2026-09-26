import Foundation

enum BighelpLinkProductionClientError: Error, Equatable {
    case signedOut
}

@MainActor
final class BighelpLinkProductionClient: BighelpLinkDeviceClient {
    private let api: any BighelpLinkDeviceAPI
    private let vault: any BighelpLinkCredentialVault
    private let now: () -> Date

    init(
        api: any BighelpLinkDeviceAPI,
        vault: any BighelpLinkCredentialVault,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.vault = vault
        self.now = now
    }

    func listDevices() async throws -> [BighelpLinkDevice] {
        try await api.listDevices(credentials: credentials())
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> BighelpLinkDevice {
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

    func beginPairing() async throws -> BighelpLinkPairingChallenge {
        _ = try credentials()
        return BighelpLinkPairingChallenge(
            id: "loopdy-link-host-pairing",
            code: "",
            expiresAt: now().addingTimeInterval(600)
        )
    }

    func completePairing(
        reference: BighelpLinkPairingReference
    ) async throws -> BighelpLinkDevice {
        try await api.approvePairing(
            reference: reference,
            hostName: "Hermes host",
            credentials: credentials()
        )
    }

    private func credentials() throws -> BighelpLinkRuntimeCredentials {
        guard let credentials = try vault.load() else {
            throw BighelpLinkProductionClientError.signedOut
        }
        return credentials
    }
}
