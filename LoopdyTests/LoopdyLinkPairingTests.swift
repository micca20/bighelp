import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyLinkPairingTests {
    @Test func pairingPresentationNeverDisclosesTheFixtureCode() {
        let challenge = LoopdyLinkPairingChallenge(
            id: "flow_fixture_0123456789012345",
            code: "ABC123",
            expiresAt: Date(timeIntervalSince1970: 1_788_000_300)
        )

        let details = LoopdyLinkPairingPresentation(challenge: challenge).details

        #expect(details.count == 1)
        #expect(details.allSatisfy { !$0.localizedCaseInsensitiveContains("fixture") })
        #expect(details.allSatisfy { !$0.contains(challenge.code) })
    }

    @Test func qrParserAcceptsOnlyTheLoopdyLinkPairingRoute() {
        let commitment = LoopdyLinkBase64URL.encode(Data(repeating: 0x22, count: 32))
        #expect(
            LoopdyLinkPairingCode.fromQRPayload(
                "loopdy://link/pair?flow=flow_fixture_0123456789012345&code=abc-123&kc=\(commitment)"
            )
                == "ABC123"
        )
        #expect(
            LoopdyLinkPairingCode.fromQRPayload("https://example.com/?code=ABC123")
                == nil
        )
        #expect(
            LoopdyLinkPairingCode.fromQRPayload("loopdy://link/pair?token=reusable-secret")
                == nil
        )
    }

    @Test func scannedPairingKeepsTheHostFlowCoordinateBoundToTheCode() async {
        let clock = PairingTestClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let client = LoopdyLinkFixtureClient(
            devices: [Self.phone],
            pairingChallenge: LoopdyLinkPairingChallenge(
                id: "flow_fixture_0123456789012345",
                code: "ABC123",
                expiresAt: clock.now.addingTimeInterval(300)
            )
        )
        let store = LoopdyLinkDeviceStore(client: client, now: { clock.now })
        await store.load()
        await store.beginPairing()

        await store.completePairing(reference: .init(
            flowID: "flow_fixture_0123456789012345",
            code: "ABC123",
            keyCommitment: LoopdyLinkBase64URL.encode(Data(repeating: 0x33, count: 32))
        ))

        #expect(store.pairingState == .paired(deviceID: "paired-host"))
    }

    @Test func expiredChallengeCannotAuthorizeADevice() async {
        let clock = PairingTestClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let client = LoopdyLinkFixtureClient(
            devices: [Self.phone],
            pairingChallenge: LoopdyLinkPairingChallenge(
                id: "challenge-1",
                code: "ABC123",
                expiresAt: clock.now.addingTimeInterval(30)
            )
        )
        let store = LoopdyLinkDeviceStore(client: client, now: { clock.now })
        await store.load()
        await store.beginPairing()
        clock.now = clock.now.addingTimeInterval(31)

        await store.completePairing(code: "ABC123")

        #expect(store.pairingState == .expired)
        #expect(store.devices == [Self.phone])
    }

    @Test func reusableCredentialShapedTextIsRejectedBeforePairing() async {
        let clock = PairingTestClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let client = LoopdyLinkFixtureClient(
            devices: [Self.phone],
            pairingChallenge: LoopdyLinkPairingChallenge(
                id: "challenge-1",
                code: "ABC123",
                expiresAt: clock.now.addingTimeInterval(300)
            )
        )
        let store = LoopdyLinkDeviceStore(client: client, now: { clock.now })
        await store.load()
        await store.beginPairing()

        await store.completePairing(code: "Bearer reusable-host-credential")

        #expect(store.pairingState == .failed("Enter the six-character pairing code."))
        #expect(store.devices == [Self.phone])
    }

    @Test func confirmedPairingAddsTheAuthoritativeHost() async {
        let clock = PairingTestClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let client = LoopdyLinkFixtureClient(
            devices: [Self.phone],
            pairingChallenge: LoopdyLinkPairingChallenge(
                id: "challenge-1",
                code: "ABC123",
                expiresAt: clock.now.addingTimeInterval(300)
            )
        )
        let suiteName = "LoopdyLinkPairingSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = LoopdyLinkHostSelectionStore(defaults: defaults)
        let store = LoopdyLinkDeviceStore(
            client: client,
            hostSelection: selection,
            now: { clock.now }
        )
        await store.load()
        await store.beginPairing()

        await store.completePairing(
            code: "abc-123",
            verificationCode: "1234-5678-9ABC-DEF0"
        )

        #expect(store.pairingState == .paired(deviceID: "paired-host"))
        #expect(store.device(id: "paired-host")?.name == "Paired Hermes")
        #expect(selection.selectedHostID == "paired-host")
        #expect(selection.primaryHostID == "paired-host")
    }

    @Test func manualPairingRequiresTheHostVerificationCode() async {
        let clock = PairingTestClock(now: Date(timeIntervalSince1970: 1_788_000_000))
        let store = LoopdyLinkDeviceStore(
            client: LoopdyLinkFixtureClient(
                devices: [Self.phone],
                pairingChallenge: .init(
                    id: "challenge-1",
                    code: "ABC123",
                    expiresAt: clock.now.addingTimeInterval(300)
                )
            ),
            now: { clock.now }
        )
        await store.load()
        await store.beginPairing()

        await store.completePairing(code: "ABC123")

        #expect(store.pairingState == .failed("Enter the host’s 16-character verification code."))
        #expect(store.devices == [Self.phone])
    }

    private static let phone = LoopdyLinkDevice(
        id: "phone-1",
        name: "This iPhone",
        kind: .phone,
        isCurrentDevice: true,
        connection: .online,
        pushState: .permissionRequired,
        lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
        revision: 1
    )
}

@MainActor
private final class PairingTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
