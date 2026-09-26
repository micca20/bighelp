import CryptoKit
import Foundation
import Observation

struct BighelpConnectionGracePeriod {
    static let duration: TimeInterval = 12

    static func deadline(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(duration)
    }

    static func shouldRevealRecovery(startedAt: Date, now: Date) -> Bool {
        now >= deadline(startedAt: startedAt)
    }
}

@MainActor
struct BighelpLocalCacheRefreshCoordinator {
    let invalidateStaleWork: @MainActor () async -> Void
    let clearCurrentHostCache: @MainActor () async throws -> Void
    let refreshAuthoritativeState: @MainActor () async -> Bool

    func clearAndRefresh() async -> Bool {
        await invalidateStaleWork()
        do {
            try await clearCurrentHostCache()
        } catch {
            return false
        }
        return await refreshAuthoritativeState()
    }
}

/// Remembers only a one-way fingerprint of the local bighelp device and the
/// Hermes host identities that previously completed an authenticated Link
/// handshake. This is a presentation optimization, never an authentication
/// credential: an authoritative empty/changed host list still restores the
/// pairing or connection gate.
final class BighelpWorkspaceAdmissionStore {
    static let defaultsKey = "loopdy.link.workspace-admission.v1"

    private struct Record: Codable {
        let version: Int
        let localDeviceFingerprint: String
        let hostFingerprints: [String]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordVerifiedAdmission(
        localDeviceID: String,
        devices: [BighelpLinkDevice]
    ) {
        let localDeviceID = localDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostFingerprints = validHostIDs(in: devices).map(Self.fingerprint).sorted()
        guard !localDeviceID.isEmpty, !hostFingerprints.isEmpty else { return }
        let record = Record(
            version: 1,
            localDeviceFingerprint: Self.fingerprint(localDeviceID),
            hostFingerprints: hostFingerprints
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func wasPreviouslyAdmitted(
        localDeviceID: String?,
        devices: [BighelpLinkDevice],
        deviceLoadState: BighelpLinkLoadState
    ) -> Bool {
        guard
            let localDeviceID = localDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !localDeviceID.isEmpty,
            let data = defaults.data(forKey: Self.defaultsKey),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.version == 1,
            record.localDeviceFingerprint == Self.fingerprint(localDeviceID),
            !record.hostFingerprints.isEmpty
        else { return false }

        guard deviceLoadState == .loaded else {
            // During a cold restore, the signed-in device identity is already
            // keychain-backed while the paired-device catalog is still loading.
            return true
        }
        let currentHosts = Set(validHostIDs(in: devices).map(Self.fingerprint))
        return !currentHosts.isDisjoint(with: record.hostFingerprints)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func validHostIDs(in devices: [BighelpLinkDevice]) -> [String] {
        devices.compactMap { device in
            let id = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard device.kind == .hermesHost, device.revision > 0, !id.isEmpty else {
                return nil
            }
            return id
        }
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data("loopdy-admission-v1:\(value)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The portion of Link readiness that cannot be inferred from the device list.
/// A transport being created is not enough to release the app gate; the socket
/// integration must explicitly promote this value to `verified` after its
/// authenticated handshake has been accepted.
enum BighelpAppReadinessLinkState: Equatable, Sendable {
    case unverified
    case connecting
    case retrying
    case verified
}

enum BighelpForegroundLinkRecoveryAction: Equatable, Sendable {
    case none
    case restoreCredentials
    case startConnection
    case retryConnection
}

enum BighelpForegroundLinkRecovery {
    static func resolve(
        account: BighelpLinkAccountState,
        hasCredentials: Bool,
        link: BighelpLinkLiveSocketState
    ) -> BighelpForegroundLinkRecoveryAction {
        if account == .failed, !hasCredentials {
            return .restoreCredentials
        }
        guard account == .ready, hasCredentials else { return .none }
        switch link {
        case .stopped:
            return .startConnection
        case .connecting, .retrying, .superseded, .verified:
            // Returning to the foreground is an explicit ownership boundary.
            // Tear down any stale transport and repeat the authenticated Link
            // handshake instead of trusting pre-suspension socket state.
            return .retryConnection
        }
    }
}

enum BighelpAccountWorkspaceBoundary {
    static func shouldClear(
        account: BighelpLinkAccountState,
        hasCredentials: Bool,
        needsLocalCleanup: Bool = false
    ) -> Bool {
        (account == .signedOut || needsLocalCleanup) && !hasCredentials
    }

    @MainActor
    static func clearWorkspace(
        isCurrent: () -> Bool,
        steps: [@MainActor () async -> Void]
    ) async {
        // Every await may outlive the account that initiated sign-out.
        // Recheck before each destructive phase, including the final store reset.
        for step in steps {
            guard !Task.isCancelled, isCurrent() else { return }
            await step()
        }
    }
}

enum BighelpAppReadinessState: Equatable, Sendable {
    case accountRequired
    case authenticating
    case pairingRequired
    case connecting
    case ready
}

struct BighelpReadinessDriveTrigger: Equatable, Sendable {
    let readiness: BighelpAppReadinessState
    let link: BighelpAppReadinessLinkState

    var shouldHydrateWorkspace: Bool {
        readiness == .ready && link == .verified
    }
}

enum BighelpAppReadinessAction: Equatable, Sendable {
    case signIn
    case createAccount
    case pairDevice
    case retryConnection

    var title: String {
        switch self {
        case .signIn: "Sign in"
        case .createAccount: "Create account"
        case .pairDevice: "Pair Hermes host"
        case .retryConnection: "Retry connection"
        }
    }
}

struct BighelpAppReadinessPresentation: Equatable, Sendable {
    let state: BighelpAppReadinessState
    let linkState: BighelpAppReadinessLinkState
    let deviceLoadState: BighelpLinkLoadState
    let workspaceWasPreviouslyAdmitted: Bool
    let title: String
    let detail: String
    let actions: [BighelpAppReadinessAction]

    var allowsWorkspace: Bool {
        state == .ready
    }

    var devicesLoaded: Bool {
        deviceLoadState == .loaded
    }
}

/// Pure app-gate policy. It deliberately consumes only account state, the
/// validated device summaries, and an independently verified Link state. It
/// never receives credentials or other account data, making it safe to use in
/// the shell without accidentally copying secrets into UI state.
enum BighelpAppReadiness {
    static func resolve(
        account: BighelpLinkAccountState,
        devices: [BighelpLinkDevice],
        link: BighelpAppReadinessLinkState,
        deviceLoadState: BighelpLinkLoadState = .loaded,
        workspaceWasPreviouslyAdmitted: Bool = false
    ) -> BighelpAppReadinessPresentation {
        let state: BighelpAppReadinessState
        switch account {
        case .signedOut, .failed:
            state = .accountRequired
        case .working:
            state = .authenticating
        case .ready:
            if deviceLoadState != .loaded {
                state = workspaceWasPreviouslyAdmitted ? .ready : .connecting
            } else if !hasHermesHost(in: devices) {
                state = .pairingRequired
            } else if workspaceWasPreviouslyAdmitted {
                // Once this account and host have completed an authenticated
                // handshake, foreground transport recovery is background state.
                // Never replace the mounted workspace with a transient gate.
                state = .ready
            } else if !hasOnlineHermesHost(in: devices) {
                state = .connecting
            } else if link == .verified {
                state = .ready
            } else {
                state = .connecting
            }
        }

        return BighelpAppReadinessPresentation(
            state: state,
            linkState: link,
            deviceLoadState: deviceLoadState,
            workspaceWasPreviouslyAdmitted: workspaceWasPreviouslyAdmitted,
            title: title(for: state),
            detail: detail(
                for: state,
                link: link,
                devicesLoaded: deviceLoadState == .loaded
            ),
            actions: actions(for: state)
        )
    }

    private static func hasHermesHost(in devices: [BighelpLinkDevice]) -> Bool {
        devices.contains {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.kind == .hermesHost
                && $0.revision > 0
        }
    }

    private static func hasOnlineHermesHost(in devices: [BighelpLinkDevice]) -> Bool {
        devices.contains {
            hasValidHermesHost($0)
                && $0.connection == .online
        }
    }

    private static func hasValidHermesHost(_ device: BighelpLinkDevice) -> Bool {
        !device.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && device.kind == .hermesHost
            && device.revision > 0
    }

    private static func title(for state: BighelpAppReadinessState) -> String {
        switch state {
        case .accountRequired:
            return "Sign in to bighelp"
        case .authenticating:
            return "Setting up your account"
        case .pairingRequired:
            return "Connect your Hermes host"
        case .connecting:
            return "Connecting to your Hermes host"
        case .ready:
            return "Workspace ready"
        }
    }

    private static func detail(
        for state: BighelpAppReadinessState,
        link: BighelpAppReadinessLinkState,
        devicesLoaded: Bool
    ) -> String {
        switch state {
        case .accountRequired:
            return "Sign in or create an account to securely connect your workspace."
        case .authenticating:
            return "Securely signing you in. This will only take a moment."
        case .pairingRequired:
            return "Pair bighelp Link with your Hermes host before opening your workspace."
        case .connecting:
            if !devicesLoaded {
                return "Checking your paired devices and secure Link connection. Your workspace will open when it’s ready."
            }
            switch link {
            case .unverified:
                return "bighelp is validating the secure Link connection. Your workspace will open when it’s ready."
            case .connecting:
                return "Connecting securely to your Hermes host. Your workspace will open when it’s ready."
            case .retrying:
                return "bighelp is retrying the secure Link connection. Retry to continue to your workspace."
            case .verified:
                return "Your Hermes host is not online yet. bighelp will keep trying the secure connection."
            }
        case .ready:
            return ""
        }
    }

    private static func actions(for state: BighelpAppReadinessState) -> [BighelpAppReadinessAction] {
        switch state {
        case .accountRequired:
            return [.signIn, .createAccount]
        case .pairingRequired:
            return [.pairDevice]
        case .connecting:
            return [.retryConnection]
        case .authenticating, .ready:
            return []
        }
    }
}
