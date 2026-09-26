import SwiftUI

extension SettingsView {
    var accountAndDevicesPage: some View {
        settingsPage(title: SettingsMenuSection.accountAndDevices.title) {
            if let hostRegistry, hostRegistry.isAccountReady { LoopdyConfiguredHostsSection(registry: hostRegistry) }
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
                        .font(.title3.weight(.semibold))
                        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
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
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var accountDeviceSections: some View {
        let sections = LoopdyLinkDeviceSections(devices: linkDevices.devices)
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
        devices: [LoopdyLinkDevice],
        emptyMessage: String
    ) -> some View {
        Section(title) {
            if devices.isEmpty {
                Text(emptyMessage)
                    .loopdyFont(.body)
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

    private func settingsDeviceRow(_ device: LoopdyLinkDevice) -> some View {
        let presentation = LoopdyLinkDevicePresentation(device: device)
        let authority = device.kind == .hermesHost
            ? LoopdyLinkHostAuthorityPresentation(
                hostID: device.id,
                selectedHostID: linkDevices.selectedHostID,
                primaryHostID: linkDevices.primaryHostID
            )
            : nil
        return Button {
            onOpenLoopdyLinkDevice(device.id)
        } label: {
            HStack(spacing: LoopdyTokens.space12) {
                Image(systemName: presentation.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .background(theme.action.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(device.name)
                        .loopdyFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    Text(presentation.subtitle)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let authority {
                        ForEach(authority.statusLabels, id: \.self) { status in
                            Text(status)
                                .loopdyFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.action)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
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
            if linkAccount?.state == .ready { loopdyLink }
            localCache
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    isAccountControlsPresented = false
                }
                .accessibilityIdentifier("settings.account.controls.done")
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
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
            }
            .disabled(
                isClearingLocalCache || (hostRegistry?.selectedHostID == nil && (linkAccount.map { $0.state != .ready } ?? false))
            )
            .accessibilityIdentifier("settings.account.clear-local-cache")

            if let localCacheStatusMessage {
                Text(localCacheStatusMessage)
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.account.clear-local-cache-status")
            }
        } header: {
            Text("Local Data")
        } footer: {
            Text("Clears cached data for the selected Hermes host and immediately downloads a fresh copy. Your account and preferences are preserved.")
                .loopdyFont(.metadata)
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

    private var loopdyLink: some View {
        let summary = LoopdyLinkDeviceSummary(devices: linkDevices.devices)
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
            Button(action: onOpenLoopdyLinkAccount) {
                    Label(
                        isSignedIn ? "Manage bighelp Account" : "Set Up Loopdy Link",
                        systemImage: isSignedIn ? "person.crop.circle.badge.checkmark" : "person.badge.key"
                    )
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
                }
                .accessibilityIdentifier("profile.loopdy-link.account")
            HStack(spacing: LoopdyTokens.space12) {
                Image(systemName: statusTitle == "Connected" ? "link.circle.fill" : "link")
                    .foregroundStyle(statusTitle == "Connected" ? theme.success : theme.warning)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(statusTitle)
                        .loopdyFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(statusTitle == "Connecting"
                         ? "Checking your paired devices…"
                         : statusTitle == "Not signed in"
                            ? "Set up a minimal passkey account to connect devices."
                            : summary.detail)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.loopdy-link")

            Button(action: onOpenLoopdyLinkDevices) {
                HStack(spacing: LoopdyTokens.space12) {
                    Label("Paired Devices", systemImage: "laptopcomputer.and.iphone")
                    Spacer(minLength: LoopdyTokens.space8)
                    Text(summary.deviceCountText)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
            }
            .disabled(!isSignedIn)
            .accessibilityLabel("Open paired devices, \(summary.deviceCountText)")
            .accessibilityIdentifier("profile.loopdy-link.devices")

            Button(action: onPairLoopdyLinkDevice) {
                Label("Pair a Device", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
            }
            .disabled(!isSignedIn)
            .accessibilityIdentifier("profile.loopdy-link.pair")
        } header: {
            Text("Loopdy Link")
        } footer: {
            Text("Loopdy Link securely connects this account’s devices with your authorized Hermes hosts.")
                .loopdyFont(.metadata)
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
                HStack(alignment: .top, spacing: LoopdyTokens.space12) {
                    Image(systemName: connection.systemImage)
                        .reflectiveVisionIcon()
                        .foregroundStyle(connection.title == "Connected"
                            ? theme.success
                            : connection.isTransient ? theme.warning : theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                        Text(connection.title)
                            .loopdyFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                        Text(connection.detail)
                            .loopdyFont(.metadata)
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
                .loopdyFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }
}
