import Foundation
import Observation

/// Main's notification implementation must verify the authenticated plugin
/// capability and recipient grant. Installed/configured-enabled is not readiness.
@MainActor
protocol HostPluginManagementServing: AnyObject {
    var isConnected: Bool { get }
    var savedConnection: DirectHermesSavedConnection? { get }
    func reconnect() async
    func managePlugins(_ params: [String: LoopdyJSONValue]) async throws -> LoopdyJSONValue
}

extension DirectHermesWorkspaceStore: HostPluginManagementServing {}

@MainActor
protocol HostNotificationSetupServing {
    func enroll(host: LoopdyConfiguredHost, connection: DirectHermesSavedConnection,
                isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult
    /// Removes only this device's recipient trust/grant metadata, not host data.
    func removeLocalEnrollment(host: LoopdyConfiguredHost) throws
}

enum HostNotificationSetupResult: Sendable {
    case enabled
    case backendRestartRequired
    case prerequisitesRequired
}

enum HostNotificationState: String, Codable, Sendable {
    case notConfigured, checking, installing, installed, enabled, backendRestartRequired
    case verificationRequired, prerequisitesRequired, permissionDenied, managementRejected, unsupported, replacementRequired, outcomeUnknown

    var message: String {
        switch self {
        case .notConfigured: "Notifications are off."
        case .checking: "Checking setup…"
        case .installing: "Installing plugin…"
        case .installed: "Plugin installed. Finishing setup…"
        case .enabled: "Notifications enabled."
        case .verificationRequired: "Check your saved setup to continue."
        case .backendRestartRequired: "Restart the hermes serve process on the host (not just the messaging gateway), then check again."
        case .prerequisitesRequired: "This computer needs notification support."
        case .permissionDenied: "This computer doesn't allow plugin installation."
        case .managementRejected: "This computer rejected installation. Check Hermes for details."
        case .unsupported: "This Hermes version doesn't support in-app installation."
        case .replacementRequired: "Update the existing Loopdy plugin on this computer."
        case .outcomeUnknown: "Couldn't confirm setup. Check again before reinstalling."
        }
    }
}

struct HostPluginIntent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case consented, installRequested, toggleRequested, verified }
    let identifier: String
    let revision: String
    /// Nil means process current scope for every list/install/toggle operation.
    let profile: String?
    var phase: Phase
}

struct HostPluginPin: Equatable, Sendable {
    /// Formerly promptclickrun/loopdy-plugin. The pinned revision's updater accepts
    /// both names (bighelp-plugin #51 onward), and GitHub redirects the old one.
    let identifier = "promptclickrun/bighelp-plugin"
    let revision: String
    init(revision: String) throws {
        guard revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DirectHermesError.invalidResponse
        }
        self.revision = revision
    }
    static var bundled: HostPluginPin? {
        guard let revision = Bundle.main.object(forInfoDictionaryKey: "LoopdyNotificationPluginRevision") as? String else { return nil }
        return try? HostPluginPin(revision: revision)
    }
    var installParameters: [String: LoopdyJSONValue] {
        ["action": .string("install"), "identifier": .string(identifier), "catalog_name": .null,
         "ref": .string(revision), "enable": .boolean(true), "force": .boolean(false)]
    }
    /// The stock manager has no custom-ref update verb. An explicit reviewed
    /// replacement uses its install API with force=true; the host kill list and
    /// scanner still run and the exact pinned revision is read back afterward.
    var updateParameters: [String: LoopdyJSONValue] {
        ["action": .string("install"), "identifier": .string(identifier), "catalog_name": .null,
         "ref": .string(revision), "enable": .boolean(true), "force": .boolean(true)]
    }
}

struct HostInstalledPlugin: Equatable {
    let name: String
    let key: String
    let pinnedSHA: String?
    let configuredEnabled: Bool

    static func decodeList(_ value: LoopdyJSONValue) throws -> [HostInstalledPlugin] {
        guard let values = value.object?["plugins"]?.array, values.count <= 4096 else { throw DirectHermesError.invalidResponse }
        // Only Loopdy is managed here. An unrelated plugin's new status or
        // metadata must not invalidate the exact target's installed readback.
        let targets = try values.filter { value in
            guard let name = value.object?["name"]?.string,
                  !name.isEmpty, name.utf8.count <= 256 else { throw DirectHermesError.invalidResponse }
            return name == "loopdy"
        }
        guard targets.count <= 1 else { throw DirectHermesError.invalidResponse }
        return try targets.map { value in
            guard let object = value.object, let name = object["name"]?.string,
                  let key = object["key"]?.string, !name.isEmpty, name.utf8.count <= 256,
                  !key.isEmpty, key.utf8.count <= 512, let status = object["status"]?.string,
                  ["enabled", "disabled", "not enabled"].contains(status) else {
                throw DirectHermesError.invalidResponse
            }
            if let pin = object["pinned_sha"], pin != .null {
                guard let revision = pin.string, (try? HostPluginPin(revision: revision)) != nil else {
                    throw DirectHermesError.invalidResponse
                }
            }
            return Self(name: name, key: key, pinnedSHA: object["pinned_sha"]?.string, configuredEnabled: status == "enabled")
        }
    }
}

@MainActor
@Observable
final class HostNotificationSetupModel {
    private(set) var state: HostNotificationState
    private(set) var isWorking = false
    private(set) var providerFailure: LoopdyManagedNotificationSetupError?
    let pin: HostPluginPin?
    let hostID: UUID
    let enrollNotifications: Bool
    @ObservationIgnored private let registry: LoopdyHostRegistry
    @ObservationIgnored private let management: any HostPluginManagementServing
    @ObservationIgnored private var operation: UUID?

    init(host: LoopdyConfiguredHost, registry: LoopdyHostRegistry, pin: HostPluginPin? = .bundled,
         management: (any HostPluginManagementServing)? = nil, enrollNotifications: Bool = true) {
        hostID = host.id
        self.registry = registry
        self.management = management ?? registry.workspace(for: host)
        self.pin = pin
        self.enrollNotifications = enrollNotifications
        // Preserve the user's saved opt-in without prompting on every visit.
        // Actual grant and delivery authority still belong to the service ledger.
        state = enrollNotifications ? host.notificationState : .notConfigured
    }

    var message: String {
        if let providerFailure { return providerFailure.localizedDescription }
        guard !enrollNotifications else { return state.message }
        return switch state {
        case .notConfigured:
            "Add optional bighelp features to this computer."
        case .installed, .enabled:
            "Plugin installed."
        case .verificationRequired:
            "Check the installed plugin."
        case .prerequisitesRequired:
            "Update bighelp to install this plugin."
        default:
            state.message
        }
    }

    var actionTitle: String? {
        guard !isWorking else { return nil }
        return switch state {
        case .enabled:
            nil
        case .checking:
            "Check Again"
        case .installing, .outcomeUnknown:
            "Check Installed State"
        case .installed:
            enrollNotifications ? "Continue Notification Setup" : nil
        case .verificationRequired:
            enrollNotifications ? "Verify Notification Setup" : nil
        case .notConfigured:
            enrollNotifications ? "Enable Notifications" : "Install Loopdy Plugin"
        case .backendRestartRequired:
            "Check After Backend Restart"
        case .managementRejected:
            "Retry Plugin Setup"
        case .permissionDenied:
            "Check Host Permission Again"
        case .unsupported:
            "Check Host Support Again"
        case .replacementRequired:
            "Check Installed Plugin Again"
        case .prerequisitesRequired:
            enrollNotifications ? "Try Notification Setup Again" : "Check Plugin Requirements Again"
        }
    }

    /// Opening a plugin page is a read, not consent to install or enroll.
    func refreshInstalledState() async {
        guard !enrollNotifications, !isWorking,
              let host = registry.hosts.first(where: { $0.id == hostID }),
              let managementOwner = registry.beginPluginManagement(hostID: hostID) else { return }
        defer { registry.endPluginManagement(hostID: hostID, owner: managementOwner) }
        let generation = registry.generation
        let scope = registry.accountScope
        let request = UUID()
        operation = request
        isWorking = true
        defer { if operation == request { isWorking = false } }
        func owns() -> Bool {
            operation == request && registry.generation == generation
                && registry.accountScope == scope
                && registry.hosts.contains(where: { $0.id == hostID }) && !Task.isCancelled
        }
        state = .checking
        do {
            if !management.isConnected { await management.reconnect() }
            guard owns() else { return }
            guard management.isConnected,
                  DirectHermesIdentity.matches(management.savedConnection?.identity, host.principalIdentity) else {
                throw DirectHermesError.notConnected
            }
            let rows = try HostInstalledPlugin.decodeList(
                await management.managePlugins(["action": .string("list")])
            )
            guard owns() else { return }
            state = rows.first?.configuredEnabled == true ? .installed : .notConfigured
        } catch {
            guard owns() else { return }
            state = Self.failureState(error)
        }
    }

    func cancel() {
        let wasActive = operation != nil || isWorking
        operation = nil
        isWorking = false
        guard wasActive, var host = registry.hosts.first(where: { $0.id == hostID }) else { return }
        switch state {
        case .installing:
            // The request may still have reached the host. Preserve its intent
            // and require list readback instead of exposing another install.
            state = .outcomeUnknown
            if enrollNotifications {
                host.notificationState = .outcomeUnknown
                try? registry.update(host)
            }
        case .checking:
            state = enrollNotifications ? host.notificationState : .notConfigured
        default:
            break
        }
        // Persisted install/toggle intent remains for readback. Never replay it.
    }

    /// User consent authorizes one pinned install/enable in backend current scope,
    /// not a restart, force replacement, profile change, or Link enrollment.
    func enable() async {
        guard !isWorking, let original = registry.hosts.first(where: { $0.id == hostID }) else { return }
        guard let managementOwner = registry.beginPluginManagement(hostID: hostID) else { state = .checking; return }
        defer { registry.endPluginManagement(hostID: hostID, owner: managementOwner) }
        let owner = registry.generation
        let scope = registry.accountScope
        let operationID = UUID()
        operation = operationID
        isWorking = true
        providerFailure = nil
        defer { if operation == operationID { isWorking = false } }
        @MainActor func owns() -> Bool {
            registry.generation == owner && registry.accountScope == scope && operation == operationID
                && registry.hosts.contains(where: { $0.id == hostID }) && !Task.isCancelled
        }
        var host = original
        let workspace = management
        do {
            if !workspace.isConnected { await workspace.reconnect() }
            guard owns() else { return }
            guard workspace.isConnected else { throw DirectHermesError.notConnected }
            guard DirectHermesIdentity.matches(workspace.savedConnection?.identity, host.principalIdentity) else {
                throw DirectHermesError.identityChanged
            }
            state = .checking
            var rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
            guard owns() else { return }
            var matches = rows.filter { $0.name == "loopdy" }
            guard matches.count <= 1 else { try finish(.replacementRequired, host: &host); return }
            if let installed = matches.first {
                if !enrollNotifications, let pin, installed.pinnedSHA != pin.revision {
                    host.pluginIntent = HostPluginIntent(
                        identifier: pin.identifier, revision: pin.revision,
                        profile: nil, phase: .installRequested
                    )
                    try registry.update(host)
                    state = .installing
                    var updateError: (any Error)?
                    do { _ = try await workspace.managePlugins(pin.updateParameters) }
                    catch { updateError = error }
                    guard owns() else { return }
                    let observed = try HostInstalledPlugin.decodeList(
                        await workspace.managePlugins(["action": .string("list")])
                    ).filter { $0.name == "loopdy" }
                    guard owns() else { return }
                    guard observed.count == 1, let verified = observed.first,
                          verified.pinnedSHA == pin.revision, verified.configuredEnabled else {
                        try finish(updateError.map(Self.failureState) ?? .outcomeUnknown, host: &host)
                        return
                    }
                    host.pluginIntent = HostPluginIntent(
                        identifier: pin.identifier, revision: pin.revision,
                        profile: nil, phase: .verified
                    )
                    try finish(.installed, host: &host)
                    return
                }
                if !installed.configuredEnabled {
                    try Self.validateKey(installed.key)
                    var toggleError: (any Error)?
                    do {
                        _ = try await workspace.managePlugins(["action": .string("toggle"),
                            "key": .string(installed.key), "enable": .boolean(true)])
                    } catch { toggleError = error }
                    guard owns() else { return }
                    // Enabling preserves the operator's installed revision. A
                    // lost receipt is reconciled without reinstalling anything.
                    let observed = try HostInstalledPlugin.decodeList(
                        await workspace.managePlugins(["action": .string("list")])
                    ).filter { $0.name == "loopdy" }
                    guard owns() else { return }
                    guard observed.count == 1, let verified = observed.first,
                          verified.key == installed.key, verified.pinnedSHA == installed.pinnedSHA,
                          verified.configuredEnabled else {
                        try finish(toggleError.map(Self.failureState) ?? .outcomeUnknown, host: &host)
                        return
                    }
                }
                // The pin controls an installation we initiate, not compatibility
                // of an operator's existing plugin. Enrollment verifies the live
                // authenticated capability schema, host identity, and grant.
                // Observed installation also resolves an older app's install intent.
                host.pluginIntent = nil
                try finish(.installed, host: &host)
                try await enrollInstalled(host: &host, connection: workspace.savedConnection, isCurrent: { owns() })
                return
            }
            guard let pin else { try finish(.prerequisitesRequired, host: &host); return }
            if let intent = host.pluginIntent,
               intent.profile != nil || intent.identifier != pin.identifier || intent.revision != pin.revision {
                try finish(.replacementRequired, host: &host)
                return
            }
            if let found = matches.first, found.pinnedSHA != pin.revision {
                try finish(.replacementRequired, host: &host); return
            }
            if matches.isEmpty {
                // A lost reply may still be executing on the backend. Absence is
                // not proof of rejection and never authorizes duplicate install.
                if let intent = host.pluginIntent, intent.phase != .consented {
                    try finish(.outcomeUnknown, host: &host); return
                }
                host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision,
                    profile: nil, phase: .installRequested)
                if enrollNotifications { host.notificationState = .installing }
                try registry.update(host)
                state = .installing
                do { _ = try await workspace.managePlugins(pin.installParameters) }
                catch {
                    guard owns() else { return }
                    // Always reconcile once, including scanner/policy rejections
                    // that may follow a completed file install but failed enable.
                    do {
                        rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                    } catch {
                        guard owns() else { return }
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    guard owns() else { return }
                    matches = rows.filter { $0.name == "loopdy" }
                    guard matches.count == 1, matches[0].pinnedSHA == pin.revision else {
                        // A terminal RPC rejection followed by verified absence
                        // permits another explicit attempt, not automatic replay.
                        if matches.isEmpty, let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try finish(Self.failureState(error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                matches = rows.filter { $0.name == "loopdy" }
            }
            guard matches.count == 1, let installed = matches.first, installed.pinnedSHA == pin.revision else {
                try finish(.outcomeUnknown, host: &host); return
            }
            if !installed.configuredEnabled {
                if host.pluginIntent?.phase == .toggleRequested { try finish(.outcomeUnknown, host: &host); return }
                // Canonical key is read from this same verified list. Reject
                // controls and path traversal instead of interpolating into a URL.
                try Self.validateKey(installed.key)
                host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision, profile: nil, phase: .toggleRequested)
                try registry.update(host)
                do {
                    _ = try await workspace.managePlugins(["action": .string("toggle"), "key": .string(installed.key), "enable": .boolean(true)])
                } catch {
                    guard owns() else { return }
                    do {
                        rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                    } catch {
                        guard owns() else { return }
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    guard owns() else { return }
                    let observed = rows.filter { $0.name == "loopdy" }
                    guard observed.count == 1, observed[0].key == installed.key,
                          observed[0].pinnedSHA == pin.revision else {
                        try finish(.outcomeUnknown, host: &host); return
                    }
                    if !observed[0].configuredEnabled {
                        if let directError = error as? DirectHermesError, case .rpcRejected = directError {
                            host.pluginIntent?.phase = .consented
                        }
                        try finish(Self.failureState(error), host: &host); return
                    }
                }
                guard owns() else { return }
                rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
                guard owns() else { return }
                guard rows.filter({ $0.name == "loopdy" }).count == 1,
                      rows.contains(where: { $0.key == installed.key && $0.pinnedSHA == pin.revision && $0.configuredEnabled }) else {
                    try finish(.outcomeUnknown, host: &host); return
                }
            }
            host.pluginIntent = HostPluginIntent(identifier: pin.identifier, revision: pin.revision, profile: nil, phase: .verified)
            try finish(.installed, host: &host)
            try await enrollInstalled(host: &host, connection: workspace.savedConnection, isCurrent: { owns() })
        } catch {
            guard owns() else { return }
            state = Self.failureState(error)
            host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
            providerFailure = error as? LoopdyManagedNotificationSetupError
            if enrollNotifications { host.notificationState = state }
            try? registry.update(host)
        }
    }

    private func enrollInstalled(host: inout LoopdyConfiguredHost, connection: DirectHermesSavedConnection?,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard enrollNotifications else { return }
        guard let setup = registry.notificationSetup, let connection,
              DirectHermesIdentity.matches(connection.identity, host.principalIdentity) else {
            try finish(.prerequisitesRequired, host: &host); return
        }
        let result = try await setup.enroll(host: host, connection: connection, isCurrent: isCurrent)
        guard isCurrent() else { return }
        host.notificationBinding = registry.hosts.first(where: { $0.id == host.id })?.notificationBinding
        switch result {
        case .enabled: try finish(.enabled, host: &host)
        case .backendRestartRequired: try finish(.backendRestartRequired, host: &host)
        case .prerequisitesRequired: try finish(.prerequisitesRequired, host: &host)
        }
    }

    private func finish(_ next: HostNotificationState, host: inout LoopdyConfiguredHost) throws {
        if enrollNotifications { host.notificationState = next }
        try registry.update(host)
        state = next
    }
    private static func validateKey(_ key: String) throws {
        guard key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }),
              !key.contains(".."), !key.contains("\\") else { throw DirectHermesError.invalidResponse }
    }
    private static func failureState(_ error: any Error) -> HostNotificationState {
        if error is LoopdyManagedNotificationSetupError { return .prerequisitesRequired }
        if let linkError = error as? LoopdyLinkAPIError,
           case let .requestFailed(_, code) = linkError {
            switch code {
            case "not_found", "device_credentials_missing", "notification_service_unavailable",
                 "notification_mobile_required", "notification_recipient_unavailable",
                 "notification_recipient_changed":
                return .prerequisitesRequired
            default:
                break
            }
        }
        guard let error = error as? DirectHermesError else { return .outcomeUnknown }
        switch error {
        case .rpcRejected(code: -32601): return .unsupported
        case .rpcRejected(code: 403): return .permissionDenied
        case .rpcRejected(code: 5026): return .managementRejected
        default: return .outcomeUnknown
        }
    }
}
