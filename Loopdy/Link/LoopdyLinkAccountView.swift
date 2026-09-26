import SwiftUI

enum LoopdyLinkAccountLayoutMode: Equatable, Sendable {
    case stacked
    case split
}

enum LoopdyLinkAccountLayout {
    static let maximumContentWidth: CGFloat = 920

    static func mode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        usesAccessibilityLayout: Bool
    ) -> LoopdyLinkAccountLayoutMode {
        horizontalSizeClass == .regular && !usesAccessibilityLayout ? .split : .stacked
    }
}

struct LoopdyLinkAccountActionPresentation: Equatable, Sendable {
    static let surfaceRole: LoopdySurfaceRole = .capsuleControl
    static let usesColoredBorder = false
}

enum LoopdyLinkAccountConfirmationStyle: Equatable, Sendable {
    case centeredAlert
}

enum LoopdyLinkAccountConfirmationPresentation {
    static let signOut: LoopdyLinkAccountConfirmationStyle = .centeredAlert
}

@MainActor
enum LoopdyLinkAccountSignOutSequence {
    static func perform(
        dismissManagement: () -> Void,
        signOutSecurely: () async -> Void
    ) async {
        dismissManagement()
        await signOutSecurely()
    }
}

private struct LoopdyAccountDevicesSurface: ViewModifier {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled { content }
        else { content.loopdySurface(.card) }
    }
}

private enum LoopdyLinkAccountActionTone {
    case primary
    case neutral
    case destructive
}

@MainActor
struct LoopdyLinkAccountView: View {
    let store: LoopdyLinkAccountStore
    let onReady: () -> Void
    let allowsDismiss: Bool
    let deviceStore: LoopdyLinkDeviceStore?
    let onManageDevices: (() -> Void)?
    let onOpenDevice: ((LoopdyLinkDevice) -> Void)?
    @Environment(\.directHermesWorkspace) private var directHermesWorkspace
    @State private var isDirectHermesPresented = false

    init(
        store: LoopdyLinkAccountStore,
        onReady: @escaping () -> Void,
        allowsDismiss: Bool = true,
        deviceStore: LoopdyLinkDeviceStore? = nil,
        onManageDevices: (() -> Void)? = nil,
        onOpenDevice: ((LoopdyLinkDevice) -> Void)? = nil
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
                    HStack(alignment: .top, spacing: LoopdyTokens.space24) {
                        accountOverview
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        accountActionsCard
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: LoopdyTokens.space20) {
                        accountOverview
                        accountActionsCard
                    }
                }
            }
            .frame(maxWidth: LoopdyLinkAccountLayout.maximumContentWidth)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, horizontalSizeClass == .regular
                ? LoopdyTokens.space32
                : LoopdyTokens.space20)
            .padding(.vertical, horizontalSizeClass == .regular
                ? LoopdyTokens.space32
                : LoopdyTokens.space24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            if uiV3Enabled { theme.canvas.ignoresSafeArea() }
            else { LoopdyThemeCanvas(theme: theme).ignoresSafeArea() }
        }
        .navigationTitle("bighelp Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) {
                    LoopdyHeaderActionButton(
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
            .loopdyShellContentWidth()
        } else {
            v2AccountGate
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
    }

    private var v3HostDeviceContent: some View {
        let sections = LoopdyLinkDeviceSections(devices: deviceStore?.devices ?? [])
        let openDevice = onOpenDevice ?? { _ in }
        return VStack(alignment: .leading, spacing: LoopdyTokens.space24) {
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
                Label("Passkey-protected · Loopdy Link", systemImage: "person.badge.key")
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
                .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("Account actions")
        .accessibilityIdentifier("link.account.menu")
    }

    // V2 changes presentation only; account commands still use the same store.
    @ViewBuilder
    private var v2AccountContent: some View {
        if store.credentials != nil {
            VStack(alignment: .leading, spacing: LoopdyTokens.space24) {
                HStack(spacing: LoopdyTokens.space12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                        Text("Your bighelp account").loopdyFont(.sectionTitle)
                        Text("Passkey-protected · Loopdy Link")
                            .loopdyFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                if layoutMode == .split {
                    HStack(alignment: .top, spacing: LoopdyTokens.space24) {
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
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            if let deviceStore, let onOpenDevice, !deviceStore.devices.isEmpty {
                let sections = LoopdyLinkDeviceSections(devices: deviceStore.devices)
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
                Label("Loopdy Link is ready", systemImage: "checkmark.seal.fill")
                    .loopdyFont(.metadata, weight: .semibold)
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
        devices: [LoopdyLinkDevice],
        emptyMessage: String = "None available.",
        onOpenDevice: @escaping (LoopdyLinkDevice) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            Text(title)
                .loopdyFont(.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            accountDeviceGroupBody(
                devices: devices,
                emptyMessage: emptyMessage,
                onOpenDevice: onOpenDevice
            )
            .modifier(LoopdyAccountDevicesSurface())
        }
    }

    @ViewBuilder
    private func accountDeviceGroupBody(
        devices: [LoopdyLinkDevice],
        emptyMessage: String,
        onOpenDevice: @escaping (LoopdyLinkDevice) -> Void
    ) -> some View {
        if devices.isEmpty {
            Text(emptyMessage)
                .loopdyFont(.body)
                .foregroundStyle(theme.secondaryText)
                .padding(LoopdyTokens.space12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    Button { onOpenDevice(device) } label: {
                        HStack(spacing: LoopdyTokens.space12) {
                            Image(systemName: deviceSymbol(device.kind))
                                .foregroundStyle(theme.action)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                                Text(device.name).loopdyFont(.label)
                                Text(deviceStatus(device))
                                    .loopdyFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: LoopdyTokens.space8)
                            Image(systemName: "chevron.right").loopdyFont(.metadata)
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(LoopdyTokens.space12)
                        .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("link.account.device.\(device.id)")
                    if device.id != devices.last?.id { Divider() }
                }
            }
        }
    }

    private func deviceSymbol(_ kind: LoopdyLinkDeviceKind) -> String {
        switch kind {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .hermesHost: "desktopcomputer"
        }
    }

    private func deviceStatus(_ device: LoopdyLinkDevice) -> String {
        let connection: String
        switch device.connection {
        case .online: connection = "Online"
        case .recent: connection = "Recently active"
        case .offline: connection = "Offline"
        }
        return device.isCurrentDevice ? "Current device · \(connection)" : connection
    }

    private var v2AccountGate: some View {
        VStack(spacing: LoopdyTokens.space24) {
            if !uiV3Enabled { LoopdyLogo(height: 32) }
            Image(systemName: "person.badge.key.fill")
                .font(.largeTitle)
                .foregroundStyle(theme.action)
                .frame(width: 72, height: 72)
                .loopdySurface(.card)
                .accessibilityHidden(true)
            VStack(spacing: LoopdyTokens.space8) {
                Text(uiV3Enabled ? "Welcome to bighelp" : "Continue securely")
                    .loopdyFont(.screenTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("bighelp uses passkeys so your identity stays private and your devices stay revocable.")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: LoopdyTokens.space4) {
                v2AccessMode("Sign in", creating: false)
                v2AccessMode("Sign up", creating: true)
            }
            .padding(LoopdyTokens.space4)
            .loopdySurface(.capsuleControl)
            .disabled(store.state == .working)
            LoopdyShellSection {
                VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                    Text(isCreatingAccount ? "Create your bighelp account" : "Welcome back")
                        .loopdyFont(.sectionTitle)
                    Text(isCreatingAccount
                        ? "One passkey creates a private account and a unique, revocable identity for this device."
                        : "Use your saved passkey to restore your encrypted bighelp account key on this device.")
                        .loopdyFont(.body)
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
                .loopdyFont(.metadata)
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
                .loopdyFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
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
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
        }
        .loopdyActionStyle(primary ? .primary : uiV3Enabled && !destructive ? .quiet : .secondary)
        .accessibilityIdentifier(identifier)
    }

    private var accountOverview: some View {
        LoopdyCard {
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.action)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                    Text("Your bighelp account")
                        .loopdyFont(.screenTitle)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your passkey securely keeps bighelp connected across your devices without an email address, password, phone number, or stored profile details.")
                        .loopdyFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(
                    "Account and notification setup stay encrypted on this device.",
                    systemImage: "lock.shield"
                )
                .loopdyFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountActionsCard: some View {
        LoopdyCard {
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                Text(accountSectionTitle)
                    .loopdyFont(.sectionTitle)
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
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
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
            HStack(spacing: LoopdyTokens.space12) {
                LoopdyThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Completing secure account request…")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
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
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
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
                .loopdyFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyActions: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            if let message = store.errorMessage {
                accountError(message)
            }
            Label("Loopdy Link is ready", systemImage: "checkmark.seal.fill")
                .loopdyFont(.sectionTitle)
                .foregroundStyle(theme.success)
            Text("This device has its own revocable identity and can connect securely to your Hermes host.")
                .loopdyFont(.body)
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
            .loopdyFont(.body)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accountActionButton(
        _ title: String,
        systemImage: String,
        tone: LoopdyLinkAccountActionTone,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: tone == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: LoopdyTokens.space12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .loopdyFont(.label, weight: .semibold)
                Spacer(minLength: LoopdyTokens.space8)
            }
            .foregroundStyle(actionForeground(for: tone))
            .padding(.horizontal, LoopdyTokens.space16)
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .loopdySurface(
            LoopdyLinkAccountActionPresentation.surfaceRole,
            isInteractive: true
        )
        .accessibilityIdentifier(identifier)
    }

    private func actionForeground(for tone: LoopdyLinkAccountActionTone) -> Color {
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

    private var layoutMode: LoopdyLinkAccountLayoutMode {
        LoopdyLinkAccountLayout.mode(
            horizontalSizeClass: horizontalSizeClass,
            usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize
        )
    }

    @State private var isCreatingAccount = false
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @LoopdyThemeReader private var theme
}
