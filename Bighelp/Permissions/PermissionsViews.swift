import SwiftUI

@MainActor
struct PermissionsSettingsView: View {
    let center: PermissionCenter

    var body: some View {
        Form {
            HostPluginFeatureSection(feature: .deviceAccess)
            if let status = center.nativeDeviceToolStatus {
                Section { Text(status).bighelpFont(.metadata).foregroundStyle(.secondary) }
            }

            Section {
                ForEach(DeviceToolCapability.allCases) { kind in
                    DeviceToolPermissionRow(permissions: center.deviceTools, kind: kind)
                }
            } header: {
                Text("Shared with your host")
            } footer: {
                Text(center.deviceTools.scope == nil
                     ? "Connect a host to enable these optional tools."
                     : "Requested data is shared with the selected host and its AI provider. Turn access off to stop agent use. Keep bighelp open while using these tools.")
            }
            .listRowBackground(theme.surface)

            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(center: center, kind: kind)
                }
            } header: {
                Text("On this device")
            } footer: {
                Text("bighelp asks iOS only after you choose Allow. Denied access must be changed in iOS Settings.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)

            Section {
                LabeledContent("Selected Photos", value: "Picker Only")
                    .accessibilityLabel("Selected Photos")
                    .accessibilityValue("Uses the iOS photo picker. bighelp does not receive full library access.")
            } header: {
                Text("Photos")
            } footer: {
                Text("Attaching a photo uses Apple’s private picker and does not grant bighelp general access to your photo library.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Device access")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.permissions")
        .task {
            await center.refresh()
            await center.deviceTools.refresh()
        }
    }

    @BighelpThemeReader private var theme
}

@MainActor
private struct DeviceToolPermissionRow: View {
    let permissions: DeviceToolPermissions
    let kind: DeviceToolCapability
    @Environment(\.openURL) private var openURL

    private var title: String {
        switch kind {
        case .health: "Apple Health"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        }
    }

    private var detail: String {
        switch kind {
        case .health: "Answer health and fitness questions using the Health data you choose to share."
        case .calendar: "Read, create, update, and delete events directly after you enable access."
        case .reminders: "Read, create, update, and delete reminders directly after you enable access."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Toggle(isOn: Binding(
                get: { permissions.isEnabled(kind) },
                set: { enabled in
                    if enabled { Task { await permissions.setEnabled(true, for: kind) } }
                    else { permissions.disable(kind) }
                }
            )) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(title).bighelpFont(.body, weight: .semibold)
                    Text(detail).bighelpFont(.metadata).foregroundStyle(.secondary)
                }
            }
            .disabled(!permissions.isEnabled(kind) && (permissions.scope == nil || permissions.requestInFlight != nil))
            .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue)")

            if permissions.requestInFlight == kind {
                ProgressView("Waiting for iOS…").bighelpFont(.metadata)
            } else if permissions.status(for: kind) == .denied {
                Button("Allow access in iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("permissions.device-tools.\(kind.rawValue).settings")
            } else if kind == .health, permissions.isEnabled(kind) {
                Text("Health controls which data is shared. An empty result can mean no data or access was not granted.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
            } else if permissions.scope != nil, permissions.status(for: kind) == .unavailable {
                Text("Unavailable on this device.").bighelpFont(.metadata).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }
}

@MainActor
struct PermissionRow: View {
    let center: PermissionCenter
    let kind: PermissionKind

    var body: some View {
        let status = center.status(for: kind)
        let presentation = PermissionRowPresentation(kind: kind, status: status)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(theme.action)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(kind.purpose)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(status.authorization.statusTitle)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(status.authorization == .denied ? theme.warning : theme.secondaryText)
            }

            if let detail = presentation.detailText {
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
            }

            switch presentation.action {
            case .request:
                Button(presentation.actionTitle ?? "Allow") {
                    Task { await center.request(kind) }
                }
                .disabled(center.requestInFlight != nil)
                .accessibilityIdentifier("permissions.\(kind.rawValue).allow")
            case .openSystemSettings:
                Button(presentation.actionTitle ?? "Open System Settings") {
                    center.performRecoveryAction(for: kind)
                }
                .accessibilityIdentifier("permissions.\(kind.rawValue).open-settings")
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityIdentifier("permissions.\(kind.rawValue).row")
    }

    @BighelpThemeReader private var theme
}

@MainActor
struct ContextualPermissionRecoveryView: View {
    let center: PermissionCenter
    let kind: PermissionKind

    var body: some View {
        let presentation = ContextualPermissionRecoveryPresentation(
            kind: kind,
            status: center.status(for: kind)
        )
        if let message = presentation.message {
            VStack(spacing: BighelpTokens.space16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if presentation.action == .openSystemSettings {
                    Button("Open System Settings") {
                        center.performRecoveryAction(for: kind)
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .accessibilityIdentifier("permissions.\(kind.rawValue).contextual-open-settings")
                }
            }
            .padding(BighelpTokens.space20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("permissions.\(kind.rawValue).contextual-recovery")
        }
    }

    @BighelpThemeReader private var theme
}

@MainActor
struct PermissionsOnboardingView: View {
    let model: PermissionsOnboardingModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(title)
                            .bighelpFont(.screenTitle)
                            .foregroundStyle(theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                    } icon: {
                        Image(systemName: currentKind.systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(theme.action)
                    }

                    Text(currentKind.purpose)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Button(actionTitle) {
                        Task { await model.allowCurrent() }
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                    .disabled(model.center.requestInFlight != nil)
                    .accessibilityIdentifier("permissions.onboarding.allow")
                } footer: {
                    Text("bighelp opens the iOS permission prompt only after you choose Allow. You can continue without granting access.")
                        .bighelpFont(.metadata)
                }
            }
            .bighelpFormSurface()
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Device access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { model.notNow() }
                        .accessibilityIdentifier("permissions.onboarding.not-now")
                }
            }
            .interactiveDismissDisabled()
            .accessibilityIdentifier("permissions.onboarding")
        }
    }

    private var currentKind: PermissionKind {
        model.step == .notification ? .notification : .locationWhenInUse
    }

    private var title: String {
        model.step == .notification ? "Notifications and Live Activities" : "Local weather, when you choose"
    }

    private var detail: String {
        if model.step == .notification {
            return "bighelp can show system alerts for replies and important status updates from the paired Hermes host you choose. During supported active runs, Live Activities can show progress on the Lock Screen and Dynamic Island. Chat remains available if you choose Not Now. bighelp asks iOS only after you tap below."
        }
        return "Location is optional. bighelp sends foreground approximate location to Apple Weather for current conditions and Apple location services for the city label. bighelp does not store your coordinates."
    }

    private var actionTitle: String {
        let state = model.center.status(for: currentKind).authorization
        return state == .notDetermined ? "Allow \(currentKind.title)" : "Continue"
    }

    @BighelpThemeReader private var theme
}
