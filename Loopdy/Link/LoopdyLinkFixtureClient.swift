import Foundation

enum LoopdyLinkFixtureFailure: Hashable, Sendable {
    case list
    case rename(String)
    case unpair(String)
}

@MainActor
final class LoopdyLinkFixtureClient: LoopdyLinkDeviceClient {
    static let defaultDevices = [
        LoopdyLinkDevice(
            id: "phone-1",
            name: "This iPhone",
            kind: .phone,
            isCurrentDevice: true,
            connection: .online,
            pushState: nil,
            lastSeenAt: Date(),
            revision: 3
        ),
        LoopdyLinkDevice(
            id: "tablet-1",
            name: "Shared iPad",
            kind: .tablet,
            isCurrentDevice: false,
            connection: .recent,
            pushState: nil,
            lastSeenAt: Date().addingTimeInterval(-1_800),
            revision: 2
        ),
        LoopdyLinkDevice(
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
        LoopdyLinkDevice(
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

    private var devices: [LoopdyLinkDevice]
    private let failures: Set<LoopdyLinkFixtureFailure>

    private let pairingChallenge: LoopdyLinkPairingChallenge

    init(
        devices: [LoopdyLinkDevice] = LoopdyLinkFixtureClient.defaultDevices,
        failures: Set<LoopdyLinkFixtureFailure> = [],

        pairingChallenge: LoopdyLinkPairingChallenge? = nil
    ) {
        self.devices = devices
        self.failures = failures

        self.pairingChallenge = pairingChallenge ?? LoopdyLinkPairingChallenge(
            id: "fixture-pairing",
            code: "ABC123",
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    func listDevices() async throws -> [LoopdyLinkDevice] {
        if failures.contains(.list) { throw FixtureError.requestFailed }
        return devices
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> LoopdyLinkDevice {
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

    func beginPairing() async throws -> LoopdyLinkPairingChallenge {
        pairingChallenge
    }

    func completePairing(
        reference: LoopdyLinkPairingReference
    ) async throws -> LoopdyLinkDevice {
        guard reference.hasValidVerification else { throw FixtureError.requestFailed }
        guard reference.flowID == nil || reference.flowID == pairingChallenge.id else {
            throw FixtureError.notFound
        }
        guard
            LoopdyLinkPairingCode.normalized(reference.code)
                == LoopdyLinkPairingCode.normalized(pairingChallenge.code)
        else {
            throw FixtureError.requestFailed
        }
        if let paired = devices.first(where: { $0.id == "paired-host" }) {
            return paired
        }
        let paired = LoopdyLinkDevice(
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

private extension LoopdyLinkFixtureClient {
    enum FixtureError: Error {
        case requestFailed
        case notFound
        case staleRevision
    }
}
