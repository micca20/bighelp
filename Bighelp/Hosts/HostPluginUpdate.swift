import Observation
import SwiftUI

/// Keeps a host's bighelp plugin current: compares the installed and running
/// versions with the one this app build installs, updates it, restarts Hermes
/// so the new code loads, and checks that the new version is actually running.
@MainActor
@Observable
final class HostPluginUpdateModel {
    enum State: Equatable {
        case idle, checking, notInstalled, upToDate, updateAvailable, restartNeeded, updating, restarting, failed
    }

    let hostID: UUID
    /// The version at the revision this app build installs.
    let latestVersion: String?
    private(set) var state: State = .idle
    private(set) var installedVersion: String?
    private(set) var runningVersion: String?
    private(set) var message: String?

    /// The running plugin can restart its own Hermes process (2.17.0 and later).
    /// Older running code can't, so the first update from it ends with a restart on the computer.
    private(set) var canRestartHost = false
    @ObservationIgnored private var runtimeID: String?
    @ObservationIgnored private weak var registry: BighelpHostRegistry?
    @ObservationIgnored private let pin: HostPluginPin?

    init(registry: BighelpHostRegistry?, hostID: UUID,
         pin: HostPluginPin? = .bundled, latestVersion: String? = HostPluginPin.bundledVersion) {
        self.registry = registry
        self.hostID = hostID
        self.pin = pin
        self.latestVersion = latestVersion
    }

    /// One model per host, so Settings, the host list and the host page agree.
    private static var shared: [UUID: HostPluginUpdateModel] = [:]

    static func model(for hostID: UUID, registry: BighelpHostRegistry) -> HostPluginUpdateModel {
        if let model = shared[hostID], model.registry === registry { return model }
        let model = HostPluginUpdateModel(registry: registry, hostID: hostID)
        shared[hostID] = model
        return model
    }

    /// Only an existing model; views that merely show a badge don't start checks.
    static func existingModel(for hostID: UUID) -> HostPluginUpdateModel? { shared[hostID] }

    /// Settings flags the host while this is true.
    var needsAttention: Bool { state == .updateAvailable || state == .restartNeeded }

    /// Short line for the Settings menu and the computers list.
    var attentionTitle: String? {
        switch state {
        case .updateAvailable: "bighelp plugin update available"
        case .restartNeeded: "Restart Hermes to finish the plugin update"
        default: nil
        }
    }

    /// Running code too old to restart itself: only the computer can finish the update.
    var needsRestartOnComputer: Bool { state == .restartNeeded && !canRestartHost }
    var isWorking: Bool { [.checking, .updating, .restarting].contains(state) }

    /// What the versions mean, given the installed files, the running code and this app's version.
    static func state(installed: String?, running: String?, latest: String?) -> State {
        func isCurrent(_ version: String?) -> Bool {
            guard let version, let latest else { return true }
            // A newer host is never downgraded.
            return HostPluginPin.compare(version, latest) != .orderedAscending
        }
        if !isCurrent(installed) { return .updateAvailable }
        if !isCurrent(running) { return .restartNeeded }
        return .upToDate
    }

    func check() async {
        guard !isWorking else { return }
        state = .checking
        message = nil
        await refresh()
    }

    /// Checks once per app session unless asked again.
    func checkIfNeeded() async {
        guard state == .idle || state == .failed else { return }
        await check()
    }

    /// Installs the bundled revision. Returns true when the new files are in place.
    func update() async -> Bool {
        guard state == .updateAvailable, let pin, let registry, let connection = currentConnection() else { return false }
        guard let lock = registry.beginPluginManagement(hostID: hostID) else {
            message = "Another plugin change is running on this host. Try again in a moment."
            return false
        }
        defer { registry.endPluginManagement(hostID: hostID, owner: lock) }
        state = .updating
        message = "Installing bighelp plugin \(latestVersion ?? "")…"
        var updateFailed = false
        do { _ = try await connection.workspace.managePlugins(pin.updateParameters) } catch { updateFailed = true }
        // Trust what the host now reports, not the install call's outcome.
        guard let installed = try? await installedPlugin(connection.workspace), installed.found else {
            fail(updateFailed
                 ? "The update didn't finish. Check your host connection and try again."
                 : "bighelp couldn't confirm the update. Check again in a moment.")
            return false
        }
        installedVersion = installed.version
        guard installed.pinnedSHA == pin.revision
                || Self.state(installed: installed.version, running: nil, latest: latestVersion) != .updateAvailable else {
            fail("The host still has version \(installed.version ?? "unknown"). Try the update again.")
            return false
        }
        state = .restartNeeded
        message = canRestartHost
            ? "Installed \(installed.version ?? latestVersion ?? "the update"). Restart Hermes to start using it."
            : Self.restartOnComputerMessage(installed: installed.version ?? latestVersion, running: runningVersion)
        return true
    }

    /// Restarts the messaging gateway and, when the running plugin supports it, the
    /// Hermes process this app is connected to. Then confirms the running version.
    func restart() async {
        guard state == .restartNeeded, let connection = currentConnection() else { return }
        state = .restarting
        let previousRuntime = runtimeID
        let hostCanRestart = canRestartHost

        // Hooks such as reply alerts run in the gateway's copy of the plugin.
        message = "Restarting the messaging gateway…"
        var gatewayRestarted = false
        do {
            let operations = DirectHermesHostOperationsClient(
                rpc: connection.direct, http: connection.direct, owner: connection.owner,
                currentOwner: { [weak self] in self?.currentConnection()?.owner }
            )
            let receipt = try await operations.launchMessagingGateway(.restart, profileID: connection.workspace.selectedProfile)
            let result = try await operations.poll(receipt, attempts: 30, intervalNanoseconds: 1_000_000_000)
            gatewayRestarted = result.phase == .succeeded
        } catch {
            gatewayRestarted = false
        }

        // The app's own connection and screens run in this process's copy.
        if hostCanRestart {
            message = "Restarting Hermes…"
            // The connection drops as the process restarts; that's expected.
            try? await connection.plugin.restartHost()
            await waitForHost(previousRuntime: previousRuntime)
        }

        await refresh()
        switch state {
        case .upToDate:
            message = "bighelp plugin \(runningVersion ?? installedVersion ?? "") is installed and running."
        case .restartNeeded where hostCanRestart:
            message = "Hermes restarted, but it still runs plugin \(runningVersion ?? "an older version"). Restart Hermes on your computer to finish."
        case .restartNeeded:
            message = (gatewayRestarted ? "The messaging gateway restarted and runs the new plugin. " : "")
                + Self.restartOnComputerMessage(installed: installedVersion, running: runningVersion)
        default:
            break
        }
    }

    // MARK: Checks

    private struct Connection {
        let workspace: DirectHermesWorkspaceStore
        let direct: DirectHermesClient
        let owner: WorkspaceOwner
        let plugin: DirectHermesNativePluginClient
    }

    private func currentConnection() -> Connection? {
        guard let registry, let host = registry.hosts.first(where: { $0.id == hostID }) else { return nil }
        let workspace = registry.workspace(for: host)
        guard workspace.isConnected, let direct = workspace.nativeClient,
              let authority = workspace.savedConnection?.workspaceAuthority,
              DirectHermesIdentity.matches(workspace.savedConnection?.identity, host.principalIdentity) else { return nil }
        let generation = registry.generation
        let connectionGeneration = workspace.connectionGeneration
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: connectionGeneration)
        let plugin = DirectHermesNativePluginClient(http: direct, owner: owner, currentOwner: { [weak registry] in
            registry?.generation == generation && workspace.connectionGeneration == connectionGeneration
                && workspace.isConnected ? owner : nil
        })
        return Connection(workspace: workspace, direct: direct, owner: owner, plugin: plugin)
    }

    private func refresh() async {
        // After a restart on the computer the old connection is gone; try once more.
        if currentConnection() == nil, let registry, let host = registry.hosts.first(where: { $0.id == hostID }) {
            let workspace = registry.workspace(for: host)
            if !workspace.isConnected { await workspace.reconnect() }
        }
        guard let connection = currentConnection() else {
            fail("Connect to this computer to check its bighelp plugin.")
            return
        }
        if let context = try? await connection.plugin.loadContext(force: true) {
            runningVersion = HostPluginPin.validVersion(context.pluginVersion) ? context.pluginVersion : nil
            runtimeID = context.runtimeID
            canRestartHost = context.features.contains(DirectHermesNativePluginClient.hostRestartFeature)
        } else {
            runningVersion = nil
            canRestartHost = false
        }
        guard let installed = try? await installedPlugin(connection.workspace) else {
            fail("bighelp couldn't read this computer's plugins. Check again in a moment.")
            return
        }
        installedVersion = installed.version
        guard installed.found else {
            state = .notInstalled
            message = "The bighelp plugin isn't installed on this computer."
            return
        }
        state = Self.state(installed: installed.version, running: runningVersion, latest: latestVersion)
        switch state {
        case .updateAvailable:
            message = "Version \(latestVersion ?? "") is available."
        case .restartNeeded:
            message = canRestartHost
                ? "Version \(installed.version ?? latestVersion ?? "") is installed, but Hermes is still running \(runningVersion ?? "an older version"). Restart Hermes to start using it."
                : Self.restartOnComputerMessage(installed: installed.version, running: runningVersion)
        default:
            message = nil
        }
    }

    private struct Installed {
        let found: Bool
        let version: String?
        let pinnedSHA: String?
    }

    private func installedPlugin(_ workspace: DirectHermesWorkspaceStore) async throws -> Installed {
        let rows = try HostInstalledPlugin.decodeList(await workspace.managePlugins(["action": .string("list")]))
        guard let row = rows.first else { return Installed(found: false, version: nil, pinnedSHA: nil) }
        return Installed(found: true, version: row.version, pinnedSHA: row.pinnedSHA)
    }

    /// Waits for the restarted process to accept connections again (up to ~90 s).
    private func waitForHost(previousRuntime: String?) async {
        guard let registry, let host = registry.hosts.first(where: { $0.id == hostID }) else { return }
        let workspace = registry.workspace(for: host)
        for _ in 0..<45 {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if !workspace.isConnected { await workspace.reconnect() }
            guard let connection = currentConnection(),
                  let context = try? await connection.plugin.loadContext(force: true) else { continue }
            if context.runtimeID != previousRuntime { return }
        }
    }

    static func restartOnComputerMessage(installed: String?, running: String?) -> String {
        "Version \(installed ?? "the update") is installed, but the Hermes service bighelp connects to is still running "
            + "\(running ?? "an older version"), which can't restart itself. Restart Hermes on your computer once "
            + "(quit and reopen it, or restart its service), then tap Check again. Future updates restart from here."
    }

    private func fail(_ text: String) {
        state = .failed
        message = text
    }
}

/// A computer's bighelp plugin version, with Update and Restart when it's
/// behind this app.
struct HostPluginUpdateSection: View {
    let model: HostPluginUpdateModel
    @State private var confirmsRestart = false

    var body: some View {
        Section {
            LabeledContent("Installed", value: model.installedVersion ?? "—")
                .accessibilityIdentifier("settings.plugin.installed")
            if let running = model.runningVersion, running != model.installedVersion {
                LabeledContent("Running", value: running)
                    .accessibilityIdentifier("settings.plugin.running")
            }
            LabeledContent("Latest", value: model.latestVersion ?? "—")
                .accessibilityIdentifier("settings.plugin.latest")
            if let message = model.message ?? (model.state == .checking ? "Checking the plugin…" : nil) {
                Label {
                    Text(message)
                } icon: {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.state == .upToDate ? "checkmark.circle" : "puzzlepiece.extension")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.plugin.status")
            }
            switch model.state {
            case .checking, .updating, .restarting:
                EmptyView()
            case .updateAvailable:
                Button("Update to \(model.latestVersion ?? "latest")") {
                    Task { if await model.update() { confirmsRestart = true } }
                }
                .accessibilityIdentifier("settings.plugin.update")
            case .restartNeeded where model.canRestartHost:
                Button("Restart Hermes") { confirmsRestart = true }
                    .accessibilityIdentifier("settings.plugin.restart")
            case .restartNeeded, .idle, .notInstalled, .upToDate, .failed:
                Button("Check again") { Task { await model.check() } }
                    .accessibilityIdentifier("settings.plugin.check")
            }
        } header: {
            Text("Plugin version")
        } footer: {
            Text("Updates install the plugin version this app was tested with.")
        }
        .alert(model.canRestartHost ? "Restart Hermes to finish updating?" : "Restart the messaging gateway?",
               isPresented: $confirmsRestart) {
            Button(model.canRestartHost ? "Restart Hermes" : "Restart Gateway") { Task { await model.restart() } }
                .accessibilityIdentifier("settings.plugin.restart.confirm")
            Button("Later", role: .cancel) {}
        } message: {
            Text(model.canRestartHost
                 ? "This restarts the messaging gateway and the Hermes service bighelp connects to, so the new plugin loads. Replies in progress on this computer will stop."
                 : "This loads the new plugin in the messaging gateway. The Hermes service bighelp connects to runs an older plugin that can't restart itself, so restart Hermes on your computer once afterwards.")
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// `-test-plugin-update`: the plugin version section in each state, for screenshots.
enum HostPluginUpdateFixture {
    static let launchArgument = "-test-plugin-update"

    @MainActor
    static func rootView() -> some View {
        NavigationStack {
            Form {
                HostPluginUpdateSection(model: model(.updateAvailable, installed: "2.15.0", running: "2.15.0",
                                                     message: "Version 2.17.0 is available."))
                HostPluginUpdateSection(model: model(.restartNeeded, installed: "2.17.0", running: "2.15.0",
                                                     message: HostPluginUpdateModel.restartOnComputerMessage(
                                                        installed: "2.17.0", running: "2.15.0")))
                HostPluginUpdateSection(model: model(.restartNeeded, installed: "2.17.1", running: "2.17.0",
                                                     message: "Installed 2.17.1. Restart Hermes to start using it.",
                                                     canRestartHost: true))
                HostPluginUpdateSection(model: model(.restarting, installed: "2.17.1", running: "2.17.0",
                                                     message: "Restarting Hermes…"))
                HostPluginUpdateSection(model: model(.upToDate, installed: "2.17.0", running: "2.17.0",
                                                     message: "bighelp plugin 2.17.0 is installed and running."))
            }
            .navigationTitle("Plugin updates")
        }
    }

    @MainActor
    private static func model(_ state: HostPluginUpdateModel.State, installed: String, running: String,
                              message: String, canRestartHost: Bool = false) -> HostPluginUpdateModel {
        let model = HostPluginUpdateModel(registry: nil, hostID: UUID(), pin: nil, latestVersion: "2.17.0")
        model.freeze(state, installed: installed, running: running, message: message, canRestartHost: canRestartHost)
        return model
    }
}

extension HostPluginUpdateModel {
    fileprivate func freeze(_ state: State, installed: String, running: String, message: String, canRestartHost: Bool) {
        self.state = state
        self.canRestartHost = canRestartHost
        installedVersion = installed
        runningVersion = running
        self.message = message
    }
}
#endif
