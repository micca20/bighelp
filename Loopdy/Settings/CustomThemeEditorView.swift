import SwiftUI
import UIKit

@MainActor
struct CustomThemeEditorView: View {
    @Environment(\.appAppearance) private var appAppearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Bindable var settings: SettingsStore
    let existing: CustomTheme?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var themeDescription: String
    @State private var font: CustomThemeFontChoice
    @State private var accent: String
    @State private var lightBackground: String
    @State private var lightPrimary: String
    @State private var lightSecondary: String
    @State private var lightTertiary: String
    @State private var darkBackground: String
    @State private var darkPrimary: String
    @State private var darkSecondary: String
    @State private var darkTertiary: String
    @State private var error: String?
    @State private var isLogoImporterPresented = false
    @State private var logoImportVariant: CustomThemeLogoVariant = .light
    @State private var previewMode: CustomThemeLogoVariant = .light

    init(settings: SettingsStore, existing: CustomTheme? = nil) {
        self.settings = settings
        self.existing = existing
        let light = existing?.light ?? CustomThemePalette(backgroundHex: "FFFFFF", primaryTextHex: "111111", secondaryTextHex: "333333", tertiaryTextHex: "555555")
        let dark = existing?.dark ?? CustomThemePalette(backgroundHex: "101010", primaryTextHex: "FFFFFF", secondaryTextHex: "E0E0E0", tertiaryTextHex: "B0B0B0")
        _name = State(initialValue: existing?.name ?? "My Theme")
        _themeDescription = State(initialValue: existing?.description ?? "")
        _font = State(initialValue: existing?.font ?? .system)
        _accent = State(initialValue: existing?.accentHex ?? "3366CC")
        _lightBackground = State(initialValue: light.backgroundHex); _lightPrimary = State(initialValue: light.primaryTextHex); _lightSecondary = State(initialValue: light.secondaryTextHex); _lightTertiary = State(initialValue: light.tertiaryTextHex)
        _darkBackground = State(initialValue: dark.backgroundHex); _darkPrimary = State(initialValue: dark.primaryTextHex); _darkSecondary = State(initialValue: dark.secondaryTextHex); _darkTertiary = State(initialValue: dark.tertiaryTextHex)
    }

    var body: some View {
        Form {
            Group {
                Section("Identity") {
                    TextField("Theme name", text: $name)
                        .accessibilityLabel("Theme name")
                        .accessibilityIdentifier("settings.custom-theme.name")
                    TextField(
                        "Short description (optional)",
                        text: $themeDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...3)
                    .onChange(of: themeDescription) { _, value in
                        if value.count > CustomTheme.maximumDescriptionLength {
                            themeDescription = String(value.prefix(CustomTheme.maximumDescriptionLength))
                        }
                    }
                    .accessibilityLabel("Theme description, optional")
                    .accessibilityIdentifier("settings.custom-theme.description")
                    Text("\(themeDescription.count)/\(CustomTheme.maximumDescriptionLength)")
                        .loopdyFont(.metadata)
                        .foregroundStyle(editorTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(
                            "\(themeDescription.count) of \(CustomTheme.maximumDescriptionLength) characters"
                        )
                }
                livePreview
                Section("Accent") {
                    colorField(
                        "Accent",
                        value: $accent,
                        displayName: "Outgoing messages & actions",
                        detail: "Used for outgoing message bubbles, links, primary actions, selections, and focus. Brightness adapts to keep links readable in both appearances; message text is chosen for contrast."
                    )
                }
                Section {
                    DisclosureGroup("Portable theme document") {
                        Text("These values remain editable so existing themes and portable theme files round-trip without losing data. They do not change bighelp’s live canvas, cards, typography, icons, or geometry.")
                            .loopdyFont(.metadata)
                            .foregroundStyle(editorTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Stored font", selection: $font) {
                            ForEach(CustomThemeFontChoice.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                        .accessibilityIdentifier("settings.custom-theme.font")

                        DisclosureGroup("Light document colors") {
                            colorField("Light background", value: $lightBackground)
                            colorField("Light primary text", value: $lightPrimary)
                            colorField("Light secondary text", value: $lightSecondary)
                            colorField("Light tertiary text", value: $lightTertiary)
                        }

                        DisclosureGroup("Dark document colors") {
                            colorField("Dark background", value: $darkBackground)
                            colorField("Dark primary text", value: $darkPrimary)
                            colorField("Dark secondary text", value: $darkSecondary)
                            colorField("Dark tertiary text", value: $darkTertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.custom-theme.advanced-document")
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Portable files retain the stored font, light and dark palettes, and logos. bighelp still validates these legacy document colors before saving so exported themes remain compatible.")
                }
                Section {
                    if existing == nil {
                        Text("Save this theme before adding a local logo.")
                            .foregroundStyle(editorTheme.secondaryText)
                    } else {
                        ForEach(CustomThemeLogoVariant.allCases) { variant in
                            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                                Text("\(variant.title) mode")
                                    .loopdyFont(.label, weight: .semibold)
                                if let url = customLogoURL(for: variant),
                                   let image = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 96)
                                        .accessibilityLabel("Current \(variant.title.lowercased()) mode logo")
                                }
                                HStack {
                                    Button(
                                        currentLogo(for: variant) == nil ? "Choose logo" : "Replace logo",
                                        systemImage: "photo.on.rectangle"
                                    ) {
                                        logoImportVariant = variant
                                        isLogoImporterPresented = true
                                    }
                                    .accessibilityLabel(
                                        "\(currentLogo(for: variant) == nil ? "Choose" : "Replace") \(variant.title.lowercased()) mode logo"
                                    )
                                    .accessibilityIdentifier("settings.custom-theme.logo.\(variant.rawValue).choose")

                                    if currentLogo(for: variant) != nil {
                                        Button("Remove", systemImage: "trash", role: .destructive) {
                                            removeLogo(variant)
                                        }
                                        .accessibilityLabel("Remove \(variant.title.lowercased()) mode logo")
                                        .accessibilityIdentifier("settings.custom-theme.logo.\(variant.rawValue).remove")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Advanced · Logos")
                } footer: {
                    Text("PNG, JPEG, or HEIC; up to 1 MB and 4 megapixels. Logos stay attached to the saved theme document and are included in portable single-theme exports. They do not replace system navigation or settings chrome.")
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(editorTheme.danger)
                    }
                }
            }
            .listRowBackground(editorTheme.surface)
        }
        .modifier(CustomThemeEditorAppearance(theme: editorTheme))
        .loopdyFormSurface().navigationTitle(existing == nil ? "New Theme" : "Edit Theme").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityIdentifier("settings.custom-theme.save") } }
        .fileImporter(
            isPresented: $isLogoImporterPresented,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false,
            onCompletion: importLogo
        )
    }

    private func colorField(
        _ title: String,
        value: Binding<String>,
        displayName: String? = nil,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
            if let detail {
                Text(displayName ?? title)
                    .loopdyFont(.label, weight: .semibold)
                Text(detail)
                    .loopdyFont(.metadata)
                    .foregroundStyle(editorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: LoopdyTokens.space8) {
                Text(detail == nil ? title : "Hex color")
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Hex", text: value)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 82, idealWidth: detail == nil ? 82 : 100,
                           maxWidth: detail == nil ? 82 : 132)
                    .accessibilityLabel("\(title) hex value")
                    .accessibilityHint(detail ?? "Six-digit hexadecimal color")
                    .accessibilityIdentifier("settings.custom-theme.color.\(colorFieldIdentifier(title)).hex")
                ColorPicker(title, selection: colorBinding(value), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .accessibilityLabel("Pick \(title.lowercased()) color")
                    .accessibilityHint(detail ?? "")
                    .accessibilityIdentifier("settings.custom-theme.color.\(colorFieldIdentifier(title)).picker")
            }
        }
    }

    private var editorTheme: LoopdyTheme {
        LoopdyTheme.resolve(appearance: appAppearance, colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var lightPalette: CustomThemePalette {
        CustomThemePalette(backgroundHex: lightBackground, primaryTextHex: lightPrimary,
                           secondaryTextHex: lightSecondary, tertiaryTextHex: lightTertiary)
    }

    private var darkPalette: CustomThemePalette {
        CustomThemePalette(backgroundHex: darkBackground, primaryTextHex: darkPrimary,
                           secondaryTextHex: darkSecondary, tertiaryTextHex: darkTertiary)
    }

    private var livePreview: some View {
        Section {
            Picker("Preview appearance", selection: $previewMode) {
                ForEach(CustomThemeLogoVariant.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.custom-theme.preview-mode")

            if let palette = try? CustomTheme.previewPalette(
                palette: previewMode == .dark ? darkPalette : lightPalette,
                accentHex: accent, font: font, isDark: previewMode == .dark
            ) {
                CustomThemeLivePreview(palette: palette, isDark: previewMode == .dark)
                    .accessibilityIdentifier("settings.custom-theme.live-preview")
            } else {
                Label("Complete the accent and advanced document colors with six hexadecimal digits to preview this theme.", systemImage: "paintpalette")
                    .loopdyFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .loopdyFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.custom-theme.validation")
            }
        } header: {
            Text("Live preview")
        } footer: {
            Text("Preview only; changes apply when you save. The selected accent is the only theme color used by the live interface. Advanced document colors and font metadata remain stored for compatibility and export.")
        }
    }

    private var validationMessage: String? {
        do {
            _ = try CustomTheme(name: name, description: themeDescription, font: font,
                                accentHex: accent, light: lightPalette, dark: darkPalette)
            return nil
        } catch let error as CustomThemeValidationError {
            switch error {
            case .invalidName: return "Use a theme name between 1 and 40 characters."
            case .invalidDescription: return "Keep the description within 120 characters."
            case .invalidColor(let field): return "\(field.editorLabel) needs a six-digit hex color."
            case .insufficientContrast(let field):
                return "\(field.editorLabel) needs more contrast inside the portable theme document before saving."
            case .invalidLogoMetadata: return "Choose a valid local logo before saving."
            }
        } catch {
            return "Check the theme fields before saving."
        }
    }

    private func colorFieldIdentifier(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private func colorBinding(_ value: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: normalizedHex(value.wrappedValue) ?? "000000") },
            set: { color in
                let uiColor = UIColor(color)
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                value.wrappedValue = String(
                    format: "%02X%02X%02X",
                    Int(round(red * 255)),
                    Int(round(green * 255)),
                    Int(round(blue * 255))
                )
            }
        )
    }

    private func normalizedHex(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6,
              normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        return normalized
    }

    private var currentTheme: CustomTheme? {
        guard let existing else { return nil }
        return settings.customThemes.first { $0.id == existing.id }
    }

    private func currentLogo(for variant: CustomThemeLogoVariant) -> CustomThemeLogo? {
        switch variant {
        case .light: currentTheme?.lightLogo
        case .dark: currentTheme?.darkLogo
        }
    }

    private func customLogoURL(for variant: CustomThemeLogoVariant) -> URL? {
        existing.flatMap { settings.customLogoURL(for: $0.id, variant: variant) }
    }

    private func importLogo(_ result: Result<[URL], any Error>) {
        do {
            guard let themeID = existing?.id,
                  let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            _ = try settings.setCustomThemeLogo(
                data: Data(contentsOf: url),
                for: themeID,
                variant: logoImportVariant
            )
            error = nil
        } catch {
            self.error = "Logo could not be saved. Choose a PNG, JPEG, or HEIC image within the size limits."
        }
    }

    private func removeLogo(_ variant: CustomThemeLogoVariant) {
        do {
            guard let themeID = existing?.id else { return }
            try settings.removeCustomThemeLogo(for: themeID, variant: variant)
            error = nil
        } catch {
            self.error = "Logo could not be removed. Try again."
        }
    }

    private func save() {
        do {
            let theme = try CustomTheme(
                id: existing?.id ?? UUID(), name: name,
                description: themeDescription, font: font,
                accentHex: accent, light: lightPalette, dark: darkPalette,
                lightLogo: currentTheme?.lightLogo,
                darkLogo: currentTheme?.darkLogo
            )
            _ = try settings.saveCustomTheme(theme)
            settings.themeID = theme.themeID
            settings.bubbleColor = nil
            dismiss()
        } catch {
            self.error = validationMessage ?? "Theme could not be saved. Check the name, accent, and advanced document fields."
        }
    }
}

private struct CustomThemeEditorAppearance: ViewModifier {
    let theme: LoopdyTheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .foregroundStyle(theme.primaryText)
            .tint(theme.action)
    }
}
