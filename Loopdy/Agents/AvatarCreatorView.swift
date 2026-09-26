import SwiftUI
import UIKit

/// Agent Studio avatar creator: pick a character or a Bit, then make it yours
/// with a colorway or color, headwear (or a Bit's face), a pattern and how it moves.
@MainActor
@Observable
final class AvatarCreatorModel {
    enum Tab: String, CaseIterable, Identifiable {
        case character, color, extras, moves

        var id: String { rawValue }

        var title: String {
            switch self {
            case .character: "Character"
            case .color: "Color"
            case .extras: "Extras"
            case .moves: "Moves"
            }
        }

        var systemImage: String {
            switch self {
            case .character: "face.smiling"
            case .color: "paintpalette"
            case .extras: "crown"
            case .moves: "figure.dance"
            }
        }
    }

    /// Curated body colors; a custom color and the app theme are also offered.
    static let palette: [(name: String, hex: String)] = [
        ("Coral", "#FF6B5A"), ("Tangerine", "#FF9A3C"), ("Sunflower", "#F6C445"), ("Lime", "#A6D65A"),
        ("Mint", "#4CC9A0"), ("Teal", "#2BB3B1"), ("Sky", "#56AEE0"), ("Cobalt", "#3F6FD8"),
        ("Lavender", "#9B87F5"), ("Grape", "#7B4FD6"), ("Bubblegum", "#F28FC0"), ("Rose", "#E5487A"),
        ("Cocoa", "#8B5E3C"), ("Stone", "#9AA0A6"), ("Charcoal", "#2E3238"), ("Snow", "#F2F1EC"),
    ]

    var appearance: CompanionAppearance
    var tab: Tab = .character
    /// A short celebration after a tap on the stage.
    private(set) var isCelebrating = false
    private var celebration: Task<Void, Never>?

    init(appearance: CompanionAppearance) {
        self.appearance = appearance
    }

    /// New agents start from a random pleasant look instead of the same one.
    static func surprise() -> CompanionAppearance {
        let model = AvatarCreatorModel(appearance: CompanionAppearance(usesCharacterColors: true))
        model.shuffle()
        return model.appearance
    }

    var tabs: [Tab] { Tab.allCases }

    func select(_ character: CompanionCharacter) {
        appearance.character = character
        if !tabs.contains(tab) { tab = .character }
    }

    func selectColor(_ hex: String) {
        appearance.usesCharacterColors = false
        appearance.matchesTheme = false
        appearance.colorHex = hex
    }

    func selectThemeColor() {
        appearance.usesCharacterColors = false
        appearance.matchesTheme = true
    }

    /// A kit colorway; "original" keeps each character's own palette.
    func selectColorway(_ id: String) {
        appearance.colorway = id == "original" ? nil : id
        appearance.usesCharacterColors = true
    }

    /// Kit colorways, Original first.
    static var colorways: [AvatarKit.Theme] { AvatarKit.bundled?.themes ?? [] }

    func shuffle() {
        var next = appearance
        let characters = CompanionCharacter.allCases.filter { $0 != appearance.character }
        next.character = characters.randomElement() ?? .lobster
        next.matchesTheme = false
        if Int.random(in: 0..<3) == 0 {
            next.usesCharacterColors = false
            next.colorHex = Self.palette.filter { $0.hex != appearance.colorHex }.randomElement()?.hex
                ?? CompanionAppearance.fallbackColorHex
        } else {
            next.usesCharacterColors = true
            let way = Self.colorways.randomElement()?.id ?? "original"
            next.colorway = way == "original" ? nil : way
        }
        next.topper = !next.character.isBit && Int.random(in: 0..<3) == 0
            ? CompanionTopper.allCases.randomElement() : CompanionTopper.none
        next.bitEyes = Int.random(in: 0..<3) == 0 ? CompanionBitEyes.allCases.randomElement() : nil
        next.bitMouth = Int.random(in: 0..<3) == 0 ? CompanionBitMouth.allCases.randomElement() : nil
        next.bitAccessory = Int.random(in: 0..<3) == 0 ? CompanionBitAccessory.allCases.randomElement() : nil
        next.pattern = Int.random(in: 0..<3) == 0 ? CompanionPattern.allCases.randomElement() : CompanionPattern.none
        next.vibe = CompanionVibe.allCases.randomElement()
        appearance = next
        if !tabs.contains(tab) { tab = .character }
    }

    func celebrate() {
        celebration?.cancel()
        isCelebrating = true
        celebration = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.isCelebrating = false
        }
    }

    /// The current look on another character, for tile previews.
    func appearance(for character: CompanionCharacter) -> CompanionAppearance {
        var preview = appearance
        preview.character = character
        preview.vibe = nil
        return preview
    }
}

struct AvatarCreatorView: View {
    @State private var model: AvatarCreatorModel
    let agentName: String
    let onUse: (CompanionAppearance) -> Void
    @Environment(\.dismiss) private var dismiss

    init(appearance: CompanionAppearance, agentName: String, onUse: @escaping (CompanionAppearance) -> Void) {
        _model = State(initialValue: AvatarCreatorModel(appearance: appearance))
        self.agentName = agentName
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage
                    .padding(.horizontal, LoopdyTokens.space20)
                    .padding(.top, LoopdyTokens.space8)
                tabBar
                    .padding(.vertical, LoopdyTokens.space12)
                ScrollView {
                    panel
                        .padding(.horizontal, LoopdyTokens.space20)
                        .padding(.bottom, LoopdyTokens.space20)
                }
                .scrollIndicators(.hidden)
                // Each tab opens at its top, not where the last one was scrolled.
                .id(model.tab)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .frame(minHeight: LoopdyTokens.hitTarget)
                        .accessibilityIdentifier("avatar.creator.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use avatar") {
                        onUse(model.appearance)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .loopdyProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: LoopdyTokens.hitTarget)
                    .accessibilityIdentifier("avatar.creator.use")
                }
            }
        }
        .accessibilityIdentifier("avatar.creator")
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(theme.surface)
                .overlay {
                    RadialGradient(
                        colors: [stageColor.opacity(0.28), stageColor.opacity(0.06), .clear],
                        center: .center, startRadius: 10, endRadius: 190
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            CompanionAvatar(
                appearance: model.appearance,
                reaction: model.isCelebrating ? .celebrate : .idle,
                isAnimating: true
            )
            .frame(width: 180, height: 180)
            .contentShape(.rect)
            .onTapGesture { model.celebrate() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Plays a little celebration.")
            .accessibilityIdentifier("avatar.creator.preview")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, LoopdyTokens.space20)
            Text(model.appearance.character.displayName)
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, LoopdyTokens.space16)
                .padding(.vertical, LoopdyTokens.space16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityIdentifier("avatar.creator.name")
            Button {
                withAnimation(.snappy) { model.shuffle() }
            } label: {
                Image(systemName: "dice")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.incomingMessageBackground))
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(LoopdyTokens.space8)
            .accessibilityLabel("Shuffle")
            .accessibilityHint("Tries a random character and look.")
            .accessibilityIdentifier("avatar.creator.shuffle")
        }
        .frame(height: 260)
    }

    private var stageColor: Color {
        Color(hex: String(resolvedBodyHex.dropFirst()))
    }

    private var resolvedBodyHex: String {
        let themeHex = CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
        return model.appearance.avatarKitColors(themeHex: themeHex)?.primary ?? themeHex
    }

    // MARK: Tabs

    /// Equal-width strip: every category is visible at once, no scrolling.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                let isSelected = model.tab == tab
                Button {
                    withAnimation(.snappy) { model.tab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? theme.actionForeground : theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.action)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("avatar.creator.tab.\(tab.rawValue)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.incomingMessageBackground))
        .padding(.horizontal, LoopdyTokens.space20)
    }

    @ViewBuilder
    private var panel: some View {
        switch model.tab {
        case .character: characterPanel
        case .color: colorPanel
        case .extras: extrasPanel
        case .moves: movesPanel
        }
    }

    // MARK: Character

    private var characterPanel: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            characterSection("Characters", CompanionCharacter.characters)
            characterSection("Bits", CompanionCharacter.bits)
        }
    }

    private func characterSection(_ title: String, _ characters: [CompanionCharacter]) -> some View {
        section(title) {
            grid(minimum: 76) {
                ForEach(characters) { character in
                    tile(
                        title: character.displayName,
                        isSelected: model.appearance.character == character,
                        identifier: "avatar.creator.character.\(character.rawValue)"
                    ) {
                        withAnimation(.snappy) { model.select(character) }
                    } preview: {
                        CompanionAvatar(appearance: model.appearance(for: character), reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
    }

    // MARK: Color

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            section("Colorway") {
                grid(minimum: 76) {
                    ForEach(AvatarCreatorModel.colorways) { way in
                        tile(
                            title: way.name,
                            isSelected: model.appearance.usesCharacterColors && (model.appearance.colorway ?? "original") == way.id,
                            identifier: "avatar.creator.colorway.\(way.id)"
                        ) {
                            model.selectColorway(way.id)
                        } preview: {
                            CompanionAvatar(appearance: preview {
                                $0.colorway = way.id == "original" ? nil : way.id
                                $0.usesCharacterColors = true
                            }, reaction: .idle, isAnimating: false)
                        }
                    }
                }
            }
            mainColorSection
        }
    }

    private var mainColorSection: some View {
        section("Main color") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LoopdyTokens.space12), count: 6),
                      spacing: LoopdyTokens.space12) {
                swatch(
                    fill: AnyShapeStyle(AngularGradient(colors: [theme.action, theme.action.opacity(0.55), theme.action],
                                                        center: .center)),
                    isSelected: !model.appearance.usesCharacterColors && model.appearance.matchesTheme,
                    label: "Theme color",
                    identifier: "avatar.creator.color.theme"
                ) { model.selectThemeColor() } overlay: {
                    Image(systemName: "sparkles").font(.caption.weight(.bold)).foregroundStyle(theme.actionForeground)
                }
                ForEach(AvatarCreatorModel.palette, id: \.hex) { color in
                    swatch(
                        fill: AnyShapeStyle(Color(hex: String(color.hex.dropFirst()))),
                        isSelected: !model.appearance.usesCharacterColors && !model.appearance.matchesTheme
                            && model.appearance.colorHex == color.hex,
                        label: color.name,
                        identifier: "avatar.creator.color.\(color.name.lowercased())"
                    ) { model.selectColor(color.hex) } overlay: { EmptyView() }
                }
                ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Custom color")
                    .accessibilityIdentifier("avatar.creator.color.custom")
            }
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { stageColor },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                model.selectColor(CompanionColor.hex(red: red, green: green, blue: blue))
            }
        )
    }

    // MARK: Extras

    private var extrasPanel: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            if model.appearance.character.isBit {
                bitFaceSections
            } else {
                headwearSection
            }
            section("Pattern") {
                grid(minimum: 76) {
                    ForEach(CompanionPattern.allCases) { pattern in
                        tile(
                            title: pattern.displayName,
                            isSelected: (model.appearance.pattern ?? .none) == pattern,
                            identifier: "avatar.creator.pattern.\(pattern.rawValue)"
                        ) {
                            model.appearance.pattern = pattern
                        } preview: {
                            CompanionAvatar(appearance: preview { $0.pattern = pattern }, reaction: .idle, isAnimating: false)
                        }
                    }
                }
            }
        }
    }

    private var headwearSection: some View {
        section("Headwear") {
            grid(minimum: 76) {
                ForEach(CompanionTopper.allCases) { topper in
                    tile(
                        title: topper.displayName,
                        isSelected: (model.appearance.topper ?? .none) == topper,
                        identifier: "avatar.creator.topper.\(topper.rawValue)"
                    ) {
                        model.appearance.topper = topper
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.topper = topper }, reaction: .idle, isAnimating: false)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    /// A Bit's own face parts, from the kit.
    @ViewBuilder
    private var bitFaceSections: some View {
        let face = model.appearance.avatarKitFace ?? AvatarKitFace(
            AvatarKit.bundled?.character(model.appearance.character.rawValue)?.face
        )
        section("Eyes") {
            grid(minimum: 76) {
                ForEach(CompanionBitEyes.allCases) { eyes in
                    tile(title: eyes.displayName, isSelected: face.eyes == eyes.rawValue,
                         identifier: "avatar.creator.eyes.\(eyes.rawValue)") {
                        model.appearance.bitEyes = eyes
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitEyes = eyes }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
        section("Mouth") {
            grid(minimum: 76) {
                ForEach(CompanionBitMouth.allCases) { mouth in
                    tile(title: mouth.displayName, isSelected: face.mouth == mouth.rawValue,
                         identifier: "avatar.creator.mouth.\(mouth.rawValue)") {
                        model.appearance.bitMouth = mouth
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitMouth = mouth }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
        section("On top") {
            grid(minimum: 76) {
                ForEach(CompanionBitAccessory.allCases) { accessory in
                    tile(title: accessory.displayName, isSelected: face.accessory == accessory.rawValue,
                         identifier: "avatar.creator.accessory.\(accessory.rawValue)") {
                        model.appearance.bitAccessory = accessory
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitAccessory = accessory }, reaction: .idle, isAnimating: false)
                            .padding(.top, 6)
                    }
                }
            }
        }
        section("Cheeks") {
            grid(minimum: 76) {
                ForEach([true, false], id: \.self) { shows in
                    tile(title: shows ? "Blush" : "No blush", isSelected: face.cheeks == shows,
                         identifier: "avatar.creator.cheeks.\(shows ? "on" : "off")") {
                        model.appearance.showsCheeks = shows
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.showsCheeks = shows }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
    }

    // MARK: Moves

    private var movesPanel: some View {
        section("When it's idle") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: LoopdyTokens.space12),
                                GridItem(.flexible(), spacing: LoopdyTokens.space12)],
                      spacing: LoopdyTokens.space12) {
                ForEach(CompanionVibe.allCases) { vibe in
                    let isSelected = (model.appearance.vibe ?? .calm) == vibe
                    Button {
                        withAnimation(.snappy) { model.appearance.vibe = vibe }
                    } label: {
                        Label(vibe.displayName, systemImage: vibe.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isSelected ? theme.action : theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("avatar.creator.move.\(vibe.rawValue)")
                }
            }
        }
    }

    // MARK: Building blocks

    private func preview(_ change: (inout CompanionAppearance) -> Void) -> CompanionAppearance {
        var look = model.appearance
        look.vibe = nil
        change(&look)
        return look
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            AgentStudioCaption(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid<Content: View>(minimum: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: LoopdyTokens.space12)],
                  spacing: LoopdyTokens.space12) {
            content()
        }
    }

    private func tile<Preview: View>(
        title: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        Button(action: action) {
            VStack(spacing: LoopdyTokens.space4) {
                preview()
                    .frame(width: 58, height: 58)
                    .allowsHitTesting(false)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LoopdyTokens.space8)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? theme.action : theme.border, lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    private func swatch<Overlay: View>(
        fill: AnyShapeStyle,
        isSelected: Bool,
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                .overlay(overlay())
                .frame(width: 40, height: 40)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? theme.action : Color.clear, lineWidth: 2.5))
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    @LoopdyThemeReader private var theme
}
