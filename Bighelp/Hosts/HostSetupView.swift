import SwiftUI

/// Editing the Cloudflare Access token starts discovery over, like the address.
private struct HostSetupAccessChanges: ViewModifier {
    let values: [String]
    let onChange: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: values) { _, _ in onChange() }
    }
}

enum HostSetupAccessError: LocalizedError {
    case needsHTTPS
    /// A proxy in front of Hermes asked for a username and password.
    case proxyPasswordRequired
    case proxyPasswordRejected
    case blockedBeforeSignIn
    case loginPage
    case invalidProxyCredentials

    var errorDescription: String? {
        switch self {
        case .needsHTTPS:
            "Cloudflare Access needs an https:// address."
        case .proxyPasswordRequired:
            "This address is protected by a username and password, set on a proxy in front of Hermes. Enter them below, then tap Continue."
        case .proxyPasswordRejected:
            "The proxy in front of Hermes didn't accept that username and password. Check them and try again."
        case .blockedBeforeSignIn:
            "Something in front of Hermes, like a proxy or firewall, turned bighelp away before sign-in. Hermes itself never blocks this step. If the proxy uses a username and password, turn on Username and password under Advanced connection."
        case .invalidProxyCredentials:
            "Check the username and password. A username can't contain a colon."
        case .loginPage:
            "This address sends bighelp to a login page it can't use. If it's Cloudflare Access, add a service token under Advanced connection. Otherwise, use an address that reaches Hermes directly."
        }
    }
}

struct HostSetupDraft: Equatable {
    var address = ""
    var port = ""
    var name = ""
    var allowPrivateHTTP = false
}

/// The address-first host wizard, used both at first run and by Add Host.
@MainActor
struct HostSetupView: View {
    let registry: BighelpHostRegistry
    var allowsDismiss = true
    var hostToAuthenticate: BighelpConfiguredHost? = nil
    var firstRunPresentation = false
    var completionActionTitle = "Start chatting"
    var retainedDraft: Binding<HostSetupDraft>? = nil
    var onConnectionCommitted: ((BighelpConfiguredHost) -> Void)? = nil
    var onFinished: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isAddressFocused: Bool
    @State private var showsConnectionOptions = false
    @State private var address = ""
    @State private var port = ""
    @State private var name = ""
    @State private var allowPrivateHTTP = false
    /// Cloudflare Access service token; never kept in the retained draft.
    @State private var usesCloudflareAccess = false
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    /// A proxy's basic-auth username and password; never kept in the retained draft.
    @State private var usesProxyPassword = false
    /// Set when the address itself asked for a password; opening the fields
    /// this way must not restart discovery and clear the explanation.
    @State private var needsProxyPassword = false
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var method = Method.token
    @State private var provider = ""
    @State private var discovery: HostAuthenticationDiscovery?
    @State private var pendingID: UUID?
    @State private var workspace: DirectHermesWorkspaceStore?
    @State private var connectedHost: BighelpConfiguredHost?
    @State private var notifications: HostNotificationSetupModel?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var browserTransactionID: UUID?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Method: String, Identifiable { case dashboard, token, password, browser; var id: Self { self } }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    if !firstRunPresentation {
                        BighelpLogo(presentation: .mark, height: 36)
                            .accessibilityHidden(true)
                    }
                    Text(connectedHost == nil
                         ? "Connect your computer"
                         : "Connected")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(connectedHost == nil
                         ? "Enter the address where Hermes is running."
                         : "Your agents are ready to chat.")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.vertical, firstRunPresentation ? 4 : 24)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if let host = connectedHost, let notifications {
                Section {
                    Label(host.name, systemImage: "checkmark.circle.fill")
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .padding(.vertical, 8)
                }
                .listRowBackground(theme.surface)
                if !firstRunPresentation {
                    Section {
                        primaryAction(completionActionTitle, identifier: "host-setup.continue", disabled: false) { finish() }
                    }
                    .listRowBackground(Color.clear)
                }
                HostNotificationSetupSection(
                    model: notifications,
                    hostName: host.name,
                    hostEndpoint: host.endpoint.identity
                )
                    .listRowBackground(theme.surface)
            } else {
                Section {
                    TextField("Hermes address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Host URL or IP address")
                        .accessibilityIdentifier("host-setup.address")
                        .focused($isAddressFocused)
                        .disabled(hostToAuthenticate != nil)
                        .padding(.vertical, 6)
                    TextField("Computer name (optional)", text: $name)
                        .accessibilityIdentifier("host-setup.name")
                        .disabled(hostToAuthenticate != nil)
                    DisclosureGroup(isExpanded: $showsConnectionOptions) {
                        TextField("Port (optional)", text: $port)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("host-setup.port")
                            .disabled(hostToAuthenticate != nil)
                        Toggle("Allow HTTP on a private network", isOn: $allowPrivateHTTP)
                            .accessibilityIdentifier("direct-hermes.private-http")
                            .disabled(hostToAuthenticate != nil)
                        Text("For home Wi-Fi, a VPN or Tailscale, such as 192.168.1.20, 10.0.0.5 or hermes.local. Connect this device to that network first.")
                            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                        if hostToAuthenticate == nil {
                            proxyPasswordFields
                            cloudflareAccessFields
                        }
                    } label: {
                        Label("Advanced connection", systemImage: "slider.horizontal.3")
                            .bighelpFont(.label, weight: .regular)
                            .frame(minHeight: 44)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("host-setup.options")
                } header: { Text("Computer") }
                .listRowBackground(theme.surface)
                if let discovery {
                    authenticationSection(discovery)
                        .disabled(isWorking)
                        .listRowBackground(theme.surface)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .bighelpFont(.body).foregroundStyle(theme.primaryText)
                            .accessibilityIdentifier("host-setup.error")
                    }
                    .listRowBackground(theme.surface)
                }
                Section {
                    if !firstRunPresentation {
                        connectionAction
                    }
                    Text("Your authenticated session or token is saved securely in Keychain. Passwords you enter aren’t retained.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                .listRowBackground(Color.clear)
                Section {
                    Link("Need help connecting?", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend")!)
                        .bighelpFont(.label, weight: .regular)
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .tint(theme.action)
        .navigationTitle(hostToAuthenticate == nil ? "" : "Sign in again")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.defaultMinListRowHeight, 44)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if firstRunPresentation {
                VStack(spacing: 0) {
                    Divider().overlay(theme.border)
                    if connectedHost != nil {
                        primaryAction(
                            completionActionTitle,
                            identifier: "host-setup.continue",
                            disabled: false
                        ) { finish() }
                    } else {
                        connectionAction
                    }
                }
                .padding(.horizontal, BighelpTokens.space24)
                .padding(.vertical, BighelpTokens.space12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .task {
            if firstRunPresentation, connectedHost == nil,
               let onboardingHostID = registry.onboardingHostID,
               let host = registry.hosts.first(where: { $0.id == onboardingHostID }) {
                connectedHost = host
                notifications = HostNotificationSetupModel(host: host, registry: registry)
                onConnectionCommitted?(host)
                return
            }
            if let retainedDraft {
                let draft = retainedDraft.wrappedValue
                address = draft.address
                port = draft.port
                name = draft.name
                allowPrivateHTTP = draft.allowPrivateHTTP
            }
            guard let host = hostToAuthenticate else { return }
            address = host.endpoint.identity
            name = host.name
            allowPrivateHTTP = host.endpoint.allowPrivateHTTP
            pendingID = host.id
            workspace = registry.workspace(for: host)
        }
        .onChange(of: address) { _, _ in needsProxyPassword = false; invalidateDiscovery(); saveRetainedDraft() }
        .onChange(of: port) { _, _ in invalidateDiscovery(); saveRetainedDraft() }
        .onChange(of: name) { _, _ in saveRetainedDraft() }
        .onChange(of: allowPrivateHTTP) { _, _ in invalidateDiscovery(); saveRetainedDraft() }
        .modifier(HostSetupAccessChanges(values: [usesCloudflareAccess ? "on" : "off", accessClientID, accessClientSecret,
                                                  usesProxyPassword ? "on" : "off", proxyUsername, proxyPassword],
                                          onChange: invalidateDiscovery))
        // One kind of gate per address.
        .onChange(of: usesProxyPassword) { _, on in if on { usesCloudflareAccess = false } }
        .onChange(of: usesCloudflareAccess) { _, on in if on { usesProxyPassword = false; needsProxyPassword = false } }
        .onChange(of: method) { _, _ in token = ""; password = ""; provider = defaultProvider }
        .onChange(of: provider) { _, _ in password = "" }
        .onChange(of: registry.accountScope) { _, _ in cancel(); dismiss() }
        .onChange(of: scenePhase) { _, phase in
            // The system-browser transaction owns its bounded listener while the
            // app visits Safari, MFA, or a password manager. All other setup work
            // retains the existing true-background cancellation behavior.
            if phase == .background, browserTransactionID == nil {
                notifications?.cancel()
                cancel()
            }
        }
        .onDisappear {
            saveRetainedDraft()
            notifications?.cancel()
            cancel()
            if connectedHost == nil, let pendingID { registry.discardPending(pendingID) }
        }
        .accessibilityIdentifier("host-setup.screen")
    }

    @BighelpThemeReader private var theme

    @ViewBuilder
    private func primaryAction(_ title: String, identifier: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if isWorking { ProgressView() }
                Text(title).bighelpFont(.label, weight: .semibold)
                Spacer(minLength: 0)
            }
            .frame(minHeight: firstRunPresentation ? BighelpTokens.primaryActionSize : 44)
            .contentShape(.rect)
        }
        .controlSize(.large)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent).foregroundStyle(Color.bighelpActionInk)
        } else {
            button.bighelpProminentButtonStyle()
        }
    }

    private var connectionAction: some View {
        primaryAction(
            isWorking ? (discovery == nil ? "Finding your agents…" : "Connecting…")
                      : (discovery == nil ? "Continue" : "Connect"),
            identifier: "host-setup.connect-host",
            disabled: isWorking || (discovery.map { !canConnect($0) } ?? false)
        ) {
            if let discovery { connect(discovery) }
            else if address.isEmpty { isAddressFocused = true }
            else { discover() }
        }
    }

    @ViewBuilder
    private func authenticationSection(_ discovery: HostAuthenticationDiscovery) -> some View {
        Section {
            if discovery.supportsToken || discovery.supportsPassword || discovery.nativePKCE {
                Picker("Connection method", selection: $method) {
                    if discovery.supportsDashboard { Text("No sign-in").tag(Method.dashboard) }
                    if discovery.supportsToken { Text(discovery.requiresAuthentication ? "Access token" : "Session token").tag(Method.token) }
                    if discovery.supportsPassword { Text("Username & password").tag(Method.password) }
                    if discovery.nativePKCE { Text("Browser sign-in").tag(Method.browser) }
                }.accessibilityIdentifier("direct-hermes.auth-picker")
            }
            if method == .token && discovery.supportsToken {
                SecureField(discovery.requiresAuthentication ? "Access token" : "Dashboard session token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("direct-hermes.token")
            } else if method == .browser && discovery.nativePKCE {
                // One provider needs no choice.
                if discovery.providers.count > 1 {
                    Picker("Provider", selection: $provider) {
                        Text("Automatic").tag("")
                        ForEach(discovery.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }.accessibilityIdentifier("host-setup.provider")
                }
            } else if method == .password && discovery.supportsPassword {
                if discovery.providers.filter(\.supportsPassword).count > 1 {
                    Picker("Provider", selection: $provider) {
                        ForEach(discovery.providers.filter(\.supportsPassword)) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .accessibilityIdentifier("host-setup.provider")
                }
                TextField("Username", text: $username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("direct-hermes.username")
                SecureField("Password", text: $password).textContentType(.password)
                    .accessibilityIdentifier("direct-hermes.password")
            }
            Text(methodDetail(discovery))
                .bighelpFont(.metadata).foregroundStyle(.secondary)
                .accessibilityIdentifier("host-setup.method-detail")

        } header: { Text("Sign in") }
    }

    private func methodDetail(_ discovery: HostAuthenticationDiscovery) -> String {
        switch method {
        case .dashboard:
            "Connect using your dashboard’s existing access. No sign-in is required by this host."
        case .token where discovery.requiresAuthentication:
            "An access token issued by this host’s sign-in provider."
        case .token:
            "The dashboard’s session token, set on your computer as HERMES_DASHBOARD_SESSION_TOKEN."
        case .password:
            "The username and password for your Hermes dashboard."
        case .browser:
            if discovery.providers.count == 1, let only = discovery.providers.first {
                "Opens \(only.name) sign-in in Safari, then brings you back here."
            } else {
                "Opens your Hermes sign-in page in Safari, for single sign-on like Authentik, Keycloak or Nous Portal, then brings you back here."
            }
        }
    }

    private var defaultProvider: String {
        guard method == .password else { return "" }
        return discovery?.providers.first(where: \.supportsPassword)?.id ?? ""
    }
    private func canConnect(_ discovery: HostAuthenticationDiscovery) -> Bool {
        switch method {
        case .dashboard: discovery.supportsDashboard
        case .token: discovery.supportsToken && !token.isEmpty
        case .password: discovery.supportsPassword && !provider.isEmpty && !username.isEmpty && !password.isEmpty
        case .browser: discovery.nativePKCE
        }
    }
    private func discover() {
        cancel()
        discovery = nil
        let owner = UUID(); requestID = owner
        let account = registry.accountScope
        let accountGeneration = registry.generation
        guard account != nil else { return }
        isWorking = true; errorMessage = nil
        task = Task { @MainActor in
            defer { if requestID == owner { isWorking = false } }
            do {
                let endpoint = try HostAddressInput.endpoint(address: address, port: port, allowPrivateHTTP: allowPrivateHTTP)
                let sentProxyPassword = try stageAccess(for: endpoint)
                let result: HostAuthenticationDiscovery
                do {
                    result = try await HostAuthenticationDiscovery.discover(endpoint: endpoint)
                } catch let gate as HostAuthenticationDiscovery.Gate {
                    switch gate {
                    case .passwordProxy:
                        guard requestID == owner else { return }
                        needsProxyPassword = true
                        showsConnectionOptions = true
                        throw sentProxyPassword ? HostSetupAccessError.proxyPasswordRejected
                                                : HostSetupAccessError.proxyPasswordRequired
                    case .blocked:
                        throw sentProxyPassword ? HostSetupAccessError.proxyPasswordRejected
                                                : HostSetupAccessError.blockedBeforeSignIn
                    case .loginPage:
                        throw HostSetupAccessError.loginPage
                    }
                }
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration, !Task.isCancelled else { return }
                discovery = result
                method = Method(rawValue: HostAuthenticationDiscovery.preferredMethod(for: result).rawValue) ?? .token
                provider = defaultProvider
            } catch {
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration else { return }
                errorMessage = (error as? HostSetupAccessError)?.localizedDescription
                    ?? DirectHermesConversationClient.safeMessage(error)
            }
        }
    }
    private func connect(_ discovery: HostAuthenticationDiscovery) {
        guard canConnect(discovery), registry.canConfigureHosts else { return }
        BighelpKeyboard.dismiss()
        let auth: DirectHermesAuthInput
        switch method {
        case .dashboard: auth = .dashboard
        case .token: auth = .token(token)
        case .password: auth = .passwordProvider(provider: provider, username: username, password: password)
        case .browser: auth = .browser(provider: provider.isEmpty ? nil : provider)
        }
        cancel()
        let owner = UUID(); requestID = owner
        if case .browser = auth { browserTransactionID = owner }
        let account = registry.accountScope
        let accountGeneration = registry.generation
        isWorking = true; errorMessage = nil
        task = Task { @MainActor in
            defer {
                if browserTransactionID == owner { browserTransactionID = nil }
                if requestID == owner { isWorking = false; token = ""; password = "" }
            }
            do {
                if workspace == nil {
                    let pending = try registry.makePendingWorkspace()
                    pendingID = pending.0; workspace = pending.1
                }
                guard let pendingID, let workspace else { return }
                await workspace.connect(address: discovery.endpoint.identity, auth: auth, allowPrivateHTTP: discovery.endpoint.allowPrivateHTTP)
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration, !Task.isCancelled else { return }
                guard workspace.isConnected else { errorMessage = workspace.status; return }
                let host: BighelpConfiguredHost
                if let existing = hostToAuthenticate {
                    host = try registry.acceptAuthentication(for: existing, workspace: workspace)
                } else {
                    host = try registry.commit(pendingID, workspace: workspace, name: name)
                }
                connectedHost = host
                notifications = HostNotificationSetupModel(host: host, registry: registry)
                onConnectionCommitted?(host)
            } catch {
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration else { return }
                errorMessage = error is HostSetupError ? HostSetupError.alreadyConfigured.localizedDescription : DirectHermesConversationClient.safeMessage(error)
            }
        }
    }
    private func invalidateDiscovery() {
        cancel()
        unstageAccess()
        if hostToAuthenticate == nil, connectedHost == nil, let pendingID {
            registry.discardPending(pendingID)
            self.pendingID = nil
            workspace = nil
        }
        discovery = nil; token = ""; password = ""; errorMessage = nil
    }
    private func cancel() {
        requestID = UUID(); browserTransactionID = nil; task?.cancel(); task = nil; isWorking = false
        if connectedHost == nil { workspace?.suspendForPresentationExit() }
        token = ""; password = ""
    }
    private func finish() {
        notifications?.cancel()
        cancel()
        unstageAccess()
        onFinished?()
        registry.finishSetup()
        dismiss()
    }

    @ViewBuilder
    private var cloudflareAccessFields: some View {
        Toggle("Cloudflare Access", isOn: $usesCloudflareAccess)
            .accessibilityIdentifier("host-setup.cloudflare-access")
        if usesCloudflareAccess {
            TextField("Client ID", text: $accessClientID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
                .accessibilityIdentifier("host-setup.cloudflare-client-id")
            SecureField("Client secret", text: $accessClientSecret)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("host-setup.cloudflare-client-secret")
        }
        Text("For a host behind Cloudflare Access, such as a Cloudflare Tunnel. Create a service token in Cloudflare Zero Trust and allow it with a Service Auth policy. bighelp sends it only to this address and keeps it in Keychain.")
            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
    }

    @ViewBuilder
    private var proxyPasswordFields: some View {
        Toggle("Username and password", isOn: Binding(
            get: { usesProxyPassword || needsProxyPassword },
            set: { on in
                usesProxyPassword = on
                if !on { needsProxyPassword = false }
            }))
            .accessibilityIdentifier("host-setup.proxy-password")
        if usesProxyPassword || needsProxyPassword {
            TextField("Username", text: $proxyUsername)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
                .accessibilityIdentifier("host-setup.proxy-username")
            SecureField("Password", text: $proxyPassword)
                .textContentType(.password)
                .privacySensitive()
                .accessibilityIdentifier("host-setup.proxy-password-field")
        }
        Text("For a Hermes address behind a proxy that asks for a username and password, like basic auth on nginx, Caddy or Traefik. bighelp sends them only to this address and keeps them in Keychain.")
            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
    }

    /// Requests during setup use the entered credentials; they're saved once the
    /// connection works. Returns whether a proxy password is being sent.
    @discardableResult
    private func stageAccess(for endpoint: DirectHermesEndpoint) throws -> Bool {
        let store = DirectHermesAccessCredentialStore.shared
        guard hostToAuthenticate == nil else {
            store.stage(nil, for: endpoint)
            return false
        }
        if usesProxyPassword || needsProxyPassword, !proxyUsername.isEmpty, !proxyPassword.isEmpty {
            guard let credentials = try? DirectHermesAccessCredentials(username: proxyUsername, password: proxyPassword)
            else { throw HostSetupAccessError.invalidProxyCredentials }
            // Never to a plain-HTTP address on the open internet.
            guard credentials.canSend(to: endpoint) else { throw HostSetupAccessError.blockedBeforeSignIn }
            store.stage(credentials, for: endpoint)
            return true
        }
        guard usesCloudflareAccess else {
            store.stage(nil, for: endpoint)
            return false
        }
        guard endpoint.baseURL.scheme == "https" else { throw HostSetupAccessError.needsHTTPS }
        store.stage(try DirectHermesAccessCredentials(clientID: accessClientID, clientSecret: accessClientSecret),
                    for: endpoint)
        return false
    }

    /// An abandoned setup never leaves a token in use; a connected host already saved it.
    private func unstageAccess() {
        guard connectedHost == nil, let endpoint = discovery?.endpoint else { return }
        DirectHermesAccessCredentialStore.shared.stage(nil, for: endpoint)
    }

    private func saveRetainedDraft() {
        retainedDraft?.wrappedValue = HostSetupDraft(
            address: address,
            port: port,
            name: name,
            allowPrivateHTTP: allowPrivateHTTP
        )
    }
}

@MainActor
struct HostNotificationSetupSection: View {
    let model: HostNotificationSetupModel
    var hostName: String? = nil
    var hostEndpoint: String? = nil
    var onCompletion: @MainActor () async -> Void = {}
    @State private var showsReview = false

    var body: some View {
        Section {
            if let hostName {
                LabeledContent("Computer", value: hostName)
                    .accessibilityIdentifier("host-setup.notification-host")
            }
            if let hostEndpoint {
                DisclosureGroup("Connection Details") {
                    Text(hostEndpoint).bighelpFont(.code).textSelection(.enabled)
                }
                .accessibilityIdentifier("host-setup.notification-host-address")
            }
            if model.state != .notConfigured && model.state != .enabled && !model.isWorking {
                BighelpInlineNotice(message: model.message,
                                   tone: model.providerFailure == nil ? .warning : .danger)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("host-setup.notification-status")
            }
            if model.isWorking {
                ProgressView(model.state == .installing ? "Installing the plugin…" : "Checking notification setup…")
                    .accessibilityIdentifier("host-setup.notification-progress")
            } else if model.state == .enabled {
                Label("Notifications Enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("host-setup.notification-enabled")
            } else if showsReview {
                Text("Get alerts for replies, tasks, questions, and approvals.")
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = model.actionTitle {
                    Button(actionTitle) {
                        Task {
                            await model.enable()
                            await onCompletion()
                        }
                    }
                    .accessibilityIdentifier("host-setup.install-plugin")
                }
                Button("Not Now", role: .cancel) { showsReview = false }
                    .accessibilityIdentifier("host-setup.notifications-not-now")
            } else {
                Button(notificationReviewTitle) { showsReview = true }
                    .accessibilityIdentifier("host-setup.enable-notifications")
            }
        } header: {
            Text("Notifications")
        }
    }

    private var notificationReviewTitle: String {
        switch model.state {
        case .notConfigured: "Enable Notifications"
        case .verificationRequired, .backendRestartRequired, .outcomeUnknown: "Check Again"
        default: "Try Again"
        }
    }
}
