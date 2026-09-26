import Foundation
import Observation

@Observable
@MainActor
final class LoopdyLinkHostSelectionStore {
    private enum Key {
        static let selected = "loopdy.link.selected-host-id"
        static let primary = "loopdy.link.primary-host-id"
    }

    private let defaults: UserDefaults
    private var knownHostIDs: Set<String> = []
    private(set) var selectedHostID: String?
    private(set) var primaryHostID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        primaryHostID = defaults.string(forKey: Key.primary)
        // Primary owns a new launch; selection changes only the current session.
        selectedHostID = primaryHostID ?? defaults.string(forKey: Key.selected)
    }

    func reconcile(hostIDs: [String]) {
        knownHostIDs = Set(hostIDs)
        guard let fallback = hostIDs.sorted().first else {
            updateSelected(nil)
            updatePrimary(nil)
            return
        }

        if primaryHostID.map(knownHostIDs.contains) != true {
            updatePrimary(selectedHostID.flatMap { knownHostIDs.contains($0) ? $0 : nil } ?? fallback)
        }
        if selectedHostID.map(knownHostIDs.contains) != true {
            updateSelected(primaryHostID.flatMap { knownHostIDs.contains($0) ? $0 : nil } ?? fallback)
        } else {
            persist(selectedHostID, forKey: Key.selected)
        }
    }

    @discardableResult
    func selectHost(_ hostID: String) -> Bool {
        guard knownHostIDs.contains(hostID), selectedHostID != hostID else { return false }
        updateSelected(hostID)
        return true
    }

    @discardableResult
    func setPrimaryHost(_ hostID: String) -> Bool {
        guard knownHostIDs.contains(hostID), primaryHostID != hostID else { return false }
        updatePrimary(hostID)
        return true
    }

    func resetForAccountBoundary() {
        knownHostIDs.removeAll()
        updateSelected(nil)
        updatePrimary(nil)
    }

    private func updateSelected(_ hostID: String?) {
        selectedHostID = hostID
        persist(hostID, forKey: Key.selected)
    }

    private func updatePrimary(_ hostID: String?) {
        primaryHostID = hostID
        persist(hostID, forKey: Key.primary)
    }

    private func persist(_ hostID: String?, forKey key: String) {
        if let hostID {
            defaults.set(hostID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@Observable
@MainActor
final class LoopdyLinkDeviceStore {
    private(set) var devices: [LoopdyLinkDevice] = []
    private(set) var loadState: LoopdyLinkLoadState = .idle
    private(set) var pendingAction: LoopdyLinkPendingAction?
    private(set) var actionError: String?
    private(set) var renameValidationError: String?
    private(set) var loadError: String?
    private(set) var pairingState: LoopdyLinkPairingState = .idle

    private let client: any LoopdyLinkDeviceClient
    private let hostSelection: LoopdyLinkHostSelectionStore
    private let onSelectedHostChange: (String?) -> Void
    private let now: () -> Date
    private var activePairingChallenge: LoopdyLinkPairingChallenge?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var loadGeneration = UUID()
    private var accountGeneration = UUID()

    init(
        client: any LoopdyLinkDeviceClient,
        hostSelection: LoopdyLinkHostSelectionStore = LoopdyLinkHostSelectionStore(),
        onSelectedHostChange: @escaping (String?) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.hostSelection = hostSelection
        self.onSelectedHostChange = onSelectedHostChange
        self.now = now
    }

    func device(id: String) -> LoopdyLinkDevice? {
        devices.first(where: { $0.id == id })
    }

    var selectedHostID: String? { hostSelection.selectedHostID }
    var primaryHostID: String? { hostSelection.primaryHostID }

    @discardableResult
    func selectHost(_ id: String) -> Bool {
        guard device(id: id)?.kind == .hermesHost,
              hostSelection.selectHost(id)
        else { return false }
        onSelectedHostChange(id)
        return true
    }

    @discardableResult
    func setPrimaryHost(_ id: String) -> Bool {
        guard device(id: id)?.kind == .hermesHost else { return false }
        return hostSelection.setPrimaryHost(id)
    }

    func resetForAccountBoundary() {
        accountGeneration = UUID()
        loadGeneration = UUID()
        let staleWaiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in staleWaiters { waiter.resume(returning: false) }
        hostSelection.resetForAccountBoundary()
        devices.removeAll()
        loadState = .idle
        pendingAction = nil
        actionError = nil
        renameValidationError = nil
        loadError = nil
        pairingState = .idle
        activePairingChallenge = nil
    }

    func load() async {
        guard !Task.isCancelled else { return }
        let account = accountGeneration
        if loadState == .loading {
            let retry = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                loadWaiters.append(continuation)
            }
            // A fresh foreground caller must not inherit its predecessor's
            // cancellation. Account retirement is never permission to retry.
            if retry, !Task.isCancelled, accountGeneration == account { await load() }
            return
        }
        loadGeneration = UUID()
        let generation = loadGeneration
        loadState = .loading
        loadError = nil
        var retryWaiters = false
        defer {
            if loadGeneration == generation {
                let waiters = loadWaiters
                loadWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: retryWaiters) }
            }
        }
        do {
            let loaded = try await client.listDevices()
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            devices = Self.sorted(loaded)
            hostSelection.reconcile(hostIDs: devices.compactMap {
                $0.kind == .hermesHost ? $0.id : nil
            })
            loadState = .loaded
        } catch {
            guard loadGeneration == generation else { return }
            if Task.isCancelled {
                retryWaiters = true
                loadState = .idle
                return
            }
            loadState = .failed
            loadError = "Paired devices could not be loaded. Try again."
        }
    }

    func renameDevice(id: String, name: String) async {
        renameValidationError = nil
        actionError = nil
        guard pendingAction == nil else { return }
        guard let current = device(id: id) else {
            actionError = "That device is no longer paired."
            return
        }
        guard let normalizedName = validatedName(name) else { return }

        let expectedRevision = current.revision
        pendingAction = .rename(deviceID: id)
        defer { pendingAction = nil }
        do {
            let confirmed = try await client.renameDevice(
                id: id,
                name: normalizedName,
                expectedRevision: expectedRevision
            )
            guard
                confirmed.id == id,
                confirmed.revision > expectedRevision,
                device(id: id)?.revision == expectedRevision
            else {
                actionError = "That device changed elsewhere. Refresh and try again."
                return
            }
            replace(confirmed)
        } catch {
            actionError = "That device could not be renamed. Try again."
        }
    }

    func unpairDevice(id: String) async {
        actionError = nil
        guard pendingAction == nil else { return }
        guard let current = device(id: id) else {
            actionError = "That device is no longer paired."
            return
        }

        let expectedRevision = current.revision
        pendingAction = .unpair(deviceID: id)
        defer { pendingAction = nil }
        do {
            try await client.unpairDevice(id: id, expectedRevision: expectedRevision)
            guard device(id: id)?.revision == expectedRevision else {
                actionError = "That device changed elsewhere. Refresh and try again."
                return
            }
            let previousSelectedHostID = hostSelection.selectedHostID
            devices.removeAll(where: { $0.id == id })
            if current.kind == .hermesHost {
                hostSelection.reconcile(hostIDs: devices.compactMap {
                    $0.kind == .hermesHost ? $0.id : nil
                })
                if hostSelection.selectedHostID != previousSelectedHostID {
                    onSelectedHostChange(hostSelection.selectedHostID)
                }
            }
        } catch {
            actionError = "That device could not be unpaired. Try again."
        }
    }

    func clearActionError() {
        actionError = nil
    }


    func beginPairing() async {
        guard pairingState != .requesting, pairingState != .pairing else { return }
        pairingState = .requesting
        activePairingChallenge = nil
        do {
            let challenge = try await client.beginPairing()
            guard challenge.expiresAt > now() else {
                pairingState = .expired
                return
            }
            activePairingChallenge = challenge
            pairingState = .ready(challenge)
        } catch {
            pairingState = .failed("Pairing could not be started. Try again.")
        }
    }

    func completePairing(code: String, verificationCode: String? = nil) async {
        guard let normalizedCode = LoopdyLinkPairingCode.normalized(code) else {
            pairingState = .failed("Enter the six-character pairing code.")
            return
        }
        let normalizedFingerprint = verificationCode.flatMap(
            LoopdyLinkPairingKeyCommitment.normalizedFingerprint
        )
        await completePairing(
            reference: LoopdyLinkPairingReference(
                flowID: nil,
                code: normalizedCode,
                keyFingerprint: normalizedFingerprint
            )
        )
    }

    func completePairing(reference: LoopdyLinkPairingReference) async {
        guard pairingState != .pairing else { return }
        guard let challenge = activePairingChallenge else {
            pairingState = .failed("Start a new pairing session and try again.")
            return
        }
        guard challenge.expiresAt > now() else {
            activePairingChallenge = nil
            pairingState = .expired
            return
        }
        guard let normalizedCode = LoopdyLinkPairingCode.normalized(reference.code) else {
            pairingState = .failed("Enter the six-character pairing code.")
            return
        }
        guard reference.hasValidVerification else {
            pairingState = .failed("Enter the host’s 16-character verification code.")
            return
        }

        pairingState = .pairing
        do {
            let confirmed = try await client.completePairing(
                reference: LoopdyLinkPairingReference(
                    flowID: reference.flowID,
                    code: normalizedCode,
                    keyCommitment: reference.keyCommitment,
                    keyFingerprint: reference.keyFingerprint
                )
            )
            guard !confirmed.id.isEmpty, confirmed.revision > 0 else {
                pairingState = .failed("Pairing could not be confirmed. Try again.")
                return
            }
            replaceOrInsert(confirmed)
            hostSelection.reconcile(hostIDs: devices.compactMap {
                $0.kind == .hermesHost ? $0.id : nil
            })
            activePairingChallenge = nil
            pairingState = .paired(deviceID: confirmed.id)
        } catch LoopdyLinkAPIError.pairingIdentityMismatch {
            pairingState = .failed("The host identity did not match. Start a new pairing session.")
        } catch {
            pairingState = .failed("That pairing code could not be confirmed. Try again.")
        }
    }


    private func validatedName(_ proposedName: String) -> String? {
        let normalized = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            renameValidationError = "Enter a device name."
            return nil
        }
        guard normalized.unicodeScalars.count <= 64 else {
            renameValidationError = "Use 64 characters or fewer."
            return nil
        }
        guard !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            renameValidationError = "Device names can’t contain control characters."
            return nil
        }
        return normalized
    }

    private func replace(_ confirmed: LoopdyLinkDevice) {
        guard let index = devices.firstIndex(where: { $0.id == confirmed.id }) else { return }
        devices[index] = confirmed
        devices = Self.sorted(devices)
    }

    private func replaceOrInsert(_ confirmed: LoopdyLinkDevice) {
        if devices.contains(where: { $0.id == confirmed.id }) {
            replace(confirmed)
        } else {
            devices.append(confirmed)
            devices = Self.sorted(devices)
        }
    }

    private static func sorted(_ devices: [LoopdyLinkDevice]) -> [LoopdyLinkDevice] {
        devices.sorted { lhs, rhs in
            let lhsKey = sortKey(for: lhs)
            let rhsKey = sortKey(for: rhs)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func sortKey(for device: LoopdyLinkDevice) -> Int {
        if device.isCurrentDevice { return 0 }
        if device.kind == .hermesHost { return 30 }
        return switch device.connection {
        case .online: 10
        case .recent: 11
        case .offline: 12
        }
    }
}
