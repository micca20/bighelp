import SwiftUI

@MainActor
struct BighelpLinkDeviceDetailView: View {
    let store: BighelpLinkDeviceStore
    let deviceID: String
    let onUnpaired: () -> Void

    @State private var renamePresentation: RenamePresentation?
    @State private var isUnpairConfirmationPresented = false

    var body: some View {
        Group {
            if let device = store.device(id: deviceID) {
                detail(for: device)
            } else {
                ContentUnavailableView(
                    "Device unavailable",
                    systemImage: "link.badge.minus",
                    description: Text("This device is no longer paired with your bighelp account.")
                )
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renamePresentation) { presentation in
            NavigationStack {
                BighelpLinkRenameDeviceView(
                    store: store,
                    deviceID: presentation.id,
                    initialName: presentation.name
                )
            }
        }
        .confirmationDialog(
            unpairTitle,
            isPresented: $isUnpairConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(isHermesHost ? "Unpair this host" : "Unpair Device", role: .destructive) {
                Task { await unpair() }
            }
        } message: {
            Text(unpairMessage)
        }
        .accessibilityIdentifier("link.device-detail")
    }

    private func detail(for device: BighelpLinkDevice) -> some View {
        let presentation = BighelpLinkDevicePresentation(device: device)
        return Form {
            Section {
                HStack(alignment: .top, spacing: BighelpTokens.space16) {
                    Image(systemName: presentation.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(width: 58, height: 58)
                        .background(theme.action.opacity(0.1), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(device.name)
                            .bighelpFont(.screenTitle)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.kindTitle)
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                        StatusBadge(
                            title: presentation.connectionTitle,
                            status: device.connection == .online ? .success : .information
                        )
                    }
                }
                .padding(.vertical, BighelpTokens.space8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
            }

            Section("Connection") {
                detailRow("Status", presentation.connectionTitle)
                if let lastSeen = presentation.lastSeenLabel {
                    detailRow("Activity", lastSeen)
                }
                detailRow("Authorization", "Paired with this bighelp account")
            }

            if device.kind == .hermesHost {
                hostAuthoritySection(for: device)
            }


            Section {
                Button {
                    renamePresentation = RenamePresentation(id: device.id, name: device.name)
                } label: {
                    Label("Rename Device", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .disabled(store.pendingAction != nil)
                .accessibilityIdentifier("link.rename-device")

                Button(role: .destructive) {
                    isUnpairConfirmationPresented = true
                } label: {
                    Label(
                        device.kind == .hermesHost ? "Unpair this host" : "Unpair Device",
                        systemImage: "link.badge.minus"
                    )
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .disabled(store.pendingAction != nil)
                .accessibilityIdentifier("link.unpair-device")

                if let actionError = store.actionError {
                    Text(actionError)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("link.device-action-error")
                }
            } header: {
                Text("Manage")
            } footer: {
                Text(managementFooter(for: device))
                    .bighelpFont(.metadata)
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
    }

    private func hostAuthoritySection(for device: BighelpLinkDevice) -> some View {
        let authority = BighelpLinkHostAuthorityPresentation(
            hostID: device.id,
            selectedHostID: store.selectedHostID,
            primaryHostID: store.primaryHostID
        )
        return Section("Host") {
            ForEach(authority.statusLabels, id: \.self) { status in
                Label(
                    status,
                    systemImage: status == "Primary" ? "star.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(theme.action)
                .accessibilityIdentifier(
                    status == "Primary" ? "link.host.primary" : "link.host.selected"
                )
            }
            if authority.canSelect {
                Button("Select Instance") {
                    store.selectHost(device.id)
                }
                .disabled(store.pendingAction != nil)
                .accessibilityIdentifier("link.host.select")
            }
            if authority.canSetPrimary {
                Button("Set as Primary") {
                    store.setPrimaryHost(device.id)
                }
                .disabled(store.pendingAction != nil)
                .accessibilityIdentifier("link.host.set-primary")
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space12) {
            Text(title)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: BighelpTokens.space8)
            Text(value)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .bighelpFont(.body)
    }


    private func managementFooter(for device: BighelpLinkDevice) -> String {
        if device.isCurrentDevice {
            return "Unpairing this device signs this app installation out after bighelp Link confirms the change."
        }
        if device.kind == .hermesHost {
            return "Unpairing removes this account’s authorization. It does not uninstall or stop Hermes."
        }
        return "Unpairing closes this device’s bighelp Link connection and removes its account authorization."
    }

    private var isHermesHost: Bool {
        store.device(id: deviceID)?.kind == .hermesHost
    }

    private var unpairTitle: String {
        guard let name = store.device(id: deviceID)?.name else { return "Unpair device?" }
        return "Unpair \(name)?"
    }

    private var unpairMessage: String {
        guard let device = store.device(id: deviceID) else {
            return "This device is no longer paired."
        }
        return managementFooter(for: device)
    }

    private func unpair() async {
        await store.unpairDevice(id: deviceID)
        if store.device(id: deviceID) == nil {
            onUnpaired()
        }
    }

    @BighelpThemeReader private var theme
}

private struct RenamePresentation: Identifiable {
    let id: String
    let name: String
}
