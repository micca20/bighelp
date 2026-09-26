import SwiftUI

@MainActor
struct HostOperationsView: View {
    @Bindable var store: HostOperationsStore

    @State private var gatewayCommand: HermesMessagingGatewayCommand?
    @State private var drainTarget: Bool?
    @State private var confirmsMigration = false
    @State private var confirmsUpdate = false

    var body: some View {
        List {
            scopeSection
            messageSections

            if let overview = store.overview {
                gatewaySection(overview)
                runtimeSection(overview)
            } else if store.isLoading {
                Section { ProgressView("Loading host status…") }
            }

            destinationsSection
            updateSection
            actionSection
            unavailableSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Host Operations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { if store.overview == nil { await store.load() } }
        .confirmationDialog(
            gatewayCommand.map { "\(gatewayTitle($0)) the messaging gateway?" } ?? "Messaging gateway action",
            isPresented: Binding(
                get: { gatewayCommand != nil },
                set: { if !$0 { gatewayCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let command = gatewayCommand {
                Button(gatewayTitle(command), role: command == .stop ? .destructive : nil) {
                    gatewayCommand = nil
                    Task { await store.launchGateway(command) }
                }
            }
            Button("Cancel", role: .cancel) { gatewayCommand = nil }
        } message: {
            Text(gatewayConfirmationMessage)
        }
        .confirmationDialog(
            drainTarget == true ? "Drain the messaging gateway?" : "Cancel messaging-gateway drain?",
            isPresented: Binding(
                get: { drainTarget != nil },
                set: { if !$0 { drainTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let draining = drainTarget {
                Button(draining ? "Begin Drain" : "Cancel Drain") {
                    drainTarget = nil
                    Task { await store.setGatewayDraining(draining) }
                }
            }
            Button("Cancel", role: .cancel) { drainTarget = nil }
        } message: {
            Text(drainTarget == true
                 ? "Hermes will stop accepting new messaging turns while allowing in-flight work to finish. This does not stop or restart hermes serve."
                 : "Hermes will clear the external drain marker and allow the messaging gateway to accept new work again.")
        }
        .confirmationDialog(
            "Migrate messaging gateways?",
            isPresented: $confirmsMigration,
            titleVisibility: .visible
        ) {
            Button("Run Reviewed Migration") { Task { await store.migrateGateway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will re-check the displayed plan, then consolidate eligible per-profile messaging gateways into its supported multiplexer. The plan must be unchanged and unblocked.")
        }
        .confirmationDialog(
            "Apply the reviewed Hermes update?",
            isPresented: $confirmsUpdate,
            titleVisibility: .visible
        ) {
            Button("Apply Update") { Task { await store.applyReviewedUpdate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will re-check update eligibility, then run its in-place updater. The update may restart messaging gateways and interrupt this connection. bighelp will never replay the request automatically.")
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: { Text("Workspace") } footer: {
            Text("These controls operate the selected host’s messaging gateway and host services. They do not restart the hermes serve process carrying this connection.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    private func gatewaySection(_ overview: HermesHostOverview) -> some View {
        Section {
            HStack {
                Label(
                    overview.gatewayRunning ? "Running" : "Stopped",
                    systemImage: overview.gatewayRunning ? "antenna.radiowaves.left.and.right" : "stop.circle"
                )
                Spacer()
                Text(overview.gatewayState.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Mode", value: overview.gatewayMode.capitalized)
            LabeledContent("Active agents", value: overview.activeAgents.formatted())
            LabeledContent("Active sessions", value: overview.activeSessions.formatted())
            if !overview.gatewaySharedWith.isEmpty {
                LabeledContent("Serving profiles", value: overview.gatewaySharedWith.joined(separator: ", "))
            }

            if overview.gatewayRunning {
                Button("Restart Messaging Gateway", systemImage: "arrow.clockwise") {
                    gatewayCommand = .restart
                }
                .disabled(!store.canAct)

                Button("Stop Messaging Gateway", systemImage: "stop.fill", role: .destructive) {
                    gatewayCommand = .stop
                }
                .disabled(!store.canAct || overview.gatewayBusy)
            } else {
                Button("Start Messaging Gateway", systemImage: "play.fill") {
                    gatewayCommand = .start
                }
                .disabled(!store.canAct)
            }

            if overview.gatewayState == "draining" {
                Button("Cancel Gateway Drain", systemImage: "arrow.uturn.backward") {
                    drainTarget = false
                }
                .disabled(!store.canAct)
            } else if overview.gatewayDrainable {
                Button("Drain New Messaging Work", systemImage: "hourglass") {
                    drainTarget = true
                }
                .disabled(!store.canAct)
            }

            if let plan = store.migrationPlan {
                DisclosureGroup("Multiplexer migration plan") {
                    LabeledContent("Profiles", value: plan.profiles.count.formatted())
                    LabeledContent("Already multiplexed", value: plan.alreadyMultiplexed ? "Yes" : "No")
                    LabeledContent("Eligible", value: plan.isEligible ? "Yes" : "No")
                    ForEach(plan.profiles) { profile in
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(profile.id).font(.subheadline)
                            Text([
                                profile.hasRunningProcess ? "Running process" : "No running process",
                                profile.serviceKind,
                            ].compactMap { $0 }.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(plan.notices, id: \.self) { notice in
                        Label(notice, systemImage: "info.circle")
                    }
                    ForEach(plan.blockers, id: \.self) { blocker in
                        Label(blocker, systemImage: "exclamationmark.octagon")
                            .foregroundStyle(.orange)
                    }
                    if plan.isEligible && plan.blockers.isEmpty && !plan.alreadyMultiplexed {
                        Button("Run Reviewed Migration") { confirmsMigration = true }
                            .disabled(!store.canAct)
                    }
                }
            }
        } header: {
            Text("Messaging gateway")
        } footer: {
            Text(overview.gatewayBusy
                 ? "Hermes reports active work. Stop is disabled; use drain to stop new turns without interrupting in-flight work."
                 : "Lifecycle requests return background-action receipts. Completion and the resulting runtime state are read back separately.")
        }
    }

    private func runtimeSection(_ overview: HermesHostOverview) -> some View {
        Section("Host status") {
            LabeledContent("Hermes", value: overview.version)
            LabeledContent("Overall", value: overview.overall.capitalized)
            ForEach(overview.components) { component in
                LabeledContent(component.id.replacingOccurrences(of: "_", with: " ").capitalized,
                               value: component.status.capitalized)
            }
        }
    }

    private var destinationsSection: some View {
        Section("Advanced") {
            NavigationLink {
                HostDiagnosticsView(store: store)
            } label: {
                Label("Diagnostics & Egress", systemImage: "stethoscope")
            }
            NavigationLink {
                HostBackupView(store: store)
            } label: {
                Label("Backups & Checkpoints", systemImage: "externaldrive")
            }
            NavigationLink {
                HostImportView(store: store)
            } label: {
                Label("Import Backup", systemImage: "externaldrive.badge.arrow.down")
            }
            NavigationLink {
                HostHooksView(store: store)
            } label: {
                Label("Shell Hooks", systemImage: "terminal")
            }
            NavigationLink {
                RawConfigurationView(store: store.rawConfiguration)
            } label: {
                Label("Raw Configuration", systemImage: "lock.doc")
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        Section {
            if let check = store.updateCheck {
                LabeledContent("Installed version", value: check.currentVersion)
                LabeledContent("Install method", value: check.installMethod)
                if let behind = check.commitsBehind {
                    LabeledContent("Commits behind", value: behind < 0 ? "Unknown" : behind.formatted())
                }
                if let message = check.message, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(check.commits.prefix(20)) { commit in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(commit.summary).font(.subheadline)
                        Text(String(commit.sha.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if check.updateAvailable && check.canApply {
                    Button("Review & Apply Update", systemImage: "arrow.down.circle") {
                        confirmsUpdate = true
                    }
                    .disabled(!store.canAct)
                } else if check.updateAvailable {
                    Text("This install cannot be updated in place from bighelp. Follow the host’s managed update channel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Check Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await store.checkForUpdates(force: true) }
            }
            .disabled(!store.canAct)

            if let receipt = store.updateReceipt {
                DisclosureGroup("Latest update receipt") {
                    LabeledContent("Outcome", value: receipt.summary.outcome.capitalized)
                    if let version = receipt.summary.postUpdateVersion {
                        LabeledContent("Result version", value: version)
                    }
                    if let finished = receipt.summary.finishedAt {
                        LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .shortened))
                    }
                    ForEach(receipt.steps.prefix(100)) { step in
                        Label(step.name, systemImage: step.succeeded ? "checkmark.circle" : "xmark.circle")
                    }
                    ForEach(receipt.fleet.prefix(50)) { member in
                        LabeledContent(member.profile, value: member.state.capitalized)
                    }
                }
            }
        } header: {
            Text("Advanced · Hermes update")
        } footer: {
            Text("A successful launch is not an update result. bighelp uses the durable structured receipt and action identity when Hermes provides them.")
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if !store.actionReceipts.isEmpty {
            Section("Background actions") {
                ForEach(store.actionReceipts) { receipt in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Text(receipt.action.rawValue).font(.headline)
                            Spacer()
                            statusLabel(store.actionStatuses[receipt.id])
                        }
                        Text(correlationText(store.actionStatuses[receipt.id], receipt: receipt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh Status") { Task { await store.pollAction(receipt) } }
                                .buttonStyle(.bordered)
                            Button("Dismiss") { store.dismissAction(receipt) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        }
    }

    @ViewBuilder
    private var unavailableSection: some View {
        if !store.unavailableFeatures.isEmpty {
            Section {
                ForEach(store.unavailableFeatures, id: \.self) { feature in
                    Label(feature, systemImage: "nosign")
                }
            } header: {
                Text("Unavailable on this host")
            } footer: {
                Text("bighelp did not emulate these host APIs through files, shell commands, private hooks, or a local success state.")
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: HermesHostActionStatus?) -> some View {
        switch status?.phase {
        case .running, nil:
            Label("Pending", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .succeeded:
            Label("Completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        case .outcomeUnknown:
            Label("Unknown", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func correlationText(
        _ status: HermesHostActionStatus?,
        receipt: HermesHostActionReceipt
    ) -> String {
        switch status?.correlation {
        case .exactActionID: "Matched the host’s durable action ID."
        case .matchingProcess: "Matched the host process receipt."
        case .actionSlotOnly: "Status is for the named host action slot; this receipt has no per-run identity."
        case .pendingIdentity: "Hermes has not yet returned durable identity for this admitted action."
        case nil: receipt.admission == .actionSlotOnly
            ? "Waiting on the named host action slot."
            : "Waiting for Hermes to report action status."
        }
    }

    private func gatewayTitle(_ command: HermesMessagingGatewayCommand) -> String {
        switch command {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }

    private var gatewayConfirmationMessage: String {
        guard let command = gatewayCommand else { return "" }
        return switch command {
        case .start:
            "Hermes will start the selected profile’s messaging gateway. This does not start or restart hermes serve."
        case .stop:
            "Hermes will stop the selected profile’s messaging gateway. Messaging delivery will stop, but hermes serve is a separate process and is not controlled here."
        case .restart:
            "Hermes will restart the selected profile’s messaging gateway. The current connection may be interrupted; bighelp will read status after reconnect and will not resend the restart."
        }
    }
}
