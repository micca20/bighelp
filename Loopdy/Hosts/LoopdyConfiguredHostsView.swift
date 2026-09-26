import SwiftUI

@MainActor
struct LoopdyConfiguredHostsSection: View {
    let registry: LoopdyHostRegistry
    var body: some View {
        Section("Computers") {
            ForEach(registry.hosts) { host in
                NavigationLink {
                    LoopdyConfiguredHostView(hostID: host.id, registry: registry)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.name)
                            Text(host.id == registry.selectedHostID ? "Selected · native Hermes" : "Native Hermes")
                                .loopdyFont(.metadata).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: host.id == registry.selectedHostID ? "checkmark.circle" : "server.rack") }
                }.accessibilityIdentifier("hosts.host.\(host.id.uuidString)")
            }
            Button("Add Host", systemImage: "plus") { registry.beginSetup() }
                .disabled(!registry.canConfigureHosts)
                .accessibilityIdentifier("hosts.add-host")
            if let error = registry.errorMessage { Text(error).loopdyFont(.metadata).foregroundStyle(.secondary) }

        }
    }
}

@MainActor
struct LoopdyConfiguredHostView: View {
    let hostID: UUID
    let registry: LoopdyHostRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationModel: HostNotificationSetupModel?
    @State private var pluginModel: HostNotificationSetupModel?
    @State private var showsRemove = false
    @State private var error: String?
    private var host: LoopdyConfiguredHost? { registry.hosts.first { $0.id == hostID } }

    var body: some View {
        Form {
            if let host {
                Section {
                    LabeledContent("Computer", value: host.name)
                    DisclosureGroup("Advanced connection details") {
                        Text(host.endpoint.identity).loopdyFont(.code).textSelection(.enabled)
                        Text(host.isIndependent
                             ? "Credentials are saved on this device for this Hermes principal, independently of a bighelp account."
                             : "These legacy credentials remain private to this account until explicitly migrated.")
                            .loopdyFont(.metadata).foregroundStyle(.secondary)
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
        .loopdyFormSurface()
        .navigationTitle(host?.name ?? "Computer")
        .navigationBarTitleDisplayMode(.inline)
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
struct LoopdyNativeHostMenu: View {
    let registry: LoopdyHostRegistry
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
                    .loopdyFont(.label, weight: .semibold).lineLimit(1).frame(minHeight: 44)
            }
            .accessibilityIdentifier("hosts.switcher")
            Spacer()
        }.padding(.horizontal)
    }
}
