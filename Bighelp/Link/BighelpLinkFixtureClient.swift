import Foundation

enum BighelpLinkFixtureFailure: Hashable, Sendable {
    case list
    case rename(String)
    case unpair(String)
}

@MainActor
final class BighelpLinkFixtureClient: BighelpLinkDeviceClient {
    static let defaultDevices = [
        BighelpLinkDevice(
            id: "phone-1",
            name: "This iPhone",
            kind: .phone,
            isCurrentDevice: true,
            connection: .online,
            pushState: nil,
            lastSeenAt: Date(),
            revision: 3
        ),
        BighelpLinkDevice(
            id: "tablet-1",
            name: "Shared iPad",
            kind: .tablet,
            isCurrentDevice: false,
            connection: .recent,
            pushState: nil,
            lastSeenAt: Date().addingTimeInterval(-1_800),
            revision: 2
        ),
        BighelpLinkDevice(
            id: "host-1",
            name: "Home Hermes",
            kind: .hermesHost,
            isCurrentDevice: false,
            connection: .online,
            pushState: nil,
            lastSeenAt: Date(),
            revision: 7
        ),
    ]

    static let multiHostDevices = defaultDevices + [
        BighelpLinkDevice(
            id: "host-2",
            name: "Studio Hermes",
            kind: .hermesHost,
            isCurrentDevice: false,
            connection: .online,
            pushState: nil,
            lastSeenAt: Date(),
            revision: 1
        ),
    ]

    private var devices: [BighelpLinkDevice]
    private let failures: Set<BighelpLinkFixtureFailure>

    private let pairingChallenge: BighelpLinkPairingChallenge

    init(
        devices: [BighelpLinkDevice] = BighelpLinkFixtureClient.defaultDevices,
        failures: Set<BighelpLinkFixtureFailure> = [],

        pairingChallenge: BighelpLinkPairingChallenge? = nil
    ) {
        self.devices = devices
        self.failures = failures

        self.pairingChallenge = pairingChallenge ?? BighelpLinkPairingChallenge(
            id: "fixture-pairing",
            code: "ABC123",
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    func listDevices() async throws -> [BighelpLinkDevice] {
        if failures.contains(.list) { throw FixtureError.requestFailed }
        return devices
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> BighelpLinkDevice {
        if failures.contains(.rename(id)) { throw FixtureError.requestFailed }
        guard let index = devices.firstIndex(where: { $0.id == id }) else {
            throw FixtureError.notFound
        }
        guard devices[index].revision == expectedRevision else {
            throw FixtureError.staleRevision
        }
        devices[index].name = name
        devices[index].revision += 1
        return devices[index]
    }

    func unpairDevice(id: String, expectedRevision: Int) async throws {
        if failures.contains(.unpair(id)) { throw FixtureError.requestFailed }
        guard let index = devices.firstIndex(where: { $0.id == id }) else {
            throw FixtureError.notFound
        }
        guard devices[index].revision == expectedRevision else {
            throw FixtureError.staleRevision
        }
        devices.remove(at: index)
    }

    func beginPairing() async throws -> BighelpLinkPairingChallenge {
        pairingChallenge
    }

    func completePairing(
        reference: BighelpLinkPairingReference
    ) async throws -> BighelpLinkDevice {
        guard reference.hasValidVerification else { throw FixtureError.requestFailed }
        guard reference.flowID == nil || reference.flowID == pairingChallenge.id else {
            throw FixtureError.notFound
        }
        guard
            BighelpLinkPairingCode.normalized(reference.code)
                == BighelpLinkPairingCode.normalized(pairingChallenge.code)
        else {
            throw FixtureError.requestFailed
        }
        if let paired = devices.first(where: { $0.id == "paired-host" }) {
            return paired
        }
        let paired = BighelpLinkDevice(
            id: "paired-host",
            name: "Paired Hermes",
            kind: .hermesHost,
            isCurrentDevice: false,
            connection: .online,
            pushState: nil,
            lastSeenAt: Date(),
            revision: 1
        )
        devices.append(paired)
        return paired
    }

}

private extension BighelpLinkFixtureClient {
    enum FixtureError: Error {
        case requestFailed
        case notFound
        case staleRevision
    }
}
