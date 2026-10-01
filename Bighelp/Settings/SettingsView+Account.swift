import SwiftUI

extension SettingsView {
    var accountAndDevicesPage: some View {
        settingsPage(title: SettingsMenuSection.accountAndDevices.title) {
            if let hostRegistry, hostRegistry.isAccountReady { BighelpConfiguredHostsSection(registry: hostRegistry) }
            accountDeviceSections
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isAccountControlsPresented = true
                    } label: {
                        Label("Account controls", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settings.account.controls")
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.bighelp(.title3).weight(.semibold))
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Account controls")
                .accessibilityIdentifier("settings.account.menu")
            }
        }
        .sheet(isPresented: $isAccountControlsPresented) {
            NavigationStack {
                accountControlsPage
            }
            .bighelpSheetSize(.standard)
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var accountDeviceSections: some View {
        let sections = BighelpLinkDeviceSections(devices: linkDevices.devices)
        settingsDeviceSection(
            title: "Hosts",
            devices: sections.hosts,
            emptyMessage: "No hosts are paired yet."
        )
        settingsDeviceSection(
            title: "Connected Devices",
            devices: sections.connectedDevices,
            emptyMessage: "No connected devices are available."
        )
    }

    private func settingsDeviceSection(
        title: String,
        devices: [BighelpLinkDevice],
        emptyMessage: String
    ) -> some View {
        Section(title) {
            if devices.isEmpty {
                Text(emptyMessage)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(devices) { device in
                    settingsDeviceRow(device)
                }
            }
        }
        .listRowBackground(theme.surface)
    }

    private func settingsDeviceRow(_ device: BighelpLinkDevice) -> some View {
        let presentation = BighelpLinkDevicePresentation(device: device)
        let authority = device.kind == .hermesHost
            ? BighelpLinkHostAuthorityPresentation(
                hostID: device.id,
                selectedHostID: linkDevices.selectedHostID,
                primaryHostID: linkDevices.primaryHostID
            )
            : nil
        return Button {
            onOpenBighelpLinkDevice(device.id)
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: presentation.systemImage)
                    .font(.bighelp(.title3).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .background(theme.action.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(device.name)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    Text(presentation.subtitle)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let authority {
                        ForEach(authority.statusLabels, id: \.self) { status in
                            Text(status)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.action)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([presentation.accessibilityLabel] + (authority?.statusLabels ?? []))
                .joined(separator: ", ")
        )
        .accessibilityHint("Opens device details")
        .accessibilityIdentifier("settings.account.device.\(device.id)")
    }

    private var accountControlsPage: some View {
        settingsPage(title: "Account") {
            localIdentity
            if linkAccount?.state == .ready { bighelpLink }
            localCache
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    isAccountControlsPresented = false
                }
                #if targetEnvironment(macCatalyst)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityIdentifier("settings.account.controls.done")
                    .bighelpToolbarText()
            }
        }
    }

    var localCache: some View {
        Section {
            Button {
                isClearCacheConfirmationPresented = true
            } label: {
                Label(
                    isClearingLocalCache ? "Refreshing Local Data…" : "Clear Local Cache",
                    systemImage: "arrow.clockwise.circle"
                )
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(
                isClearingLocalCache || (hostRegistry?.selectedHostID == nil && (linkAccount.map { $0.state != .ready } ?? false))
            )
            .accessibilityIdentifier("settings.account.clear-local-cache")

            if let localCacheStatusMessage {
                Text(localCacheStatusMessage)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.account.clear-local-cache-status")
            }
        } header: {
            Text("Local Data")
        } footer: {
            Text("Clears cached data for the selected Hermes host and immediately downloads a fresh copy. Your account and preferences are preserved.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    func clearLocalCache() {
        guard !isClearingLocalCache else { return }
        isClearingLocalCache = true
        localCacheStatusMessage = nil
        Task { @MainActor in
            let succeeded = await onClearLocalCache()
            localCacheStatusMessage = succeeded
                ? "Local cache cleared. Fresh account data is ready."
                : "The local cache could not be refreshed. Try again."
            isClearingLocalCache = false
        }
    }

    private var bighelpLink: some View {
        let summary = BighelpLinkDeviceSummary(devices: linkDevices.devices)
        let isSignedIn = linkAccount?.state == .ready || linkAccount == nil
        let statusTitle: String = if !isSignedIn {
            "Not signed in"
        } else {
            switch linkDevices.loadState {
            case .idle, .loading: "Connecting"
            case .failed: "Needs attention"
            case .loaded: summary.title
            }
        }

        return Section {
            Button(action: onOpenBighelpLinkAccount) {
                    Label(
                        isSignedIn ? "Manage bighelp Account" : "Set Up bighelp Link",
                        systemImage: isSignedIn ? "person.crop.circle.badge.checkmark" : "person.badge.key"
                    )
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .accessibilityIdentifier("profile.loopdy-link.account")
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: statusTitle == "Connected" ? "link.circle.fill" : "link")
                    .foregroundStyle(statusTitle == "Connected" ? theme.success : theme.warning)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(statusTitle)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(statusTitle == "Connecting"
                         ? "Checking your paired devices…"
                         : statusTitle == "Not signed in"
                            ? "Set up a minimal passkey account to connect devices."
                            : summary.detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.loopdy-link")

            Button(action: onOpenBighelpLinkDevices) {
                HStack(spacing: BighelpTokens.space12) {
                    Label("Paired Devices", systemImage: "laptopcomputer.and.iphone")
                    Spacer(minLength: BighelpTokens.space8)
                    Text(summary.deviceCountText)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(!isSignedIn)
            .accessibilityLabel("Open paired devices, \(summary.deviceCountText)")
            .accessibilityIdentifier("profile.loopdy-link.devices")

            Button(action: onPairBighelpLinkDevice) {
                Label("Pair a Device", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(!isSignedIn)
            .accessibilityIdentifier("profile.loopdy-link.pair")
        } header: {
            Text("bighelp Link")
        } footer: {
            Text("bighelp Link securely connects this account’s devices with your authorized Hermes hosts.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    var connectivity: some View {
        let presentation = SettingsConnectivityPresentation(
            linkAccountState: linkAccount?.state ?? .ready
        )
        return Section {
            if let linkConnectionState {
                let connection = SettingsLinkConnectionPresentation(state: linkConnectionState)
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    Image(systemName: connection.systemImage)
                        .reflectiveVisionIcon()
                        .foregroundStyle(connection.title == "Connected"
                            ? theme.success
                            : connection.isTransient ? theme.warning : theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(connection.title)
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                        Text(connection.detail)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.link-connection")
            }

            Toggle(isOn: $settings.offlineModeEnabled) {
                settingLabel(
                    "Offline mode",
                    detail: "Keep downloaded sessions readable while pausing network actions."
                )
            }
        } header: {
            Text("Connectivity")
        } footer: {
            Text(presentation.footer)
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }
}
