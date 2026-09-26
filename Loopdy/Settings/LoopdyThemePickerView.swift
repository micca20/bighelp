import SwiftUI

@MainActor
struct ThemeSelectionLink: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        NavigationLink {
            AppearanceStudioView(settings: settings)
        } label: {
            HStack(spacing: LoopdyTokens.space12) {
                ZStack {
                    Circle().fill(theme.canvas).overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                    Circle().fill(theme.action).padding(9)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colors")
                        .foregroundStyle(theme.primaryText)
                    Text(summary)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(minHeight: LoopdyTokens.hitTarget)
        }
        .accessibilityValue(summary)
        .accessibilityIdentifier("settings.themes")
    }

    /// "Lavender bubbles · Cream · Graphite"
    private var summary: String {
        let bubbles = settings.bubbleColor?.name ?? (settings.themeID == .loopdy ? "Lavender" : selectedThemeDefinition.name)
        return "\(bubbles) bubbles · \(settings.lightBackground.name) · \(settings.darkBackground.name)"
    }

    private var selectedThemeDefinition: LoopdyThemeDefinition {
        settings.selectedCustomTheme?.definition
            ?? LoopdyThemeRegistry.definition(for: settings.themeID)
            ?? LoopdyThemeRegistry.builtIns[0]
    }

    @LoopdyThemeReader private var theme

}

@MainActor
struct LoopdyThemePickerView: View {
    @Bindable var settings: SettingsStore
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument: CustomThemeCatalogDocument?
    @State private var isPortableExporterPresented = false
    @State private var portableExportDocument: CustomThemePortableDocument?
    @State private var portableExportFilename = "loopdy-theme.loopdy-theme.json"
    @State private var transferError: String?

    var body: some View {
        Form {
            Section {
                Text("Choose the accent for outgoing messages and actions. Outgoing messages stay white and bighelp adjusts only their fill for contrast. The rest of bighelp stays adaptive and neutral.")
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(theme.surface)

            Section("Built-in accents") {
                ForEach(LoopdyThemeRegistry.builtIns) { definition in
                    Button {
                        settings.themeID = definition.id
                        // A theme picked here brings its own accent.
                        settings.bubbleColor = nil
                    } label: {
                        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                            accentChoiceRow(
                                definition: definition,
                                isSelected: settings.themeID == definition.id
                            )
                            ThemePreview(definition: definition)
                        }
                        .padding(.vertical, LoopdyTokens.space4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(definition.name) accent theme")
                    .accessibilityValue(settings.themeID == definition.id ? "Selected" : "Not selected")
                    .accessibilityIdentifier("settings.theme.\(definition.id.rawValue)")
                }
            }
            .listRowBackground(theme.surface)

            CustomThemeSection(
                settings: settings,
                theme: theme,
                onExport: exportPortableTheme
            )
        }
        .loopdyFormSurface()
        .environment(\.defaultMinListRowHeight, LoopdyTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Accent Themes")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.theme-picker")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import themes", systemImage: "square.and.arrow.down") {
                    isImporterPresented = true
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("settings.custom-theme.import")
                Button("Export theme collection", systemImage: "square.and.arrow.up") {
                    exportDocument = CustomThemeCatalogDocument(
                        catalog: CustomThemeCatalog(themes: settings.customThemes)
                    )
                    isExporterPresented = true
                }
                .labelStyle(.iconOnly)
                .disabled(settings.customThemes.isEmpty)
                .accessibilityIdentifier("settings.custom-theme.export")
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let data = try Data(contentsOf: url)
                try settings.importCustomThemeFile(data)
            } catch { transferError = "Import failed. Choose a valid bighelp theme JSON file." }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "loopdy-custom-themes.json"
        ) { result in
            if case .failure = result { transferError = "Export failed. Try again." }
        }
        .fileExporter(
            isPresented: $isPortableExporterPresented,
            document: portableExportDocument,
            contentType: .json,
            defaultFilename: portableExportFilename
        ) { result in
            if case .failure = result { transferError = "Portable theme export failed. Try again." }
        }
        .alert("Theme transfer", isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })) {
            Button("OK", role: .cancel) { transferError = nil }
        } message: { Text(transferError ?? "") }
    }

    private func accentChoiceRow(
        definition: LoopdyThemeDefinition,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: LoopdyTokens.space12) {
            ThemeSwatch(themeID: definition.id, size: 38)
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text(definition.name)
                    .loopdyFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("Outgoing messages, links, and actions")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: LoopdyTokens.space8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func exportPortableTheme(_ custom: CustomTheme) {
        do {
            let data = try PortableCustomThemePackage.artifactData(
                theme: custom,
                lightLogoData: try settings.customLogoData(for: custom.id, variant: .light),
                darkLogoData: try settings.customLogoData(for: custom.id, variant: .dark)
            )
            let base = custom.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            portableExportDocument = CustomThemePortableDocument(data: data)
            portableExportFilename = "\(base.isEmpty ? "loopdy-theme" : base).loopdy-theme.json"
            isPortableExporterPresented = true
            transferError = nil
        } catch {
            transferError = "Portable theme export failed. Check its saved logos and try again."
        }
    }

    @LoopdyThemeReader private var theme

}

private struct CustomThemeSection: View {
    @Bindable var settings: SettingsStore
    let theme: LoopdyTheme
    let onExport: (CustomTheme) -> Void
    @State private var editingThemeID: UUID?
    @State private var pendingDeleteTheme: CustomTheme?
    @State private var actionError: String?

    var body: some View {
        Section {
            if settings.customThemes.isEmpty {
                Text("No custom themes")
                    .foregroundStyle(theme.secondaryText)
            }

            ForEach(settings.customThemes) { custom in
                VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                    HStack(spacing: LoopdyTokens.space8) {
                        Button {
                            settings.themeID = custom.themeID
                            settings.bubbleColor = nil
                        } label: {
                            customThemeChoice(
                                custom,
                                isSelected: settings.themeID == custom.themeID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(custom.name) custom accent theme")
                        .accessibilityValue(settings.themeID == custom.themeID ? "Selected" : "Not selected")
                        .accessibilityHint("Selects this accent. Use Theme actions to edit, export, duplicate, or delete it.")
                        .accessibilityIdentifier("settings.custom-theme.\(custom.id.uuidString)")

                        Menu("Theme actions", systemImage: "ellipsis.circle") {
                            customThemeActions(custom)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Actions for \(custom.name)")
                        .accessibilityIdentifier("settings.custom-theme.\(custom.id.uuidString).actions")
                    }

                    ThemePreview(definition: custom.definition)
                        .allowsHitTesting(false)
                }
                .padding(.vertical, LoopdyTokens.space4)
                .contextMenu {
                    customThemeActions(custom)
                }
            }

            if settings.availableCustomThemeSlots > 0 {
                NavigationLink {
                    CustomThemeEditorView(settings: settings)
                } label: {
                    Label("New custom theme", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.custom-theme.new")
            }
        } header: {
            Text("Custom accents")
        } footer: {
            Text("Selecting a custom theme applies its accent only. Its stored font, light and dark palette fields, and logos remain editable and are preserved in collection and portable exports.")
        }
        .listRowBackground(theme.surface)
        .navigationDestination(item: $editingThemeID) { themeID in
            if let custom = settings.customThemes.first(where: { $0.id == themeID }) {
                CustomThemeEditorView(settings: settings, existing: custom)
            } else {
                ContentUnavailableView("Theme unavailable", systemImage: "paintpalette")
            }
        }

        .confirmationDialog(
            "Delete \(pendingDeleteTheme?.name ?? "custom theme")?",
            isPresented: Binding(
                get: { pendingDeleteTheme != nil },
                set: { if !$0 { pendingDeleteTheme = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Theme", role: .destructive) {
                deletePendingTheme()
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteTheme = nil
            }
        } message: {
            Text("This removes the theme and its local logos from this device.")
        }
        .alert(
            "Custom theme",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func customThemeChoice(
        _ custom: CustomTheme,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: LoopdyTokens.space12) {
            ThemeSwatch(themeID: custom.themeID, customTheme: custom, size: 38)
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text(custom.name)
                    .loopdyFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("Outgoing messages, links, and actions")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: LoopdyTokens.space8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func customThemeActions(_ custom: CustomTheme) -> some View {
        Button("Edit", systemImage: "pencil") {
            editingThemeID = custom.id
        }
        Button("Export Theme File", systemImage: "square.and.arrow.up") {
            onExport(custom)
        }
        .accessibilityIdentifier("settings.custom-theme.portable-export.\(custom.id.uuidString)")
        Button("Duplicate", systemImage: "plus.square.on.square") {
            duplicate(custom)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDeleteTheme = custom
        }
    }

    private func duplicate(_ custom: CustomTheme) {
        do {
            _ = try settings.duplicateCustomTheme(id: custom.id)
            actionError = nil
        } catch {
            actionError = "The custom theme could not be duplicated."
        }
    }

    private func deletePendingTheme() {
        guard let custom = pendingDeleteTheme else { return }
        pendingDeleteTheme = nil
        do {
            try settings.deleteCustomTheme(id: custom.id)
            actionError = nil
        } catch {
            actionError = "The custom theme could not be deleted."
        }
    }


}
