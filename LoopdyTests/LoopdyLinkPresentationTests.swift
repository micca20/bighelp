import Foundation
import Testing
@testable import Loopdy

struct LoopdyLinkPresentationTests {
    @Test func installPromptOffersManagedOrSelfHostedSetupBeforePairing() {
        let prompt = LoopdyLinkInstallPrompt.text

        #expect(prompt.contains("Ask me whether I want the Loopdy managed relay or a self-hosted relay"))
        #expect(prompt.contains("hermes plugins install promptclickrun/loopdy-ios/plugins/loopdy --enable --force"))
        #expect(prompt.contains("hermes loopdy link pair"))
        #expect(prompt.contains("hermes loopdy link pair --base-url"))
        #expect(prompt.contains("six-character pairing code"))
        #expect(!prompt.contains("promptclickrun/loopdyai"))
        #expect(!prompt.lowercased().contains("gateway token"))
        #expect(!prompt.contains("LOOPDY_LINK_ACCOUNT_KEY"))
    }

    @Test func aReadyLinkAccountNeverOffersLegacyGatewayCredentials() {
        let presentation = SettingsConnectivityPresentation(linkAccountState: .ready)

        #expect(!presentation.showsDirectGatewaySetup)
        #expect(presentation.footer.contains("no separate gateway address or token"))
    }

    @Test func deviceSectionsExposeOnlyHostsAndConnectedDevices() {
        let current = device(
            id: "phone-1",
            name: "This iPhone",
            kind: .phone,
            isCurrent: true,
            connection: .online,
            push: .ready
        )
        let tablet = device(
            id: "tablet-1",
            name: "Shared iPad",
            kind: .tablet,
            connection: .recent,
            push: .ready
        )
        let host = device(
            id: "host-1",
            name: "Home Hermes",
            kind: .hermesHost,
            connection: .online
        )

        let sections = LoopdyLinkDeviceSections(devices: [tablet, host, current])

        #expect(sections.connectedDevices == [current, tablet])
        #expect(sections.hosts == [host])
    }

    @Test func hostAuthorityPresentationKeepsSelectionAndPrimaryIndependentAndVisible() {
        let selectedPrimary = LoopdyLinkHostAuthorityPresentation(
            hostID: "host-a",
            selectedHostID: "host-a",
            primaryHostID: "host-a"
        )
        #expect(selectedPrimary.statusLabels == ["Selected instance", "Primary"])
        #expect(!selectedPrimary.canSelect)
        #expect(!selectedPrimary.canSetPrimary)

        let selectedOnly = LoopdyLinkHostAuthorityPresentation(
            hostID: "host-b",
            selectedHostID: "host-b",
            primaryHostID: "host-a"
        )
        #expect(selectedOnly.statusLabels == ["Selected instance"])
        #expect(!selectedOnly.canSelect)
        #expect(selectedOnly.canSetPrimary)

        let primaryOnly = LoopdyLinkHostAuthorityPresentation(
            hostID: "host-a",
            selectedHostID: "host-b",
            primaryHostID: "host-a"
        )
        #expect(primaryOnly.statusLabels == ["Primary"])
        #expect(primaryOnly.canSelect)
        #expect(!primaryOnly.canSetPrimary)
    }

    @Test func summaryReportsConnectedDeviceCountWithoutRawCoordinates() {
        let summary = LoopdyLinkDeviceSummary(devices: [
            device(
                id: "opaque-mobile-coordinate",
                name: "This iPhone",
                kind: .phone,
                isCurrent: true,
                connection: .online,
                push: .ready
            ),
            device(
                id: "opaque-host-coordinate",
                name: "Home Hermes",
                kind: .hermesHost,
                connection: .online
            ),
        ])

        #expect(summary.title == "Connected")
        #expect(summary.deviceCountText == "2 paired devices")
        #expect(!summary.accessibilitySummary.contains("opaque"))
    }

    @Test func emptySummaryIsExplicitlyNotPaired() {
        let summary = LoopdyLinkDeviceSummary(devices: [])

        #expect(summary.title == "Not paired")
        #expect(summary.deviceCountText == "No paired devices")
    }

    private func device(
        id: String,
        name: String,
        kind: LoopdyLinkDeviceKind,
        isCurrent: Bool = false,
        connection: LoopdyLinkConnectionState,
        push: LoopdyLinkPushState? = nil
    ) -> LoopdyLinkDevice {
        LoopdyLinkDevice(
            id: id,
            name: name,
            kind: kind,
            isCurrentDevice: isCurrent,
            connection: connection,
            pushState: push,
            lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
            revision: 1
        )
    }
}
