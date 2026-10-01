import SwiftUI
import UniformTypeIdentifiers

/// ☰ › Secure credential vault: what an agent's browser can sign in with.
/// Lists only labels; secrets are typed here once and go straight to Hermes.
struct CredentialVaultView: View {
    @Bindable var model: CredentialVaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false
    @State private var unlocking: CredentialVaultSource?
    @State private var removing: CredentialVaultItem?
    @State private var isPickingFile = false
    @State private var found: FoundLogins?

    /// A read export, held only while its preview sheet is open.
    struct FoundLogins: Identifiable {
        let id = UUID()
        let file: CredentialVaultImport
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Logins, cards and addresses your agent can use in its browser. They're kept on your computer, your agent never sees the passwords, and bighelp doesn't keep them.")
                        .foregroundStyle(.secondary)
                    if model.agents.count > 1 {
                        Picker("Agent", selection: Binding(get: { model.agentID },
                                                           set: { id in Task { await model.select(agentID: id) } })) {
                            ForEach(model.agents) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("vault.agent")
                    }
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("vault.message")
                }
                switch model.state {
                case .loading:
                    Section { ProgressView("Opening the vault…") }
                case .unsupported:
                    Section {
                        Text("This needs a newer Hermes on your computer. Update Hermes, then come back.")
                            .accessibilityIdentifier("vault.unsupported")
                    }
                case .failed:
                    Section {
                        Text("The vault didn't answer. Check your connection to your computer.")
                        Button("Try again") { Task { await model.load() } }
                            .foregroundStyle(.tint)
                    }
                case .ready:
                    savedSection
                    managersSection
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Credential vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("vault.done")
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add")
                        .accessibilityIdentifier("vault.add")
                        .disabled(model.state != .ready)
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(isPresented: $isAdding) { CredentialVaultAddView(model: model).bighelpSheetSize(.standard) }
            .sheet(item: $unlocking) { source in
                CredentialVaultUnlockView(model: model, source: source).bighelpSheetSize(.compact)
            }
            .sheet(item: $found) { CredentialVaultImportView(model: model, file: $0.file).bighelpSheetSize(.standard) }
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                if case .success(let url) = result { read(url) }
            }
            .confirmationDialog("Remove \(removing?.label ?? "this")?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let item = removing { Task { await model.remove(item) } }
                    removing = nil
                }
            } message: {
                Text("Your agent won't be able to use it anymore.")
            }
        }
    }

    private var savedSection: some View {
        Section {
            if model.items.isEmpty {
                Text("Nothing saved for \(model.agentName) yet. \(BighelpPlatform.isMac ? "Click" : "Tap") + to add a login, card or address.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vault.empty")
            }
            ForEach(model.items) { item in
                row(item)
                    .swipeActions {
                        if item.isLocal {
                            Button("Remove", role: .destructive) { removing = item }
                        }
                    }
                    .contextMenu {
                        if item.isLocal {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = item }
                        }
                    }
            }
            Button {
                #if DEBUG
                if let fixture = CredentialVaultImport.testFixture {
                    found = (try? CredentialVaultImport.read(fixture)).map { FoundLogins(file: $0) }
                    return
                }
                #endif
                isPickingFile = true
            } label: {
                Label("Import logins from a file", systemImage: "square.and.arrow.down")
            }
            .foregroundStyle(.tint)
            .accessibilityIdentifier("vault.import")
        } header: {
            Text("Saved for \(model.agentName)")
        } footer: {
            Text("Import a CSV export from Apple Passwords, Chrome, 1Password, Bitwarden, LastPass, Firefox and most other password managers.")
        }
    }

    /// Reads the export where it is, in memory; it's never copied into bighelp.
    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CredentialVaultImport.maximumBytes else { throw CredentialVaultImport.Problem.tooLarge }
            found = FoundLogins(file: try CredentialVaultImport.read(Data(contentsOf: url, options: .uncached)))
            model.message = nil
        } catch let problem as CredentialVaultImport.Problem {
            model.message = problem.message
        } catch {
            model.message = "That file couldn't be opened. If it's in iCloud Drive, download it first."
        }
    }

    private func row(_ item: CredentialVaultItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                let detail = [item.identifier, item.kind == .login ? host(item.origin) : nil,
                              item.generatesCodes ? "Makes its own codes" : nil,
                              item.isLocal ? nil : "From \(sourceName(item.source))"]
                    .compactMap { $0 }.filter { !$0.isEmpty && $0 != item.label }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).bighelpFont(.metadata).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.kind.symbol)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vault.item.\(item.id)")
    }

    @ViewBuilder
    private var managersSection: some View {
        Section {
            ForEach(model.managers) { source in
                Toggle(isOn: Binding(get: { source.enabled },
                                     set: { on in Task { await model.setEnabled(source, on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                        Text(!source.enabled ? "Off" : source.unlocked ? "Unlocked" : "Locked")
                            .bighelpFont(.metadata).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("vault.source.\(source.name)")
                if source.enabled {
                    if source.unlocked {
                        Button("Lock \(source.displayName)") { Task { await model.lock(source) } }
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("vault.lock.\(source.name)")
                    } else {
                        Button("Unlock \(source.displayName)") { unlocking = source }
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("vault.unlock.\(source.name)")
                    }
                }
            }
        } header: {
            Text("Password managers")
        } footer: {
            Text(model.managers.isEmpty
                 ? "1Password and Bitwarden show up here when their command-line tools are installed on your computer."
                 : "Your agent can use logins from an unlocked manager. It stays unlocked on your computer for 30 minutes after its last use.")
        }
    }

    private func host(_ origin: String?) -> String? {
        origin.flatMap { URLComponents(string: $0)?.host }
    }

    private func sourceName(_ name: String) -> String {
        model.sources.first { $0.name == name }?.displayName ?? name
    }
}

/// Adds one login, card or address. Secrets live only in this sheet's state
/// and are cleared when it closes or the app leaves the screen.
private struct CredentialVaultAddView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case login = "Login", card = "Card", address = "Address"
        var id: Self { self }
    }

    let model: CredentialVaultModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind = Kind.login
    @State private var site = ""
    @State private var identifier = ""
    @State private var password = ""
    @State private var authenticatorKey = ""
    @State private var showsAuthenticatorKey = false
    @State private var cardName = ""
    @State private var cardNumber = ""
    @State private var month = ""
    @State private var year = ""
    @State private var securityCode = ""
    @State private var postalCode = ""
    @State private var addressLabel = ""
    @State private var line1 = ""
    @State private var line2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var country = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("vault.kind")
                }
                switch kind {
                case .login: loginFields
                case .card: cardFields
                case .address: addressFields
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Add to vault")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clear(); dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("vault.save")
                }
            }
            .onAppear { model.message = nil }
            .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
            .onDisappear { clear() }
        }
    }

    private var loginFields: some View {
        Section {
            TextField("Website, like example.com", text: $site)
                .keyboardType(.URL)
                .textContentType(.URL)
                .accessibilityIdentifier("vault.site")
            TextField("Email or username", text: $identifier)
                .keyboardType(.emailAddress)
                .accessibilityIdentifier("vault.username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .privacySensitive()
                .accessibilityIdentifier("vault.password")
            // A separate step, and not a password field: AutoFill would otherwise
            // take two password fields in a row for "confirm password".
            if showsAuthenticatorKey {
                SecureField("Authenticator key", text: $authenticatorKey)
                    .textContentType(.oneTimeCode)
                    .privacySensitive()
                    .accessibilityIdentifier("vault.authenticator")
            } else {
                Button("Add an authenticator key") { showsAuthenticatorKey = true }
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("vault.add-authenticator")
            }
        } footer: {
            Text("Only that site can use this login. With an authenticator key (the setup code or otpauth link), Hermes makes the site's one-time codes itself.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var cardFields: some View {
        Section {
            TextField("Name on card", text: $cardName)
                .textContentType(.name)
            SecureField("Card number", text: $cardNumber)
                .keyboardType(.numberPad)
                .privacySensitive()
                .accessibilityIdentifier("vault.card-number")
            HStack {
                TextField("MM", text: $month).keyboardType(.numberPad)
                TextField("YYYY", text: $year).keyboardType(.numberPad)
            }
            SecureField("Security code", text: $securityCode)
                .keyboardType(.numberPad)
                .privacySensitive()
            TextField("Billing postal code (optional)", text: $postalCode)
                .textContentType(.postalCode)
        } footer: {
            Text("Hermes asks you before it fills a card on any page.")
        }
        .autocorrectionDisabled()
    }

    private var addressFields: some View {
        Section {
            TextField("Name, like Home", text: $addressLabel)
            TextField("Street address", text: $line1).textContentType(.streetAddressLine1)
            TextField("Apartment, suite (optional)", text: $line2).textContentType(.streetAddressLine2)
            TextField("City", text: $city).textContentType(.addressCity)
            TextField("State or region (optional)", text: $state).textContentType(.addressState)
            TextField("Postal code", text: $postalCode).textContentType(.postalCode)
            TextField("Country", text: $country).textContentType(.countryName)
        }
        .privacySensitive()
    }

    private func save() {
        let entry: CredentialVaultEntry = switch kind {
        case .login:
            .login(site: site, identifier: identifier, password: password, authenticatorKey: authenticatorKey)
        case .card:
            .card(name: cardName, number: cardNumber, month: month, year: year, securityCode: securityCode,
                  postalCode: postalCode)
        case .address:
            .address(label: addressLabel, line1: line1, line2: line2, city: city, state: state,
                     postalCode: postalCode, country: country)
        }
        Task {
            guard await model.save(entry) else { return }
            clear()
            dismiss()
        }
    }

    private func clear() {
        password = ""
        authenticatorKey = ""
        cardNumber = ""
        securityCode = ""
    }
}

/// A password manager's master password, sent once to unlock it on the computer.
private struct CredentialVaultUnlockView: View {
    let model: CredentialVaultModel
    let source: CredentialVaultSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Master password", text: $password)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .submitLabel(.go)
                        .onSubmit(unlock)
                        .accessibilityIdentifier("vault.master-password")
                } footer: {
                    Text("Unlocks \(source.displayName) on your computer so your agent can use its logins. bighelp doesn't keep your master password.")
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Unlock \(source.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { password = ""; dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: unlock)
                        .disabled(password.isEmpty || model.isWorking)
                        .accessibilityIdentifier("vault.unlock-confirm")
                }
            }
            .onAppear { model.message = nil; focused = true }
            .onChange(of: scenePhase) { _, phase in if phase != .active { password = "" } }
            .onDisappear { password = "" }
        }
    }

    private func unlock() {
        let typed = password
        password = ""
        guard !typed.isEmpty else { return }
        Task { if await model.unlock(source, password: typed) { dismiss() } }
    }
}

/// Presents the vault from the root, outside RootShellView's large body.
struct CredentialVaultSheet: ViewModifier {
    @Binding var model: CredentialVaultModel?

    func body(content: Content) -> some View {
        content.sheet(item: $model) { CredentialVaultView(model: $0).bighelpSheetSize(.standard) }
    }
}

extension RootShellView {
    /// Any host can open it; one without a vault says to update Hermes.
    var canOpenCredentialVault: Bool {
        hostRegistry?.selectedHost != nil || usesWorkspaceFixtures
    }

    func openCredentialVault() {
        let service: any CredentialVaultService
        if let workspace = hostRegistry?.selectedWorkspace {
            guard workspace.isConnected else {
                actionErrorMessage = "Connect to your computer to open the vault."
                return
            }
            service = DirectHermesCredentialVaultService(workspace: workspace)
        } else if usesWorkspaceFixtures {
            service = DemoCredentialVaultService()
        } else {
            return
        }
        var list = agents.profiles.map { CredentialVaultModel.Agent(id: $0.id, name: $0.name) }
        if list.isEmpty { list = [.init(id: "default", name: "Default agent")] }
        credentialVault = CredentialVaultModel(service: service, agents: list, agentID: homeAgent?.id ?? "default")
    }
}

/// What an export holds, before anything is sent: sites and usernames only.
private struct CredentialVaultImportView: View {
    let model: CredentialVaultModel
    let file: CredentialVaultImport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var result: (imported: Int, failed: Int)?

    var body: some View {
        let pending = file.excluding(model.items)
        NavigationStack {
            Form {
                if let result {
                    Section {
                        Label(result.imported == 1 ? "Imported 1 login." : "Imported \(result.imported) logins.",
                              systemImage: "checkmark.circle")
                            .accessibilityIdentifier("vault.import-done")
                        if result.failed > 0 {
                            Text(result.failed == 1 ? "1 login couldn't be saved." : "\(result.failed) logins couldn't be saved.")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Now delete the exported file. It has your passwords in plain text.")
                    }
                } else {
                    Section {
                        Text(summary(pending))
                            .accessibilityIdentifier("vault.import-summary")
                        if let progress = model.importProgress {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                                Text("Saving \(progress.done) of \(progress.total)…")
                            }
                        }
                    } footer: {
                        Text("Passwords go straight to the vault on your computer for \(model.agentName). bighelp doesn't keep them.")
                    }
                    if !pending.logins.isEmpty {
                        Section("Logins") {
                            ForEach(pending.logins.prefix(300)) { login in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(login.site)
                                    Text(login.identifier).bighelpFont(.metadata).foregroundStyle(.secondary)
                                }
                            }
                            if pending.logins.count > 300 {
                                Text("And \(pending.logins.count - 300) more").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Import logins")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isWorking)
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                            .bighelpToolbarText()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button("Done") { dismiss() }
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                            .accessibilityIdentifier("vault.import-close")
                    } else {
                        Button(pending.logins.count == 1 ? "Import 1" : "Import \(pending.logins.count)") {
                            Task { result = await model.importLogins(pending.logins) }
                        }
                        .disabled(pending.logins.isEmpty || model.isWorking)
                        .accessibilityIdentifier("vault.import-confirm")
                    }
                }
            }
            // The export's passwords leave memory with this sheet.
            .onChange(of: scenePhase) { _, phase in if phase == .background, !model.isWorking { dismiss() } }
        }
    }

    private func summary(_ pending: (logins: [CredentialVaultImport.Login], alreadySaved: Int)) -> String {
        var parts = [pending.logins.count == 1 ? "Found 1 login to import." : "Found \(pending.logins.count) logins to import."]
        if pending.alreadySaved > 0 {
            parts.append(pending.alreadySaved == 1 ? "1 is already saved." : "\(pending.alreadySaved) are already saved.")
        }
        if file.skipped > 0 {
            parts.append(file.skipped == 1 ? "1 row was skipped: it has no website, username or password."
                         : "\(file.skipped) rows were skipped: they have no website, username or password.")
        }
        return parts.joined(separator: " ")
    }
}
