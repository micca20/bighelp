import Foundation
import Testing
@testable import Bighelp

private enum LocalCacheRefreshFixtureError: Error {
    case clearFailed
}

struct BighelpAppReadinessTests {

    @Test @MainActor func staleAccountCleanupCannotClearReplacementWorkspace() async {
        var generation = UUID()
        let owned = generation
        var didSuspend = false
        var continuation: CheckedContinuation<Void, Never>?
        var resetReplacement = false
        let cleanup = Task {
            await BighelpAccountWorkspaceBoundary.clearWorkspace(
                isCurrent: { generation == owned },
                steps: [
                    { await withCheckedContinuation { continuation = $0; didSuspend = true } },
                    { resetReplacement = true }
                ]
            )
        }
        for _ in 0..<30 where !didSuspend { await Task.yield() }
        #expect(didSuspend)
        generation = UUID()
        continuation?.resume()
        await cleanup.value
        #expect(!resetReplacement)
    }

    @Test func failedLocalSignOutStillClearsUnauthenticatedWorkspace() {
        #expect(BighelpAccountWorkspaceBoundary.shouldClear(account: .failed, hasCredentials: false, needsLocalCleanup: true))
        #expect(!BighelpAccountWorkspaceBoundary.shouldClear(account: .failed, hasCredentials: false))
        #expect(!BighelpAccountWorkspaceBoundary.shouldClear(account: .failed, hasCredentials: true, needsLocalCleanup: true))
    }

    @Test @MainActor func localCacheRefreshInvalidatesClearsThenPerformsAFreshPull() async {
        var events: [String] = []
        let coordinator = BighelpLocalCacheRefreshCoordinator(
            invalidateStaleWork: { events.append("invalidate") },
            clearCurrentHostCache: { events.append("clear") },
            refreshAuthoritativeState: {
                events.append("refresh")
                return true
            }
        )

        #expect(await coordinator.clearAndRefresh())
        #expect(events == ["invalidate", "clear", "refresh"])
    }

    @Test @MainActor func localCacheRefreshReportsFailureWithoutClaimingSuccess() async {
        let coordinator = BighelpLocalCacheRefreshCoordinator(
            invalidateStaleWork: {},
            clearCurrentHostCache: { throw LocalCacheRefreshFixtureError.clearFailed },
            refreshAuthoritativeState: { true }
        )

        #expect(!(await coordinator.clearAndRefresh()))
    }

    @Test @MainActor func hostSelectionChangesSerializeAndCoalesceToLatestAuthority() async {
        let relay = BighelpHostSelectionChangeRelay()
        let gate = AccountRefreshGate()
        var events: [String] = []
        relay.handler = { hostID in
            let host = hostID ?? "none"
            events.append("start:\(host)")
            if hostID == "host-a" { await gate.wait() }
            events.append("end:\(host)")
        }

        relay.send("host-a")
        await gate.waitUntilBlocked()
        relay.send("host-b")
        relay.send("host-c")
        for _ in 0..<20 { await Task.yield() }
        #expect(events == ["start:host-a"])

        gate.open()
        for _ in 0..<200 where events.count < 4 { await Task.yield() }
        #expect(events == [
            "start:host-a",
            "end:host-a",
            "start:host-c",
            "end:host-c",
        ])
    }

    @Test func productionStillMigratesTheStableLegacyDemoDirectory() {
        let applicationSupport = URL(filePath: "/fixture/Application Support")

        #expect(
            BighelpApplicationDataDirectories.active(
                fixtures: false,
                applicationSupport: applicationSupport,
                processIdentifier: 77
            ).lastPathComponent == "Loopdy"
        )
        #expect(
            BighelpApplicationDataDirectories.active(
                fixtures: true,
                applicationSupport: applicationSupport,
                processIdentifier: 77
            ).lastPathComponent == "LoopdyDemo-77"
        )
        #expect(
            BighelpApplicationDataDirectories.legacySocketDirectories(
                fixtures: false,
                applicationSupport: applicationSupport
            ).map(\.lastPathComponent) == ["LoopdyDemo"]
        )
        #expect(
            BighelpApplicationDataDirectories.legacySocketDirectories(
                fixtures: true,
                applicationSupport: applicationSupport
            ).isEmpty
        )
    }

    @Test func signedOutRequiresAccountEvenWhenAHostRecordExists() {
        let presentation = BighelpAppReadiness.resolve(
            account: .signedOut,
            devices: [hermesHost()],
            link: .verified
        )

        #expect(presentation.state == .accountRequired)
        #expect(presentation.actions == [.signIn, .createAccount])
        #expect(presentation.allowsWorkspace == false)
    }

    @Test func accountWorkAndFailureStatesRemainBehindTheAccountGate() {
        let working = BighelpAppReadiness.resolve(
            account: .working,
            devices: [],
            link: .unverified
        )
        let failed = BighelpAppReadiness.resolve(
            account: .failed,
            devices: [hermesHost()],
            link: .verified
        )

        #expect(working.state == .authenticating)
        #expect(working.allowsWorkspace == false)
        #expect(failed.state == .accountRequired)
        #expect(failed.actions == [.signIn, .createAccount])
    }

    @Test func signedInWithoutAValidHermesHostRequiresPairing() {
        let noDevices = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .verified
        )
        let currentDeviceOnly = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [
                BighelpLinkDevice(
                    id: "phone",
                    name: "This iPhone",
                    kind: .phone,
                    isCurrentDevice: true,
                    connection: .online,
                    pushState: .ready,
                    lastSeenAt: nil,
                    revision: 1
                )
            ],
            link: .verified
        )
        let malformedHost = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(id: "", revision: 1)],
            link: .verified
        )

        for presentation in [noDevices, currentDeviceOnly, malformedHost] {
            #expect(presentation.state == .pairingRequired)
            #expect(presentation.actions == [.pairDevice])
            #expect(presentation.allowsWorkspace == false)
        }
    }

    @Test func pairedHostNeedsVerifiedLinkBeforeWorkspaceOpens() {
        let unverified = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .offline)],
            link: .unverified
        )
        let connecting = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .recent)],
            link: .connecting
        )
        let retrying = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .online)],
            link: .retrying
        )
        let offlineHost = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .offline)],
            link: .verified
        )
        let recentHost = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .recent)],
            link: .verified
        )

        for presentation in [unverified, connecting, retrying, offlineHost, recentHost] {
            #expect(presentation.state == .connecting)
            #expect(presentation.actions == [.retryConnection])
            #expect(presentation.allowsWorkspace == false)
        }
        #expect(unverified.linkState == .unverified)
        #expect(connecting.linkState == .connecting)
        #expect(retrying.linkState == .retrying)
    }

    @Test func onlyVerifiedLinkWithValidPairedHostReleasesWorkspace() {
        let presentation = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .online)],
            link: .verified
        )

        #expect(presentation.state == .ready)
        #expect(presentation.actions.isEmpty)
        #expect(presentation.allowsWorkspace)
    }

    @Test func anAdmittedWorkspaceSurvivesTransientLinkRetry() {
        let presentation = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .online)],
            link: .retrying,
            workspaceWasPreviouslyAdmitted: true
        )

        #expect(presentation.state == .ready)
        #expect(presentation.allowsWorkspace)
    }

    @Test func aPersistedAdmissionAvoidsTheColdLaunchConnectionGateUntilDevicesAreAuthoritative() throws {
        let suiteName = "BighelpAppReadinessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BighelpWorkspaceAdmissionStore(defaults: defaults)
        store.recordVerifiedAdmission(
            localDeviceID: "this-phone",
            devices: [hermesHost(id: "paired-host")]
        )

        let restored = BighelpWorkspaceAdmissionStore(defaults: defaults)

        #expect(restored.wasPreviouslyAdmitted(
            localDeviceID: "this-phone",
            devices: [],
            deviceLoadState: .idle
        ))
        #expect(restored.wasPreviouslyAdmitted(
            localDeviceID: "this-phone",
            devices: [hermesHost(id: "paired-host", connection: .offline)],
            deviceLoadState: .loaded
        ))
        #expect(!restored.wasPreviouslyAdmitted(
            localDeviceID: "another-phone",
            devices: [hermesHost(id: "paired-host")],
            deviceLoadState: .loaded
        ))
        #expect(!restored.wasPreviouslyAdmitted(
            localDeviceID: "this-phone",
            devices: [hermesHost(id: "replacement-host")],
            deviceLoadState: .loaded
        ))
        #expect(!restored.wasPreviouslyAdmitted(
            localDeviceID: "this-phone",
            devices: [],
            deviceLoadState: .loaded
        ))
    }

    @Test func restoredAdmissionReleasesWorkspaceBeforeTheFirstDeviceRefreshButNotAfterAnAuthoritativeUnpair() {
        let restoring = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .retrying,
            deviceLoadState: .loading,
            workspaceWasPreviouslyAdmitted: true
        )
        let unpaired = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .retrying,
            deviceLoadState: .loaded,
            workspaceWasPreviouslyAdmitted: true
        )

        #expect(restoring.state == .ready)
        #expect(restoring.allowsWorkspace)
        #expect(unpaired.state == .pairingRequired)
        #expect(!unpaired.allowsWorkspace)
    }

    @Test func admittedColdLaunchRefreshesWhenSocketVerificationArrivesWithoutReadinessStateChange() {
        let restoring = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .retrying,
            deviceLoadState: .loading,
            workspaceWasPreviouslyAdmitted: true
        )
        let verified = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .verified,
            deviceLoadState: .loading,
            workspaceWasPreviouslyAdmitted: true
        )

        let restoringTrigger = BighelpReadinessDriveTrigger(
            readiness: restoring.state,
            link: restoring.linkState
        )
        let verifiedTrigger = BighelpReadinessDriveTrigger(
            readiness: verified.state,
            link: verified.linkState
        )
        #expect(restoring.state == .ready)
        #expect(verified.state == .ready)
        #expect(restoringTrigger != verifiedTrigger)
        #expect(!restoringTrigger.shouldHydrateWorkspace)
        #expect(verifiedTrigger.shouldHydrateWorkspace)
    }

    @Test func retryRecoveryIsRevealedOnlyAfterOneAbsoluteTwelveSecondGracePeriod() {
        let startedAt = Date(timeIntervalSince1970: 1_000)

        #expect(!BighelpConnectionGracePeriod.shouldRevealRecovery(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(11.999)
        ))
        #expect(BighelpConnectionGracePeriod.shouldRevealRecovery(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(12)
        ))
        #expect(
            BighelpConnectionGracePeriod.deadline(startedAt: startedAt)
                == startedAt.addingTimeInterval(12)
        )
    }

    @Test func homeConnectionStatusUsesCompactAccessibleConnectedAndRecoveryStates() {
        let connected = HostConnectionStatus(dashboardIsConnected: true)
        let reconnecting = HostConnectionStatus(dashboardIsConnected: false)

        #expect(connected.label == "Connected")
        #expect(connected.phase == .connected)
        #expect(reconnecting.label == "Reconnecting")
        #expect(reconnecting.phase == .reconnecting)
    }

    @Test func transientReconnectStatusIsCompactAndSettingsOnlyAfterAdmission() {
        let retrying = SettingsLinkConnectionPresentation(state: .retrying)
        let connecting = SettingsLinkConnectionPresentation(state: .connecting)
        let superseded = SettingsLinkConnectionPresentation(state: .superseded)
        let verified = SettingsLinkConnectionPresentation(state: .verified)

        #expect(retrying.title == "Reconnecting")
        #expect(retrying.detail == "bighelp Link is restoring the secure connection in the background.")
        #expect(connecting.title == "Connecting")
        #expect(superseded.title == "Connection moved")
        #expect(superseded.status.phase == .disconnected)
        #expect(verified.title == "Connected")
        #expect(verified.status.phase == .connected)
        #expect(retrying.status.phase == .reconnecting)
        #expect(connecting.status.phase == .connecting)
    }

    @Test func anAdmittedWorkspaceSurvivesTransientDeviceRefreshFailure() {
        let presentation = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost(connection: .online)],
            link: .verified,
            deviceLoadState: .failed,
            workspaceWasPreviouslyAdmitted: true
        )

        #expect(presentation.state == .ready)
        #expect(presentation.allowsWorkspace)
    }

    @Test func admissionDoesNotBypassPairingOrAccountBoundaries() {
        let unpaired = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .retrying,
            workspaceWasPreviouslyAdmitted: true
        )
        let signedOut = BighelpAppReadiness.resolve(
            account: .signedOut,
            devices: [hermesHost()],
            link: .retrying,
            workspaceWasPreviouslyAdmitted: true
        )

        #expect(unpaired.state == .pairingRequired)
        #expect(unpaired.allowsWorkspace == false)
        #expect(signedOut.state == .accountRequired)
        #expect(signedOut.allowsWorkspace == false)
    }

    @Test func accountReadyDoesNotFlashPairingWhileDeviceStoreIsNotAuthoritative() {
        let checkingStates: [BighelpLinkLoadState] = [.idle, .loading, .failed]
        let checking = checkingStates.map { loadState in
            BighelpAppReadiness.resolve(
                account: .ready,
                devices: [],
                link: .verified,
                deviceLoadState: loadState
            )
        }
        let loadedEmpty = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .verified,
            deviceLoadState: .loaded
        )

        for presentation in checking {
            #expect(presentation.state == .connecting)
            #expect(presentation.actions == [.retryConnection])
            #expect(presentation.allowsWorkspace == false)
            #expect(presentation.devicesLoaded == false)
            #expect(presentation.detail == "Checking your paired devices and secure Link connection. Your workspace will open when it’s ready.")
        }
        #expect(loadedEmpty.state == .pairingRequired)
    }

    @Test func guidedCopyUsesAgentSafeAccountAndLinkLanguage() {
        let account = BighelpAppReadiness.resolve(
            account: .signedOut,
            devices: [],
            link: .unverified
        )
        let pairing = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [],
            link: .unverified
        )
        let connecting = BighelpAppReadiness.resolve(
            account: .ready,
            devices: [hermesHost()],
            link: .retrying
        )

        #expect(account.title == "Sign in to bighelp")
        #expect(account.detail == "Sign in or create an account to securely connect your workspace.")
        #expect(pairing.title == "Connect your Hermes host")
        #expect(pairing.detail == "Pair bighelp Link with your Hermes host before opening your workspace.")
        #expect(connecting.title == "Connecting to your Hermes host")
        #expect(connecting.detail == "bighelp is retrying the secure Link connection. Retry to continue to your workspace.")
    }

    @Test func foregroundRecoveryRestoresCredentialsAndRefreshesNonVerifiedSockets() {
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .failed,
            hasCredentials: false,
            link: .stopped
        ) == .restoreCredentials)
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .ready,
            hasCredentials: true,
            link: .stopped
        ) == .startConnection)
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .ready,
            hasCredentials: true,
            link: .connecting
        ) == .retryConnection)
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .ready,
            hasCredentials: true,
            link: .retrying
        ) == .retryConnection)
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .ready,
            hasCredentials: true,
            link: .superseded
        ) == .retryConnection)
        #expect(BighelpForegroundLinkRecovery.resolve(
            account: .ready,
            hasCredentials: true,
            link: .verified
        ) == .retryConnection)
    }

    @Test func onlyExplicitSignOutClearsTheAccountWorkspace() {
        #expect(BighelpAccountWorkspaceBoundary.shouldClear(
            account: .signedOut,
            hasCredentials: false
        ))
        #expect(!BighelpAccountWorkspaceBoundary.shouldClear(
            account: .failed,
            hasCredentials: false
        ))
        #expect(!BighelpAccountWorkspaceBoundary.shouldClear(
            account: .signedOut,
            hasCredentials: true
        ))
        #expect(!BighelpAccountWorkspaceBoundary.shouldClear(
            account: .ready,
            hasCredentials: true
        ))
    }

    private func hermesHost(
        id: String = "hermes-host",
        revision: Int = 1,
        connection: BighelpLinkConnectionState = .online
    ) -> BighelpLinkDevice {
        BighelpLinkDevice(
            id: id,
            name: "Hermes Mac",
            kind: .hermesHost,
            isCurrentDevice: false,
            connection: connection,
            pushState: .ready,
            lastSeenAt: nil,
            revision: revision
        )
    }
}

@MainActor
private final class AccountRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
