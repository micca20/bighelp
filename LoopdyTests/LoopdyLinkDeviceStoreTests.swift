import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyLinkDeviceStoreTests {
    @Test func freshLoadDoesNotInheritCancelledOriginatingRequest() async {
        let client = DeferredAccountDeviceClient()
        client.observesCancellation = true
        let suiteName = "DeviceResume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LoopdyLinkDeviceStore(client: client, hostSelection: LoopdyLinkHostSelectionStore(defaults: defaults))
        let oldLoad = Task { await store.load() }
        for _ in 0..<100 where client.replies.count < 1 { await Task.yield() }
        guard client.replies.count == 1 else { Issue.record("Initial request missing"); return }
        oldLoad.cancel()
        let freshLoad = Task { await store.load() }
        for _ in 0..<20 { await Task.yield() }
        client.replies[0].resume(returning: [.hostFixture])
        await oldLoad.value
        for _ in 0..<100 where client.replies.count < 2 { await Task.yield() }
        #expect(client.replies.count == 2, "Fresh foreground load must replace the cancelled request")
        if client.replies.count == 2 { client.replies[1].resume(returning: [.hostFixture]) }
        await freshLoad.value
        #expect(store.loadState == .loaded)
        #expect(store.selectedHostID == "host-1")
    }

    @Test func staleDeviceLoadCannotRestorePreviousAccountAuthority() async {
        let client = DeferredAccountDeviceClient()
        let suiteName = "DeviceEpoch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LoopdyLinkDeviceStore(client: client, hostSelection: LoopdyLinkHostSelectionStore(defaults: defaults))
        let oldLoad = Task { await store.load() }
        for _ in 0..<30 where client.replies.count < 1 { await Task.yield() }
        #expect(client.replies.count == 1)
        store.resetForAccountBoundary()
        let newLoad = Task { await store.load() }
        for _ in 0..<30 where client.replies.count < 2 { await Task.yield() }
        #expect(client.replies.count == 2)
        client.replies[0].resume(returning: [.hostFixture])
        await oldLoad.value
        #expect(store.devices.isEmpty)
        #expect(store.selectedHostID == nil)
        #expect(store.loadState == .loading)
        let replacement = fixtureDevice(id: "new-host", name: "New host", kind: .hermesHost, connection: .online, revision: 1)
        client.replies[1].resume(returning: [replacement])
        await newLoad.value
        #expect(store.devices.map(\.id) == ["new-host"])
        #expect(store.selectedHostID == "new-host")
        store.resetForAccountBoundary()
    }

    @Test func loadedDevicesKeepTheCurrentDeviceFirstAndHostsLast() async {
        let client = LoopdyLinkFixtureClient(devices: [
            fixtureDevice(
                id: "host-1",
                name: "Home Hermes",
                kind: .hermesHost,
                connection: .online,
                revision: 7
            ),
            fixtureDevice(
                id: "tablet-1",
                name: "Shared iPad",
                kind: .tablet,
                connection: .recent,
                revision: 2
            ),
            fixtureDevice(
                id: "phone-1",
                name: "This iPhone",
                kind: .phone,
                isCurrentDevice: true,
                connection: .online,
                pushState: nil,
                revision: 3
            ),
        ])
        let store = LoopdyLinkDeviceStore(client: client)

        await store.load()

        #expect(store.devices.map(\.id) == ["phone-1", "tablet-1", "host-1"])
        #expect(store.loadState == .loaded)
    }

    @Test func loadedHostsEstablishOneDeterministicAuthorityWhenPersistenceIsMissing() async {
        let suiteName = "LoopdyLinkLoadedHostSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = LoopdyLinkHostSelectionStore(defaults: defaults)
        let client = LoopdyLinkFixtureClient(devices: [
            fixtureDevice(
                id: "host-secondary",
                name: "Studio Hermes",
                kind: .hermesHost,
                connection: .online,
                revision: 2
            ),
            fixtureDevice(
                id: "host-primary",
                name: "Home Hermes",
                kind: .hermesHost,
                connection: .online,
                revision: 1
            ),
        ])
        let store = LoopdyLinkDeviceStore(client: client, hostSelection: selection)

        await store.load()

        #expect(selection.selectedHostID == "host-primary")
        #expect(selection.primaryHostID == "host-primary")
    }

    @Test func accountBoundaryClearsHostAuthorityBeforeDeviceHydration() async {
        let suiteName = "LoopdyLinkAccountBoundarySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = LoopdyLinkHostSelectionStore(defaults: defaults)
        let store = LoopdyLinkDeviceStore(
            client: LoopdyLinkFixtureClient(devices: [.hostFixture]),
            hostSelection: selection
        )
        await store.load()
        #expect(store.selectedHostID == "host-1")
        #expect(store.primaryHostID == "host-1")

        store.resetForAccountBoundary()

        #expect(store.selectedHostID == nil)
        #expect(store.primaryHostID == nil)
        #expect(defaults.string(forKey: "loopdy.link.selected-host-id") == nil)
        #expect(defaults.string(forKey: "loopdy.link.primary-host-id") == nil)
        #expect(store.devices.isEmpty)
    }

    @Test func renameCommitsOnlyTheConfirmedRevision() async {
        let client = LoopdyLinkFixtureClient(devices: [.phoneFixture])
        let store = LoopdyLinkDeviceStore(client: client)
        await store.load()

        await store.renameDevice(id: "phone-1", name: "  Travel iPhone  ")

        #expect(store.device(id: "phone-1")?.name == "Travel iPhone")
        #expect(store.device(id: "phone-1")?.revision == 4)
        #expect(store.pendingAction == nil)
        #expect(store.actionError == nil)
    }

    @Test func invalidRenameNeverChangesTheAuthoritativeRow() async {
        let client = LoopdyLinkFixtureClient(devices: [.phoneFixture])
        let store = LoopdyLinkDeviceStore(client: client)
        await store.load()

        await store.renameDevice(id: "phone-1", name: "   ")

        #expect(store.device(id: "phone-1")?.name == "This iPhone")
        #expect(store.renameValidationError == "Enter a device name.")
        #expect(store.pendingAction == nil)
    }

    @Test func failedRenameRetainsTheAuthoritativeDevice() async {
        let client = LoopdyLinkFixtureClient(
            devices: [.phoneFixture],
            failures: [.rename("phone-1")]
        )
        let store = LoopdyLinkDeviceStore(client: client)
        await store.load()

        await store.renameDevice(id: "phone-1", name: "Travel iPhone")

        #expect(store.device(id: "phone-1")?.name == "This iPhone")
        #expect(store.device(id: "phone-1")?.revision == 3)
        #expect(store.actionError == "That device could not be renamed. Try again.")
    }

    @Test func confirmedUnpairRemovesExactlyThatDevice() async {
        let client = LoopdyLinkFixtureClient(devices: [.phoneFixture, .hostFixture])
        let store = LoopdyLinkDeviceStore(client: client)
        await store.load()

        await store.unpairDevice(id: "host-1")

        #expect(store.devices.map(\.id) == ["phone-1"])
        #expect(store.actionError == nil)
    }

    @Test func selectedHostUnpairFallsBackDeterministicallyThenReturnsToPairing() async {
        let suiteName = "LoopdyLinkUnpairSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = LoopdyLinkHostSelectionStore(defaults: defaults)
        var selectedChanges: [String?] = []
        let firstHost = fixtureDevice(
            id: "host-a",
            name: "Home Hermes",
            kind: .hermesHost,
            connection: .online,
            revision: 1
        )
        let fallbackHost = fixtureDevice(
            id: "host-b",
            name: "Studio Hermes",
            kind: .hermesHost,
            connection: .online,
            revision: 1
        )
        let store = LoopdyLinkDeviceStore(
            client: LoopdyLinkFixtureClient(devices: [.phoneFixture, firstHost, fallbackHost]),
            hostSelection: selection,
            onSelectedHostChange: { selectedChanges.append($0) }
        )
        await store.load()

        await store.unpairDevice(id: "host-a")
        #expect(store.devices.map(\.id).contains("phone-1"))
        #expect(selection.selectedHostID == "host-b")
        #expect(selection.primaryHostID == "host-b")
        #expect(selectedChanges == ["host-b"])

        await store.unpairDevice(id: "host-b")
        #expect(store.devices.map(\.id) == ["phone-1"])
        #expect(selection.selectedHostID == nil)
        #expect(selection.primaryHostID == nil)
        #expect(selectedChanges == ["host-b", nil])
    }

    @Test func failedUnpairRetainsTheAuthoritativeDevice() async {
        let client = LoopdyLinkFixtureClient(
            devices: [.phoneFixture],
            failures: [.unpair("phone-1")]
        )
        let store = LoopdyLinkDeviceStore(client: client)
        await store.load()

        await store.unpairDevice(id: "phone-1")

        #expect(store.device(id: "phone-1") != nil)
        #expect(store.actionError == "That device could not be unpaired. Try again.")
    }

    @Test func selectedAndPrimaryHostsPersistIndependentlyWithPrimaryOwningNextLaunch() {
        let suiteName = "LoopdyLinkHostSelectionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LoopdyLinkHostSelectionStore(defaults: defaults)

        store.reconcile(hostIDs: ["host-primary"])
        store.reconcile(hostIDs: ["host-primary", "host-secondary"])
        #expect(store.selectedHostID == "host-primary")
        #expect(store.primaryHostID == "host-primary")

        #expect(store.selectHost("host-secondary"))
        #expect(store.selectedHostID == "host-secondary")
        #expect(store.primaryHostID == "host-primary")

        #expect(store.setPrimaryHost("host-secondary"))
        #expect(store.selectedHostID == "host-secondary")
        #expect(store.primaryHostID == "host-secondary")

        #expect(store.selectHost("host-primary"))
        #expect(store.selectedHostID == "host-primary")
        #expect(store.primaryHostID == "host-secondary")

        let relaunched = LoopdyLinkHostSelectionStore(defaults: defaults)
        #expect(relaunched.selectedHostID == "host-secondary")
        #expect(relaunched.primaryHostID == "host-secondary")
    }

    @Test func changingPrimaryBackToTheOriginalHostSurvivesRepeatedRelaunches() {
        let suiteName = "LoopdyLinkPrimaryRoundTripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = LoopdyLinkHostSelectionStore(defaults: defaults)
        store.reconcile(hostIDs: ["host-a", "host-b"])
        #expect(store.selectHost("host-b"))

        for primary in ["host-b", "host-a", "host-b", "host-a"] {
            let previousSelection = store.selectedHostID
            #expect(store.setPrimaryHost(primary))
            #expect(store.primaryHostID == primary)
            // Setting a launch preference must not switch live authority.
            #expect(store.selectedHostID == previousSelection)
            store.reconcile(hostIDs: ["host-b", "host-a"])
            #expect(defaults.string(forKey: "loopdy.link.primary-host-id") == primary)

            store = LoopdyLinkHostSelectionStore(defaults: UserDefaults(suiteName: suiteName)!)
            #expect(store.selectedHostID == primary)
            store.reconcile(hostIDs: ["host-a", "host-b"])
            #expect(store.selectedHostID == primary)
            #expect(store.primaryHostID == primary)
            #expect(defaults.string(forKey: "loopdy.link.selected-host-id") == primary)
        }
    }

    @Test func launchFallsBackToSavedSelectionWhenNoPrimaryExists() {
        let suiteName = "LoopdyLinkLegacySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("host-b", forKey: "loopdy.link.selected-host-id")

        let store = LoopdyLinkHostSelectionStore(defaults: defaults)
        #expect(store.selectedHostID == "host-b")
        store.reconcile(hostIDs: ["host-a", "host-b"])
        #expect(store.selectedHostID == "host-b")
        #expect(store.primaryHostID == "host-b")
    }

    @Test func unavailableLaunchPrimaryIsReconciledAndAccountResetClearsPreferences() {
        let suiteName = "LoopdyLinkUnavailablePrimaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("removed-host", forKey: "loopdy.link.primary-host-id")
        defaults.set("host-b", forKey: "loopdy.link.selected-host-id")

        let store = LoopdyLinkHostSelectionStore(defaults: defaults)
        store.reconcile(hostIDs: ["host-b", "host-a"])
        #expect(store.selectedHostID == "host-a")
        #expect(store.primaryHostID == "host-a")
        #expect(!store.setPrimaryHost("removed-host"))
        #expect(!store.setPrimaryHost("host-a"))

        store.resetForAccountBoundary()
        let relaunched = LoopdyLinkHostSelectionStore(defaults: defaults)
        #expect(relaunched.selectedHostID == nil)
        #expect(relaunched.primaryHostID == nil)
        #expect(defaults.string(forKey: "loopdy.link.selected-host-id") == nil)
        #expect(defaults.string(forKey: "loopdy.link.primary-host-id") == nil)
    }

    @Test func hostActionsSeparateImmediateSelectionFromNextLaunchPrimary() async {
        let suiteName = "LoopdyLinkHostActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = LoopdyLinkHostSelectionStore(defaults: defaults)
        var selectedChanges: [String?] = []
        let store = LoopdyLinkDeviceStore(
            client: LoopdyLinkFixtureClient(devices: [
                .phoneFixture,
                fixtureDevice(
                    id: "host-a",
                    name: "Home Hermes",
                    kind: .hermesHost,
                    connection: .online,
                    revision: 1
                ),
                fixtureDevice(
                    id: "host-b",
                    name: "Studio Hermes",
                    kind: .hermesHost,
                    connection: .online,
                    revision: 1
                ),
            ]),
            hostSelection: selection,
            onSelectedHostChange: { selectedChanges.append($0) }
        )
        await store.load()

        #expect(store.selectedHostID == "host-a")
        #expect(store.primaryHostID == "host-a")
        #expect(store.selectHost("host-b"))
        #expect(store.selectedHostID == "host-b")
        #expect(store.primaryHostID == "host-a")
        #expect(selectedChanges == ["host-b"])

        #expect(store.setPrimaryHost("host-b"))
        #expect(store.selectedHostID == "host-b")
        #expect(store.primaryHostID == "host-b")
        #expect(selectedChanges == ["host-b"])

        #expect(!store.selectHost("phone-1"))
        #expect(!store.setPrimaryHost("phone-1"))
        #expect(selectedChanges == ["host-b"])
    }

    private func fixtureDevice(
        id: String,
        name: String,
        kind: LoopdyLinkDeviceKind,
        isCurrentDevice: Bool = false,
        connection: LoopdyLinkConnectionState,
        pushState: LoopdyLinkPushState? = nil,
        revision: Int
    ) -> LoopdyLinkDevice {
        LoopdyLinkDevice(
            id: id,
            name: name,
            kind: kind,
            isCurrentDevice: isCurrentDevice,
            connection: connection,
            pushState: pushState,
            lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
            revision: revision
        )
    }
}

@MainActor
private final class DeferredAccountDeviceClient: LoopdyLinkDeviceClient {
    var replies: [CheckedContinuation<[LoopdyLinkDevice], Never>] = []
    var observesCancellation = false
    func listDevices() async throws -> [LoopdyLinkDevice] {
        let devices = await withCheckedContinuation { replies.append($0) }
        if observesCancellation { try Task.checkCancellation() }
        return devices
    }
    func renameDevice(id: String, name: String, expectedRevision: Int) async throws -> LoopdyLinkDevice { throw URLError(.unsupportedURL) }
    func unpairDevice(id: String, expectedRevision: Int) async throws { throw URLError(.unsupportedURL) }
    func beginPairing() async throws -> LoopdyLinkPairingChallenge { throw URLError(.unsupportedURL) }
    func completePairing(reference: LoopdyLinkPairingReference) async throws -> LoopdyLinkDevice { throw URLError(.unsupportedURL) }

}

private extension LoopdyLinkDevice {
    static let phoneFixture = LoopdyLinkDevice(
        id: "phone-1",
        name: "This iPhone",
        kind: .phone,
        isCurrentDevice: true,
        connection: .online,
        pushState: nil,
        lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
        revision: 3
    )

    static let hostFixture = LoopdyLinkDevice(
        id: "host-1",
        name: "Home Hermes",
        kind: .hermesHost,
        isCurrentDevice: false,
        connection: .online,
        pushState: nil,
        lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
        revision: 7
    )
}
