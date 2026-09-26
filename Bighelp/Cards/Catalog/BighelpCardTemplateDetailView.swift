import SwiftUI

struct BighelpCardTemplateDetailView: View {
    let entry: BighelpCardCatalogEntry
    let installedVersion: Int?
    let installAction: @MainActor () async throws -> Void
    let removeAction: @MainActor () async throws -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        entry: BighelpCardCatalogEntry,
        installedVersion: Int?,
        installAction: @escaping @MainActor () async throws -> Void,
        removeAction: @escaping @MainActor () async throws -> Void
    ) {
        self.entry = entry
        self.installedVersion = installedVersion
        self.installAction = installAction
        self.removeAction = removeAction
    }

    var body: some View {
        List {
            Section { header }
            Section("Card preview") { previewContent }
            Section("Data access") { permissionsContent }
            Section("About this template") { provenanceContent }
            Section("Install") { action }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("catalog.detail.\(entry.id)")
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t update this template", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.summary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewContent: some View {
        BighelpCardRenderer(card: entry.document)
            .padding(.vertical, 8)
            .accessibilityIdentifier("catalog.preview.\(entry.id)")
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entry.dataSourceDisclosures) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Label(source.host, systemImage: "globe")
                        .font(.headline)
                    Text(refreshDescription(source.minimumIntervalSeconds))
                    Text("Marks data stale after \(durationDescription(source.staleAfterSeconds))")
                    Text(expirationDescription(source.expiresAt))
                }
            }
            if entry.dataSourceDisclosures.isEmpty {
                Text("No external data sources")
            }
            Divider()
            Text("Requested components")
                .font(.headline)
            ForEach(entry.requestedComponentTypes, id: \.self) { component in
                Text(component)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(permissionAccessibilityLabel)
        .accessibilityIdentifier("catalog.permissions.\(entry.id)")
    }

    private var provenanceContent: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Author").foregroundStyle(.secondary)
                Text(entry.author)
            }
            GridRow {
                Text("License").foregroundStyle(.secondary)
                Text(entry.license)
            }
            GridRow {
                Text("Version").foregroundStyle(.secondary)
                Text("Version \(entry.version)")
            }
            GridRow {
                Text("Card format").foregroundStyle(.secondary)
                Text("Version \(entry.minimumCardVersion)")
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if isWorking {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Updating template")
        } else if let installedVersion {
            VStack(spacing: 12) {
                if installedVersion < entry.version {
                    Button { perform(installAction) } label: {
                        Text("Update \(entry.name)")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                        .bighelpProminentButtonStyle()
                        .accessibilityIdentifier("catalog.update.\(entry.id)")
                }
                Button(role: .destructive) { perform(removeAction) } label: {
                    Text("Remove \(entry.name)")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("catalog.remove.\(entry.id)")
            }
        } else {
            Button { perform(installAction) } label: {
                Text("Install \(entry.name)")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
                .bighelpProminentButtonStyle()
                .accessibilityIdentifier("catalog.install.\(entry.id)")
        }
    }


    private var permissionAccessibilityLabel: String {
        let sources = entry.dataSourceDisclosures.map { source in
            "\(source.host), \(refreshDescription(source.minimumIntervalSeconds)), \(expirationDescription(source.expiresAt))"
        }
        return (sources + ["Requested components: \(entry.requestedComponentTypes.joined(separator: ", "))"])
            .joined(separator: ". ")
    }

    private func refreshDescription(_ seconds: Int) -> String {
        if seconds.isMultiple(of: 3600) {
            let hours = seconds / 3600
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        }
        return "Every \(seconds) seconds"
    }

    private func durationDescription(_ seconds: Int) -> String {
        if seconds.isMultiple(of: 3600) {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }

    private func expirationDescription(_ rawValue: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: rawValue) else {
            return "Stops refreshing at the template expiration time"
        }
        return "Stops refreshing after \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
