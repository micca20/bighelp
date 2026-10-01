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
    #if os(visionOS)
    /// A mood being tried on the 3D stage; nil plays the chosen moves.
    @State private var tryingMood: String?
    @State private var isShowingInRoom = false
    @Environment(\.spatialAvatar) private var spatialAvatar
    @Environment(\.openWindow) private var openWindow
    #endif

    init(appearance: CompanionAppearance, agentName: String, onUse: @escaping (CompanionAppearance) -> Void) {
        _model = State(initialValue: AvatarCreatorModel(appearance: appearance))
        self.agentName = agentName
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            layout
            .background(theme.canvas.ignoresSafeArea())
            #if os(visionOS)
            // What you try on in the room follows every change, until you're done here.
            .onChange(of: model.appearance) { _, appearance in
                if isShowingInRoom { spatialAvatar?.previewAppearance = appearance }
            }
            .onDisappear { spatialAvatar?.previewAppearance = nil }
            #endif
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("avatar.creator.cancel")
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use avatar") {
                        onUse(model.appearance)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("avatar.creator.use")
                }
            }
        }
        .accessibilityIdentifier("avatar.creator")
    }

    /// Phone and iPad: the character on top, choices under it. Vision Pro: the
    /// 3D character beside the choices, in a wider sheet, so both have room.
    /// The Mac too: its sheet is wide and short, so a stage on top left the
    /// choices a sliver.
    @ViewBuilder
    private var layout: some View {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                stage
                    .frame(width: min(440, proxy.size.width * 0.46))
                    .padding([.leading, .vertical], BighelpTokens.space20)
                VStack(spacing: 0) {
                    tabBar
                        .padding(.vertical, BighelpTokens.space12)
                    choices
                }
            }
        }
        #else
        VStack(spacing: 0) {
            stage
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.top, BighelpTokens.space8)
            tabBar
                .padding(.vertical, BighelpTokens.space12)
            choices
        }
        #endif
    }

    private var choices: some View {
        ScrollView {
            panel
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.bottom, BighelpTokens.space20)
        }
        .scrollIndicators(.hidden)
        // Each tab opens at its top, not where the last one was scrolled.
        .id(model.tab)
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
            #if os(visionOS)
            spatialStage
            #else
            CompanionAvatar(
                appearance: model.appearance,
                reaction: model.isCelebrating ? .celebrate : .idle,
                isAnimating: true
            )
            .frame(width: Self.previewSize, height: Self.previewSize)
            .contentShape(.rect)
            .onTapGesture { model.celebrate() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Plays a little celebration.")
            .accessibilityIdentifier("avatar.creator.preview")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, BighelpTokens.space20)
            #endif
            Text(model.appearance.character.displayName)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space16)
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
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(BighelpTokens.space8)
            .accessibilityLabel("Shuffle")
            .accessibilityHint("Tries a random character and look.")
            .accessibilityIdentifier("avatar.creator.shuffle")
        }
        #if os(visionOS) || targetEnvironment(macCatalyst)
        .frame(maxHeight: .infinity)
        #else
        .frame(height: 260)
        #endif
    }

    #if !os(visionOS)
    /// The Mac's stage is the sheet's full height, so the character can be bigger.
    private static var previewSize: CGFloat { BighelpPlatform.isMac ? 240 : 180 }
    #endif

    #if os(visionOS)
    /// Moods to try on the 3D stage: how it looks while the agent works.
    private static let tryouts: [(title: String, mood: String?)] = [
        ("Its moves", nil), ("Listening", "listening"), ("Thinking", "thinking"),
        ("Talking", "nod"), ("Happy", "excited"), ("Sleepy", "sleepy"),
    ]

    /// Vision Pro: the character in 3D, as it will stand in your room.
    private var spatialStage: some View {
        VStack(spacing: BighelpTokens.space12) {
            if let look = SpatialAvatarLook(appearance: model.appearance, themeHex: theme.actionHex) {
                SpatialAvatarPreview(look: look, mood: tryingMood ?? model.appearance.vibe?.moodID, height: 380) {
                    model.celebrate()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.appearance.character.displayName) in 3D")
                .accessibilityHint("Pinch for a hop; drag to turn it around.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { model.celebrate() }
                .accessibilityIdentifier("avatar.creator.preview")
            }
            // Wraps onto two rows in the narrow stage, so every mood is in view.
            FlowLayout(spacing: BighelpTokens.space8) {
                    ForEach(Self.tryouts, id: \.title) { tryout in
                        let isSelected = tryingMood == tryout.mood
                        Button {
                            withAnimation(.snappy) { tryingMood = tryout.mood }
                        } label: {
                            Text(tryout.title)
                                .font(.bighelp(.callout).weight(.semibold))
                                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                                .padding(.horizontal, BighelpTokens.space16)
                                .frame(minHeight: BighelpTokens.hitTarget)
                                .background(Capsule().fill(isSelected ? theme.action : theme.incomingMessageBackground))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("avatar.creator.try.\(tryout.mood ?? "moves")")
                    }
                    if spatialAvatar != nil {
                        Button {
                            spatialAvatar?.previewAppearance = model.appearance
                            isShowingInRoom = true
                            if spatialAvatar?.isVolumeOpen != true { openWindow(id: SpatialAvatarSceneID.avatar) }
                        } label: {
                            Label(isShowingInRoom ? "In your room" : "See it in your room",
                                  systemImage: "cube.transparent")
                                .font(.bighelp(.callout).weight(.semibold))
                                .foregroundStyle(theme.action)
                                .padding(.horizontal, BighelpTokens.space16)
                                .frame(minHeight: BighelpTokens.hitTarget)
                                .background(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityHint("Shows this look at full size in your space while you design it.")
                        .accessibilityIdentifier("avatar.creator.in-room")
                    }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, BighelpTokens.space16)
    }
    #endif

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
                            .font(.bighelp(.caption2).weight(.semibold))
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
        .padding(.horizontal, BighelpTokens.space20)
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
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
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
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 6),
                      spacing: BighelpTokens.space12) {
                swatch(
                    fill: AnyShapeStyle(AngularGradient(colors: [theme.action, theme.action.opacity(0.55), theme.action],
                                                        center: .center)),
                    isSelected: !model.appearance.usesCharacterColors && model.appearance.matchesTheme,
                    label: "Theme color",
                    identifier: "avatar.creator.color.theme"
                ) { model.selectThemeColor() } overlay: {
                    Image(systemName: "sparkles").font(.bighelp(.caption).weight(.bold)).foregroundStyle(theme.actionForeground)
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
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: BighelpTokens.space12),
                                GridItem(.flexible(), spacing: BighelpTokens.space12)],
                      spacing: BighelpTokens.space12) {
                ForEach(CompanionVibe.allCases) { vibe in
                    let isSelected = (model.appearance.vibe ?? .calm) == vibe
                    Button {
                        withAnimation(.snappy) { model.appearance.vibe = vibe }
                    } label: {
                        Label(vibe.displayName, systemImage: vibe.systemImage)
                            .font(.bighelp(.body).weight(.semibold))
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
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            AgentStudioCaption(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid<Content: View>(minimum: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: BighelpTokens.space12)],
                  spacing: BighelpTokens.space12) {
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
            VStack(spacing: BighelpTokens.space4) {
                preview()
                    .frame(width: 58, height: 58)
                    .allowsHitTesting(false)
                Text(title)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
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
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

#if os(visionOS)
/// Lays views out left to right, starting a new row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            // Each row is centered, like the stage above it.
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif
