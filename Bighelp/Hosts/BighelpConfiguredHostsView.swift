import SwiftUI

@MainActor
struct BighelpConfiguredHostsSection: View {
    let registry: BighelpHostRegistry
    var body: some View {
        Section("Computers") {
            ForEach(registry.hosts) { host in
                NavigationLink {
                    BighelpConfiguredHostView(hostID: host.id, registry: registry)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.name)
                            Text(host.id == registry.selectedHostID ? "Selected · native Hermes" : "Native Hermes")
                                .bighelpFont(.metadata).foregroundStyle(.secondary)
                            if let attention = HostPluginUpdateModel.existingModel(for: host.id)?.attentionTitle {
                                Text(attention)
                                    .bighelpFont(.metadata).foregroundStyle(.tint)
                                    .accessibilityIdentifier("hosts.host.plugin-update")
                            }
                        }
                    } icon: { Image(systemName: host.id == registry.selectedHostID ? "checkmark.circle" : "server.rack") }
                }.accessibilityIdentifier("hosts.host.\(host.id.uuidString)")
            }
            Button("Add Host", systemImage: "plus") { registry.beginSetup() }
                .disabled(!registry.canConfigureHosts)
                .accessibilityIdentifier("hosts.add-host")
            if let error = registry.errorMessage { Text(error).bighelpFont(.metadata).foregroundStyle(.secondary) }

        }
    }
}

@MainActor
struct BighelpConfiguredHostView: View {
    let hostID: UUID
    let registry: BighelpHostRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationModel: HostNotificationSetupModel?
    @State private var pluginModel: HostNotificationSetupModel?
    @State private var updateModel: HostPluginUpdateModel?
    @State private var showsRemove = false
    @State private var isAccessEditorPresented = false
    /// Bumped after editing access so the summary rereads Keychain.
    @State private var accessRevision = 0
    @State private var error: String?
    private var host: BighelpConfiguredHost? { registry.hosts.first { $0.id == hostID } }

    /// What bighelp sends to get past a proxy or Cloudflare Access (names only, never values).
    @ViewBuilder
    private func accessSummary(_ endpoint: DirectHermesEndpoint) -> some View {
        let store = DirectHermesAccessCredentialStore.shared
        let access = store.savedCredentials(for: endpoint)
        let headers = store.savedCustomHeaders(for: endpoint)
        if access != nil || !headers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let access {
                    Text(access.kind == .basic ? "Proxy username and password saved"
                                               : "Cloudflare Access service token saved")
                }
                if !headers.isEmpty {
                    Text("Custom headers: " + headers.map(\.name).joined(separator: ", "))
                }
            }
            .bighelpFont(.metadata).foregroundStyle(.secondary)
            .accessibilityIdentifier("hosts.cloudflare-access")
        }
    }

    var body: some View {
        Form {
            if let host {
                Section {
                    LabeledContent("Computer", value: host.name)
                    DisclosureGroup("Advanced connection details") {
                        Text(host.endpoint.identity).bighelpFont(.code).textSelection(.enabled)
                        accessSummary(host.endpoint)
                            .id(accessRevision)
                        Button("Edit access", systemImage: "lock.shield") { isAccessEditorPresented = true }
                            .accessibilityIdentifier("hosts.edit-access")
                        Text(host.isIndependent
                             ? "Credentials are saved on this device for this Hermes principal."
                             : "These legacy credentials remain private to this account until explicitly migrated.")
                            .bighelpFont(.metadata).foregroundStyle(.secondary)
                    }
                    Button(host.id == registry.selectedHostID ? "Selected host" : "Use this host") {
                        registry.select(host.id)
                        dismiss()
                    }.disabled(host.id == registry.selectedHostID)
                    .accessibilityIdentifier("hosts.select")
                    Button("Sign in and use this host") { registry.beginAuthentication(for: host) }
                        .accessibilityIdentifier("hosts.sign-in")
                } header: {
                    Text("Connection")
                }
                if let pluginModel {
                    HostPluginInstallationSection(
                        model: pluginModel,
                        hostName: host.name,
                        hostEndpoint: host.endpoint.identity
                    )
                }
                if let updateModel, updateModel.state != .notInstalled {
                    HostPluginUpdateSection(model: updateModel)
                }
                if let notificationModel {
                    HostNotificationSetupSection(
                        model: notificationModel,
                        hostName: host.name,
                        hostEndpoint: host.endpoint.identity
                    )
                }
                Section {
                    Button("Remove Host", role: .destructive) { showsRemove = true }
                        .accessibilityIdentifier("hosts.remove")
                } header: { Text("Remove from this device") } footer: {
                    Text("Removes this device's credentials, local drafts and setup metadata. Hermes sessions and host files are not deleted. This does not claim server-side token revocation.")
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            } else {
                Text("This host is no longer configured.")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(host?.name ?? "Computer")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAccessEditorPresented) {
            if let host {
                HostAccessEditorView(endpoint: host.endpoint) {
                    accessRevision += 1
                    guard host.id == registry.selectedHostID, let workspace = registry.selectedWorkspace else { return }
                    // New connections pick up the saved access; reconnect the current one now.
                    Task { await workspace.suspend(); await workspace.reconnect() }
                }
            }
        }
        .alert("Remove this host from this device?", isPresented: $showsRemove) {
            Button("Remove Host", role: .destructive) {
                guard let host else { return }
                do { try registry.remove(host); dismiss() }
                catch { self.error = "The host could not be completely removed. Unlock the device and try again." }
            }
            Button("Cancel", role: .cancel) { }
        }
        .task(id: hostID) {
            if let host {
                pluginModel = HostNotificationSetupModel(
                    host: host,
                    registry: registry,
                    enrollNotifications: false
                )
                notificationModel = HostNotificationSetupModel(host: host, registry: registry)
                await pluginModel?.refreshInstalledState()
                let update = HostPluginUpdateModel.model(for: host.id, registry: registry)
                updateModel = update
                await update.checkIfNeeded()
            }
        }
        .onDisappear {
            pluginModel?.cancel()
            notificationModel?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            pluginModel?.cancel()
            notificationModel?.cancel()
        }
    }
}

@MainActor
struct BighelpNativeHostMenu: View {
    let registry: BighelpHostRegistry
    let hasLinkHost: Bool
    let openAccount: () -> Void
    var body: some View {
        HStack {
            Menu {
                ForEach(registry.hosts) { host in
                    Button(host.name, systemImage: host.id == registry.selectedHostID ? "checkmark" : "server.rack") { registry.select(host.id) }
                }
                Button("Add Host", systemImage: "plus") { registry.beginSetup() }

            } label: {
                Label(registry.selectedHost?.name ?? "Hosts", systemImage: "server.rack")
                    .bighelpFont(.label, weight: .semibold).lineLimit(1).frame(minHeight: 44)
            }
            .accessibilityIdentifier("hosts.switcher")
            Spacer()
        }.padding(.horizontal)
    }
}
