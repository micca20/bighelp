import SwiftUI

enum HostPluginFeature: String, Hashable, Sendable {
    case liveVoice, deviceAccess

    var capability: String { self == .liveVoice ? "native-voice-v1" : "native-device-tools-v1" }
    var title: String { self == .liveVoice ? "Codex Live Voice" : "Device access" }
    var detail: String {
        self == .liveVoice
            ? "Codex Live Voice requires the bighelp plugin on your Hermes host, plus a Codex subscription signed in on that host."
            : "Calendar, Reminders, and Health access require the bighelp plugin on your Hermes host. You choose each permission separately on this iPhone."
    }
    var installIdentifier: String {
        self == .liveVoice ? CodexLiveVoiceSettingsPresentation.installAccessibilityIdentifier
            : "settings.install-loopdy-plugin-for-device-access"
    }
}

/// This section installs through the selected host's ordinary plugin manager.
/// Capability discovery and installation never enroll a notification recipient.
@MainActor
struct HostPluginFeatureSection: View {
    let feature: HostPluginFeature
    @Environment(\.bighelpHostRegistry) private var registry
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup: HostNotificationSetupModel?
    @State private var status = "Checking the selected host…"
    @State private var action: String?
    @State private var checking = false
    @State private var ready = false
    @State private var offerGatewayRestart = false
    @State private var restartingGateway = false
    @State private var confirmsGatewayRestart = false
    @State private var requestID = UUID()

    private var identity: String {
        "\(registry?.selectedHostID?.uuidString ?? "none"):\(registry?.generation.uuidString ?? "none"):\(registry?.selectedWorkspace?.connectionGeneration.uuidString ?? "none")"
    }

    var body: some View {
        Section {
            Text(feature.detail).fixedSize(horizontal: false, vertical: true)
            Label(status, systemImage: ready ? "checkmark.circle" : "puzzlepiece.extension")
                .bighelpFont(.metadata).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.plugin-status.\(feature.rawValue)")
            if checking || setup?.isWorking == true {
                ProgressView(setup?.isWorking == true ? "Setting up the plugin…" : "Checking plugin…")
            } else if let action, let setup {
                Button(action) {
                    Task {
                        await setup.enable()
                        guard !Task.isCancelled else { return }
                        if setup.state == .installed {
                            offerGatewayRestart = true
                            status = "Plugin files and configured enablement are verified. Restart the messaging gateway to try loading agent tools, or restart the hermes serve process on the host itself to load native APIs. bighelp cannot restart hermes serve for you."
                        } else { status = setup.message }
                    }
                }
                .accessibilityIdentifier(feature.installIdentifier)
            } else if !ready, registry?.selectedHost != nil {
                Button("Check again") { Task { await check() } }
                    .accessibilityIdentifier("settings.plugin-check.\(feature.rawValue)")
            }
            if offerGatewayRestart && !ready {
                Button(restartingGateway ? "Restarting Messaging Gateway…" : "Restart Messaging Gateway") {
                    confirmsGatewayRestart = true
                }
                .disabled(restartingGateway)
                .accessibilityIdentifier("settings.plugin-restart-gateway.\(feature.rawValue)")
            }
        } header: {
            Text(feature.title)
        } footer: {
            Text(feature == .deviceAccess
                 ? "Installation leaves iOS permissions off. Keep bighelp open while your agent uses this iPhone."
                 : "Voice connects directly to Hermes. Notifications are optional and set up separately.")
        }
        .task(id: identity) { await check() }
        .onDisappear { requestID = UUID(); setup?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            requestID = UUID()
            setup?.cancel()
        }
        .confirmationDialog(
            "Restart the messaging gateway?",
            isPresented: $confirmsGatewayRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Messaging Gateway") { Task { await restartMessagingGateway() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts only the selected profile's messaging gateway. It does not restart the hermes serve process carrying this connection and native plugin APIs. To restart that process, restart hermes serve on the host itself, then return here and check again.")
        }
    }

    private func check() async {
        let request = UUID()
        requestID = request
        checking = true; ready = false; action = nil
        defer { if requestID == request { checking = false } }
        guard let registry, let host = registry.selectedHost,
              let workspace = registry.selectedWorkspace, workspace.isConnected,
              let direct = workspace.nativeClient,
              let authority = workspace.savedConnection?.workspaceAuthority else {
            status = "Connect to a Hermes host to set up this feature."
            return
        }
        let generation = registry.generation
        let connection = workspace.connectionGeneration
        func owns() -> Bool {
            requestID == request && registry.generation == generation
                && registry.selectedHostID == host.id && workspace.connectionGeneration == connection
                && workspace.isConnected && !Task.isCancelled
        }
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: connection)
        let client = DirectHermesNativePluginClient(http: direct, owner: owner,
                                                    currentOwner: { owns() ? owner : nil })
        setup?.cancel()
        setup = HostNotificationSetupModel(host: host, registry: registry, enrollNotifications: false)
        // Tracks whether the plugin's native API (hermes serve dashboard
        // process) answered at all. A 200 without the capability means the
        // middleware did not advertise it; a thrown route means the plugin is
        // not loaded there. Both are distinct from "not installed".
        var nativeResponded = false
        do {
            let context = try await client.loadContext(force: true)
            guard owns() else { return }
            nativeResponded = true
            if context.features.contains(feature.capability) {
                guard registry.recordPluginFeatureReadiness(
                    feature: feature,
                    hostID: host.id,
                    registryGeneration: generation,
                    connectionGeneration: connection,
                    contextETag: context.etag,
                    capabilities: context.features,
                    isCurrent: owns
                ) else { return }
                ready = true
                status = "bighelp plugin connected."
                return
            }
        } catch {
            guard owns() else { return }
            // A missing route can mean absent, disabled, or not yet loaded.
            // Read the official manager before offering any installation.
        }
        do {
            let matches = try HostInstalledPlugin.decodeList(
                await workspace.managePlugins(["action": .string("list")])
            ).filter { $0.name == "loopdy" }
            guard owns() else { return }
            if matches.isEmpty {
                status = "The bighelp plugin is not installed on this host."
                action = "Install bighelp Plugin"
            } else if matches.count == 1, let installed = matches.first {
                if let pin = setup?.pin, installed.pinnedSHA != pin.revision {
                    status = "A different bighelp plugin revision is installed. Review the exact pinned update before replacing it."
                    action = "Install Reviewed Update"
                } else if installed.configuredEnabled {
                    status = nativeResponded
                        ? "The plugin is installed and its native API answered, but it did not advertise this feature. Check the hermes serve log on the host for why the native middleware was skipped, restart the hermes serve process on the host itself, then check again."
                        : "The plugin is installed, but bighelp could not reach its native API on this host. Restarting the messaging gateway only loads agent tools; restart the hermes serve process on the host itself, then reconnect and check again."
                } else {
                    status = "The bighelp plugin is installed but disabled."
                    action = "Enable bighelp Plugin"
                }
            } else {
                status = "Hermes reported more than one bighelp plugin. Review the installed plugins on your host."
            }
        } catch {
            guard owns() else { return }
            status = "Plugin status could not be verified. Check your host connection and try again."
        }
    }

    /// Deliberately gateway-only: this connection is carried by the very
    /// `hermes serve` process a dual restart would have to kill, so the app
    /// cannot restart it and poll the result. The confirmation copy states
    /// exactly what restarts and gives the host-side manual step.
    private func restartMessagingGateway() async {
        guard !restartingGateway, let registry, let host = registry.selectedHost,
              let workspace = registry.selectedWorkspace, workspace.isConnected,
              let direct = workspace.nativeClient,
              let authority = workspace.savedConnection?.workspaceAuthority else { return }
        let generation = registry.generation
        let connection = workspace.connectionGeneration
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: generation,
            connectionGeneration: connection
        )
        func owns() -> Bool {
            registry.generation == generation && registry.selectedHostID == host.id
                && workspace.connectionGeneration == connection && !Task.isCancelled
        }
        restartingGateway = true
        defer { restartingGateway = false }
        do {
            let operations = DirectHermesHostOperationsClient(
                rpc: direct, http: direct, owner: owner,
                currentOwner: { owns() ? owner : nil }
            )
            let receipt = try await operations.launchMessagingGateway(
                .restart, profileID: workspace.selectedProfile
            )
            let result = try await operations.poll(
                receipt, attempts: 30, intervalNanoseconds: 1_000_000_000
            )
            guard owns() else { return }
            guard result.phase == .succeeded else {
                status = "The messaging-gateway restart could not be confirmed. bighelp cannot restart the hermes serve process from this connection; restart it on the host itself, then reconnect and check again."
                return
            }
            await workspace.reconnect()
            guard owns(), workspace.isConnected else {
                status = "The gateway restarted, but bighelp could not reconnect. Restart the hermes serve process on the host itself if the plugin still does not activate."
                return
            }
            offerGatewayRestart = false
            await check()
            if !ready {
                status = "The messaging gateway restarted, but the plugin feature is still unavailable. bighelp cannot restart the hermes serve process from here; restart it on the host itself, then reconnect and check again."
            }
        } catch {
            guard owns() else { return }
            status = "The messaging-gateway restart failed or could not be verified. Restart the hermes serve process on the host itself, then reconnect and check again."
        }
    }
}

/// Explicit host-detail installation. It reuses the stock plugin coordinator
/// and never registers a device or creates a notification grant.
@MainActor
struct HostPluginInstallationSection: View {
    let model: HostNotificationSetupModel
    let hostName: String
    let hostEndpoint: String
    @State private var showsReview = false
    @State private var restartOffered = false
    @State private var confirmsRestart = false
    @State private var restarting = false
    @State private var restartStatus: String?
    @Environment(\.bighelpHostRegistry) private var registry

    var body: some View {
        Section {
            LabeledContent("Computer", value: hostName)
                .accessibilityIdentifier("hosts.plugin-install.host")
            VStack(alignment: .leading, spacing: 4) {
                Text("Address").bighelpFont(.metadata).foregroundStyle(.secondary)
                Text(hostEndpoint).bighelpFont(.code).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hosts.plugin-install.host-address")
            Text(model.message)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hosts.plugin-install.status")

            if model.isWorking {
                ProgressView(model.state == .installing ? "Installing the plugin…" : "Checking the plugin…")
                    .accessibilityIdentifier("hosts.plugin-install.progress")
            } else if model.state == .installed || model.state == .enabled {
                Label("Installed and enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("hosts.plugin-install.complete")
            } else if showsReview {
                Text("This action checks the selected host's current plugin scope. It installs the reviewed bighelp plugin when missing, enables the same installed revision when disabled, or replaces a different revision with the exact reviewed pin. A replacement can overwrite local plugin modifications.")
                    .fixedSize(horizontal: false, vertical: true)
                if let pin = model.pin {
                    LabeledContent("Plugin", value: pin.identifier)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reviewed revision").bighelpFont(.metadata).foregroundStyle(.secondary)
                        Text(pin.revision).bighelpFont(.code).textSelection(.enabled)
                    }
                    Text("The host's normal kill list and security scanner stay enabled. First install uses force false. An explicitly reviewed pinned replacement uses the stock manager's force replacement because custom-ref plugins have no update verb. Every result is read back before activation is offered.")
                    Text("Installation does not enroll notifications or prove activation. bighelp can explicitly restart only the messaging gateway; the hermes serve process must be restarted on the host itself by the host operator when native plugin APIs do not activate.")
                }
                if let actionTitle = model.actionTitle {
                    Button(actionTitle) {
                        Task {
                            await model.enable()
                            if model.state == .installed || model.state == .enabled {
                                restartOffered = true
                                restartStatus = "Plugin files are installed and enabled. Runtime activation is not yet verified."
                            }
                        }
                    }
                        .accessibilityIdentifier("hosts.install-loopdy-plugin.confirm")
                }
                Button("Not Now", role: .cancel) { showsReview = false }
                    .accessibilityIdentifier("hosts.install-loopdy-plugin.not-now")
            } else {
                Button(pluginReviewTitle) { showsReview = true }
                    .accessibilityIdentifier("hosts.install-loopdy-plugin")
            }
            if restartOffered {
                Button(restarting ? "Restarting Messaging Gateway…" : "Restart Messaging Gateway") {
                    confirmsRestart = true
                }
                .disabled(restarting)
                .accessibilityIdentifier("hosts.plugin-install.restart-gateway")
            }
            if let restartStatus {
                Text(restartStatus).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hosts.plugin-install.restart-status")
            }
        } header: {
            Text("bighelp Plugin")
        } footer: {
            Text("Plugin installation is separate from notification enrollment. Basic chat and Artifacts remain available without it.")
        }
        .confirmationDialog(
            "Restart the messaging gateway?",
            isPresented: $confirmsRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Messaging Gateway") { Task { await restartAndVerify() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts only the selected profile's messaging gateway. It does not restart hermes serve, which carries this native connection and plugin API. To restart that process, restart hermes serve on the host itself, then return here and check again.")
        }
    }

    private var pluginReviewTitle: String {
        switch model.state {
        case .notConfigured: "Install bighelp Plugin"
        case .outcomeUnknown: "Review and Check Installed State"
        default: "Review Plugin Setup"
        }
    }

    /// Gateway-only by design (see restartMessagingGateway): the host operator
    /// restarts `hermes serve` on the host itself when native APIs stay dark.
    private func restartAndVerify() async {
        guard !restarting, let registry,
              let host = registry.hosts.first(where: { $0.id == model.hostID }) else { return }
        let workspace = registry.workspace(for: host)
        if !workspace.isConnected { await workspace.reconnect() }
        guard workspace.isConnected, let direct = workspace.nativeClient,
              let authority = workspace.savedConnection?.workspaceAuthority else {
            restartStatus = "bighelp could not reconnect to request a gateway restart. Restart the hermes serve process on the host itself, then check again."
            return
        }
        let generation = registry.generation
        let connection = workspace.connectionGeneration
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: connection)
        func owns() -> Bool {
            registry.generation == generation && registry.hosts.contains(where: { $0.id == host.id })
                && workspace.connectionGeneration == connection && !Task.isCancelled
        }
        restarting = true
        defer { restarting = false }
        do {
            let operations = DirectHermesHostOperationsClient(
                rpc: direct, http: direct, owner: owner,
                currentOwner: { owns() ? owner : nil }
            )
            let receipt = try await operations.launchMessagingGateway(
                .restart, profileID: workspace.selectedProfile
            )
            let result = try await operations.poll(receipt, attempts: 30,
                                                   intervalNanoseconds: 1_000_000_000)
            guard owns(), result.phase == .succeeded else {
                restartStatus = "The gateway restart could not be verified. Restart the hermes serve process on the host itself, then check again."
                return
            }
            await workspace.reconnect()
            guard owns(), workspace.isConnected, let refreshed = workspace.nativeClient else {
                restartStatus = "The gateway restarted, but bighelp could not reconnect. Restart the hermes serve process on the host itself if the plugin remains unavailable."
                return
            }
            let verifier = DirectHermesNativePluginClient(
                http: refreshed, owner: owner, currentOwner: { owns() ? owner : nil }
            )
            _ = try await verifier.loadContext(force: true)
            guard owns() else { return }
            restartOffered = false
            restartStatus = "Messaging gateway restarted and the bighelp plugin context was verified after reconnect."
        } catch {
            guard owns() else { return }
            restartStatus = "The messaging gateway failed or did not activate the native plugin context. Restart the hermes serve process on the host itself, then reconnect and check again."
        }
    }
}
