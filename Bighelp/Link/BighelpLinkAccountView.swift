import SwiftUI

enum BighelpLinkAccountLayoutMode: Equatable, Sendable {
    case stacked
    case split
}

enum BighelpLinkAccountLayout {
    static let maximumContentWidth: CGFloat = 920

    static func mode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        usesAccessibilityLayout: Bool
    ) -> BighelpLinkAccountLayoutMode {
        horizontalSizeClass == .regular && !usesAccessibilityLayout ? .split : .stacked
    }
}

struct BighelpLinkAccountActionPresentation: Equatable, Sendable {
    static let surfaceRole: BighelpSurfaceRole = .capsuleControl
    static let usesColoredBorder = false
}

enum BighelpLinkAccountConfirmationStyle: Equatable, Sendable {
    case centeredAlert
}

enum BighelpLinkAccountConfirmationPresentation {
    static let signOut: BighelpLinkAccountConfirmationStyle = .centeredAlert
}

@MainActor
enum BighelpLinkAccountSignOutSequence {
    static func perform(
        dismissManagement: () -> Void,
        signOutSecurely: () async -> Void
    ) async {
        dismissManagement()
        await signOutSecurely()
    }
}

private struct BighelpAccountDevicesSurface: ViewModifier {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled { content }
        else { content.bighelpSurface(.card) }
    }
}

private enum BighelpLinkAccountActionTone {
    case primary
    case neutral
    case destructive
}

@MainActor
struct BighelpLinkAccountView: View {
    let store: BighelpLinkAccountStore
    let onReady: () -> Void
    let allowsDismiss: Bool
    let deviceStore: BighelpLinkDeviceStore?
    let onManageDevices: (() -> Void)?
    let onOpenDevice: ((BighelpLinkDevice) -> Void)?
    @Environment(\.directHermesWorkspace) private var directHermesWorkspace
    @State private var isDirectHermesPresented = false

    init(
        store: BighelpLinkAccountStore,
        onReady: @escaping () -> Void,
        allowsDismiss: Bool = true,
        deviceStore: BighelpLinkDeviceStore? = nil,
        onManageDevices: (() -> Void)? = nil,
        onOpenDevice: ((BighelpLinkDevice) -> Void)? = nil
    ) {
        self.store = store
        self.onReady = onReady
        self.allowsDismiss = allowsDismiss
        self.deviceStore = deviceStore
        self.onManageDevices = onManageDevices
        self.onOpenDevice = onOpenDevice
    }

    var body: some View {
        ScrollView {
            Group {
                if uiV3Enabled {
                    v3AccountContent
                } else if uiV2Enabled {
                    v2AccountContent
                } else if layoutMode == .split {
                    HStack(alignment: .top, spacing: BighelpTokens.space24) {
                        accountOverview
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        accountActionsCard
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                        accountOverview
                        accountActionsCard
                    }
                }
            }
            .frame(maxWidth: BighelpLinkAccountLayout.maximumContentWidth)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, horizontalSizeClass == .regular
                ? BighelpTokens.space32
                : BighelpTokens.space20)
            .padding(.vertical, horizontalSizeClass == .regular
                ? BighelpTokens.space32
                : BighelpTokens.space24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            if uiV3Enabled { theme.canvas.ignoresSafeArea() }
            else { BighelpThemeCanvas(theme: theme).ignoresSafeArea() }
        }
        .navigationTitle("bighelp Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) {
                    BighelpHeaderActionButton(
                        systemImage: "xmark",
                        accessibilityLabel: "Close bighelp Account",
                        action: dismiss.callAsFunction
                    )
                }
            }
            if uiV3Enabled, store.credentials != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    v3AccountMenu
                }
            }
        }
        .alert("Sign out of bighelp?", isPresented: $isSignOutConfirmationPresented) {
            Button("Sign Out", role: .destructive) {
                store.beginSignOut()
                if allowsDismiss { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes this device’s local bighelp account data. Your account and other paired devices remain available.")
        }
        .alert("Permanently delete your bighelp account?", isPresented: $isDeleteConfirmationPresented) {
            Button("Delete Account", role: .destructive) {
                Task { await store.deleteAccount() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You’ll confirm with your passkey. bighelp will revoke paired devices, notification delivery, live activities, relay state, and this device’s local account data. This cannot be undone.")
        }
        .accessibilityIdentifier("link.account")
        .safeAreaInset(edge: .bottom) {
            if store.credentials == nil, directHermesWorkspace != nil {
                Button("Connect directly to Hermes", systemImage: "server.rack") {
                    isDirectHermesPresented = true
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(theme.canvas)
                .accessibilityIdentifier("direct-hermes.open")
            }
        }
        .fullScreenCover(isPresented: $isDirectHermesPresented) {
            if let directHermesWorkspace {
                NavigationStack {
                    DirectHermesWorkspaceView(store: directHermesWorkspace)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { isDirectHermesPresented = false }
                                    .accessibilityIdentifier("direct-hermes.done")
                            }
                        }
                }
            }
        }
        .task(id: store.credentials?.deviceID) {
            guard uiV2Enabled, store.credentials != nil, let deviceStore,
                  deviceStore.loadState == .idle else { return }
            await deviceStore.load()
        }
    }

    @ViewBuilder
    private var v3AccountContent: some View {
        if store.credentials != nil {
            v3HostDeviceContent
            .bighelpShellContentWidth()
        } else {
            v2AccountGate
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }

    private var v3HostDeviceContent: some View {
        let sections = BighelpLinkDeviceSections(devices: deviceStore?.devices ?? [])
        let openDevice = onOpenDevice ?? { _ in }
        return VStack(alignment: .leading, spacing: BighelpTokens.space24) {
            accountDeviceGroup(
                "Hosts",
                devices: sections.hosts,
                emptyMessage: "No hosts are paired yet.",
                onOpenDevice: openDevice
            )
            accountDeviceGroup(
                "Connected Devices",
                devices: sections.connectedDevices,
                emptyMessage: "No connected devices are available.",
                onOpenDevice: openDevice
            )
        }
    }

    private var v3AccountMenu: some View {
        Menu {
            Section("Account") {
                Label("Passkey-protected · bighelp Link", systemImage: "person.badge.key")
                Text("Your account uses a private, revocable device identity.")
            }
            Section {
                if store.state == .working {
                    Label("Completing secure account request…", systemImage: "hourglass")
                } else {
                    Button {
                        onReady()
                        if allowsDismiss { dismiss() }
                    } label: {
                        Label("Continue", systemImage: "arrow.right")
                    }
                    .accessibilityIdentifier("link.account.continue")
                    Button {
                        isSignOutConfirmationPresented = true
                    } label: {
                        Label("Sign out of this device", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("link.account.sign-out")
                    Button(role: .destructive) {
                        isDeleteConfirmationPresented = true
                    } label: {
                        Label("Delete account", systemImage: "trash")
                    }
                    .accessibilityIdentifier("link.account.delete")
                }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title3.weight(.semibold))
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("Account actions")
        .accessibilityIdentifier("link.account.menu")
    }

    // V2 changes presentation only; account commands still use the same store.
    @ViewBuilder
    private var v2AccountContent: some View {
        if store.credentials != nil {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text("Your bighelp account").bighelpFont(.sectionTitle)
                        Text("Passkey-protected · bighelp Link")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                if layoutMode == .split {
                    HStack(alignment: .top, spacing: BighelpTokens.space24) {
                        accountOverview.frame(maxWidth: .infinity)
                        v2Management.frame(maxWidth: .infinity)
                    }
                } else {
                    accountOverview
                    v2Management
                }
            }
            .foregroundStyle(theme.primaryText)
        } else {
            v2AccountGate
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }

    private var v2Management: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            if let deviceStore, let onOpenDevice, !deviceStore.devices.isEmpty {
                let sections = BighelpLinkDeviceSections(devices: deviceStore.devices)
                if !sections.hosts.isEmpty {
                    accountDeviceGroup("Hosts", devices: sections.hosts, onOpenDevice: onOpenDevice)
                }
                if !sections.connectedDevices.isEmpty {
                    accountDeviceGroup("Connected Devices", devices: sections.connectedDevices, onOpenDevice: onOpenDevice)
                }
            }
            if let onManageDevices {
                v2Action("Manage paired devices", symbol: "link", identifier: "link.account.devices", action: onManageDevices)
            }
            if store.state == .working {
                accountActions
            } else {
                if let message = store.errorMessage { accountError(message) }
                Label("bighelp Link is ready", systemImage: "checkmark.seal.fill")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.success)
                v2Action("Continue", symbol: "arrow.right", primary: true, identifier: "link.account.continue") {
                    onReady()
                    if allowsDismiss { dismiss() }
                }
                v2Action("Sign out of this device", symbol: "rectangle.portrait.and.arrow.right", identifier: "link.account.sign-out") {
                    isSignOutConfirmationPresented = true
                }
                v2Action("Delete account", symbol: "trash", destructive: true, identifier: "link.account.delete") {
                    isDeleteConfirmationPresented = true
                }
            }
        }
    }

    private func accountDeviceGroup(
        _ title: String,
        devices: [BighelpLinkDevice],
        emptyMessage: String = "None available.",
        onOpenDevice: @escaping (BighelpLinkDevice) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(title)
                .bighelpFont(.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            accountDeviceGroupBody(
                devices: devices,
                emptyMessage: emptyMessage,
                onOpenDevice: onOpenDevice
            )
            .modifier(BighelpAccountDevicesSurface())
        }
    }

    @ViewBuilder
    private func accountDeviceGroupBody(
        devices: [BighelpLinkDevice],
        emptyMessage: String,
        onOpenDevice: @escaping (BighelpLinkDevice) -> Void
    ) -> some View {
        if devices.isEmpty {
            Text(emptyMessage)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .padding(BighelpTokens.space12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    Button { onOpenDevice(device) } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            Image(systemName: deviceSymbol(device.kind))
                                .foregroundStyle(theme.action)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(device.name).bighelpFont(.label)
                                Text(deviceStatus(device))
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: BighelpTokens.space8)
                            Image(systemName: "chevron.right").bighelpFont(.metadata)
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(BighelpTokens.space12)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("link.account.device.\(device.id)")
                    if device.id != devices.last?.id { Divider() }
                }
            }
        }
    }

    private func deviceSymbol(_ kind: BighelpLinkDeviceKind) -> String {
        switch kind {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .hermesHost: "desktopcomputer"
        }
    }

    private func deviceStatus(_ device: BighelpLinkDevice) -> String {
        let connection: String
        switch device.connection {
        case .online: connection = "Online"
        case .recent: connection = "Recently active"
        case .offline: connection = "Offline"
        }
        return device.isCurrentDevice ? "Current device · \(connection)" : connection
    }

    private var v2AccountGate: some View {
        VStack(spacing: BighelpTokens.space24) {
            if !uiV3Enabled { BighelpLogo(height: 32) }
            Image(systemName: "person.badge.key.fill")
                .font(.largeTitle)
                .foregroundStyle(theme.action)
                .frame(width: 72, height: 72)
                .bighelpSurface(.card)
                .accessibilityHidden(true)
            VStack(spacing: BighelpTokens.space8) {
                Text(uiV3Enabled ? "Welcome to bighelp" : "Continue securely")
                    .bighelpFont(.screenTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("bighelp uses passkeys so your identity stays private and your devices stay revocable.")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: BighelpTokens.space4) {
                v2AccessMode("Sign in", creating: false)
                v2AccessMode("Sign up", creating: true)
            }
            .padding(BighelpTokens.space4)
            .bighelpSurface(.capsuleControl)
            .disabled(store.state == .working)
            BighelpShellSection {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Text(isCreatingAccount ? "Create your bighelp account" : "Welcome back")
                        .bighelpFont(.sectionTitle)
                    Text(isCreatingAccount
                        ? "One passkey creates a private account and a unique, revocable identity for this device."
                        : "Use your saved passkey to restore your encrypted bighelp account key on this device.")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                    if store.state == .working {
                        accountActions
                    } else {
                        if let message = store.errorMessage { accountError(message) }
                        if store.needsLocalCleanup { cleanupRetry }
                        v2Action(
                            isCreatingAccount ? "Create account with passkey" : "Sign in with passkey",
                            symbol: "person.badge.key", primary: true,
                            identifier: isCreatingAccount ? "link.account.create" : "link.account.sign-in"
                        ) {
                            Task {
                                if isCreatingAccount { await store.register() }
                                else { await store.signIn() }
                            }
                        }
                        .disabled(store.needsLocalCleanup)
                    }
                }
            }
            Label("No email, password, or phone number required. bighelp never receives your Apple account details or biometric data.", systemImage: "lock.shield")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.primaryText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link.account.v2-gate")
    }

    private func v2AccessMode(_ title: String, creating: Bool) -> some View {
        Button { isCreatingAccount = creating } label: {
            Text(title)
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .background(isCreatingAccount == creating ? theme.raisedSurface : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCreatingAccount == creating ? .isSelected : [])
        .accessibilityIdentifier(creating ? "link.account.mode.sign-up" : "link.account.mode.sign-in")
    }

    private func v2Action(
        _ title: String, symbol: String, primary: Bool = false,
        destructive: Bool = false, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: symbol)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
        }
        .bighelpActionStyle(primary ? .primary : uiV3Enabled && !destructive ? .quiet : .secondary)
        .accessibilityIdentifier(identifier)
    }

    private var accountOverview: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text("Your bighelp account")
                        .bighelpFont(.screenTitle)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your passkey securely keeps bighelp connected across your devices without an email address, password, phone number, or stored profile details.")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(
                    "Account and notification setup stay encrypted on this device.",
                    systemImage: "lock.shield"
                )
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountActionsCard: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Text(accountSectionTitle)
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                accountActions
            }
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        switch store.state {
        case .signedOut:
            signedOutActions
        case .failed where store.credentials == nil:
            signedOutActions
        case .failed:
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                accountError(
                    store.errorMessage ?? "This account action could not be completed securely."
                )
                accountActionButton(
                    "Retry Secure Sign Out",
                    systemImage: "arrow.clockwise",
                    tone: .destructive,
                    identifier: "link.account.sign-out-retry"
                ) {
                    Task { await store.signOut() }
                }
            }
        case .working:
            HStack(spacing: BighelpTokens.space12) {
                BighelpThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Completing secure account request…")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        case .ready:
            readyActions
        }
    }

    private var cleanupRetry: some View {
        accountActionButton(
            "Retry Secure Sign Out", systemImage: "arrow.clockwise", tone: .destructive,
            identifier: "link.account.sign-out-retry"
        ) {
            store.beginSignOut()
        }
    }

    private var signedOutActions: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            if let message = store.errorMessage {
                accountError(message)
            }
            if store.needsLocalCleanup { cleanupRetry }
            accountActionButton(
                "Create bighelp Account",
                systemImage: "person.badge.plus",
                tone: .primary,
                identifier: "link.account.create"
            ) {
                Task { await store.register() }
            }
            .disabled(store.needsLocalCleanup)

            accountActionButton(
                "Sign In with Passkey",
                systemImage: "person.badge.key",
                tone: .neutral,
                identifier: "link.account.sign-in"
            ) {
                Task { await store.signIn() }
            }
            .disabled(store.needsLocalCleanup)

            Text("Your passkey may sync through Apple Passwords. bighelp never receives your Apple account details.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyActions: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            if let message = store.errorMessage {
                accountError(message)
            }
            Label("bighelp Link is ready", systemImage: "checkmark.seal.fill")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.success)
            Text("This device has its own revocable identity and can connect securely to your Hermes host.")
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            accountActionButton(
                "Continue",
                systemImage: "arrow.right",
                tone: .primary,
                identifier: "link.account.continue"
            ) {
                onReady()
                dismiss()
            }

            Divider()

            accountActionButton(
                "Sign Out",
                systemImage: "rectangle.portrait.and.arrow.right",
                tone: .neutral,
                identifier: "link.account.sign-out"
            ) {
                isSignOutConfirmationPresented = true
            }

            accountActionButton(
                "Delete Account",
                systemImage: "trash",
                tone: .destructive,
                identifier: "link.account.delete"
            ) {
                isDeleteConfirmationPresented = true
            }
        }
    }

    private func accountError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .bighelpFont(.body)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accountActionButton(
        _ title: String,
        systemImage: String,
        tone: BighelpLinkAccountActionTone,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: tone == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .bighelpFont(.label, weight: .semibold)
                Spacer(minLength: BighelpTokens.space8)
            }
            .foregroundStyle(actionForeground(for: tone))
            .padding(.horizontal, BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .bighelpSurface(
            BighelpLinkAccountActionPresentation.surfaceRole,
            isInteractive: true
        )
        .accessibilityIdentifier(identifier)
    }

    private func actionForeground(for tone: BighelpLinkAccountActionTone) -> Color {
        switch tone {
        case .primary:
            theme.action
        case .neutral:
            theme.primaryText
        case .destructive:
            theme.danger
        }
    }

    private var accountSectionTitle: String {
        switch store.state {
        case .signedOut:
            "Get started"
        case .failed where store.credentials == nil:
            "Get started"
        case .working:
            "Securing your account"
        case .ready:
            "Account status"
        case .failed:
            "Account action needed"
        }
    }

    private var layoutMode: BighelpLinkAccountLayoutMode {
        BighelpLinkAccountLayout.mode(
            horizontalSizeClass: horizontalSizeClass,
            usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize
        )
    }

    @State private var isCreatingAccount = false
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @BighelpThemeReader private var theme
}
