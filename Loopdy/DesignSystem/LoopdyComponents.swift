import SwiftUI

extension View {
    /// Lets presented content sample what is behind it unless accessibility
    /// requires a fully opaque surface.
    func loopdyTranslucentPresentationBackground(fallback: Color) -> some View {
        modifier(LoopdyTranslucentPresentationBackground(fallback: fallback))
    }
}

private struct LoopdyTranslucentPresentationBackground: ViewModifier {
    let fallback: Color

    // Ember sheets sit on the warm canvas (cream / after dark) rather than a
    // gray system material, so they read as part of the same surface family.
    func body(content: Content) -> some View {
        content.presentationBackground(fallback)
    }
}

enum LoopdyComponentKind: Equatable, Sendable {
    case card
    case iconButton
    case pillControl
    case menuPanel
    case menuRow
    case composer
    case searchField
    case generatedContentInset
}

struct LoopdyComponentPresentation: Equatable, Sendable {
    let surfaceRole: LoopdySurfaceRole?
    let cornerRadius: CGFloat
    let minimumHeight: CGFloat?
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?
    let usesInteractiveSurface: Bool
    let opaqueBase: LoopdySurfaceOpaqueBase?
    let elevation: LoopdySurfaceElevation

    static func resolve(
        _ kind: LoopdyComponentKind,
        isSelected: Bool = false
    ) -> LoopdyComponentPresentation {
        switch kind {
        case .card:
            LoopdyComponentPresentation(
                surfaceRole: .card,
                cornerRadius: LoopdyTokens.cardCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: .surface,
                elevation: .low
            )
        case .iconButton:
            LoopdyComponentPresentation(
                surfaceRole: .circularControl,
                cornerRadius: LoopdyTokens.minimumControlSize / 2,
                minimumHeight: LoopdyTokens.minimumControlSize,
                fixedWidth: LoopdyTokens.minimumControlSize,
                fixedHeight: LoopdyTokens.minimumControlSize,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .low
            )
        case .pillControl:
            LoopdyComponentPresentation(
                surfaceRole: .capsuleControl,
                cornerRadius: LoopdyTokens.radiusPill,
                minimumHeight: LoopdyTokens.minimumControlSize,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .low
            )
        case .menuPanel:
            LoopdyComponentPresentation(
                surfaceRole: .menu,
                cornerRadius: LoopdyTokens.menuCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: nil,
                elevation: .high
            )
        case .menuRow:
            LoopdyComponentPresentation(
                surfaceRole: isSelected ? .selected : nil,
                cornerRadius: LoopdyTokens.menuRowCornerRadius,
                minimumHeight: LoopdyTokens.minimumControlSize,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: isSelected ? .surface : nil,
                elevation: .none
            )
        case .composer:
            LoopdyComponentPresentation(
                surfaceRole: .composer,
                cornerRadius: LoopdyTokens.composerCornerRadius,
                minimumHeight: LoopdyTokens.composerMinimumHeight,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: nil,
                elevation: .medium
            )
        case .searchField:
            LoopdyComponentPresentation(
                surfaceRole: .input,
                cornerRadius: LoopdyTokens.inputCornerRadius,
                minimumHeight: LoopdyTokens.searchMinimumHeight,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .none
            )
        case .generatedContentInset:
            LoopdyComponentPresentation(
                surfaceRole: nil,
                cornerRadius: LoopdyTokens.generatedContentInsetCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: .raisedSurface,
                elevation: .none
            )
        }
    }
}

struct LoopdyHeaderActionPresentation: Equatable, Sendable {
    let iconPointSize: CGFloat
    let hitTarget: CGFloat
    let renderingMode: LoopdyIconRenderingMode
    let showsBackground: Bool
    let showsBorder: Bool
    let usesTintFill: Bool

    static let standard = LoopdyHeaderActionPresentation(
        iconPointSize: 17,
        hitTarget: LoopdyTokens.hitTarget,
        renderingMode: .monochrome,
        showsBackground: false,
        showsBorder: false,
        usesTintFill: false
    )

    static let chatPrimary = LoopdyHeaderActionPresentation(
        iconPointSize: 22,
        hitTarget: LoopdyTokens.controlHeight,
        renderingMode: .monochrome,
        showsBackground: false,
        showsBorder: false,
        usesTintFill: false
    )
}

extension LoopdyHeaderActionPresentation {
    static let compactGlass = LoopdyHeaderActionPresentation(
        iconPointSize: 18,
        hitTarget: 48,
        renderingMode: .monochrome,
        showsBackground: true,
        showsBorder: false,
        usesTintFill: false
    )
}

struct SpectrumActionHitTargetPresentation: Equatable, Sendable {
    let visualSize: CGFloat
    let minimumHeight: CGFloat
    let expandsHorizontally: Bool
}

struct SpectrumAction: View {
    static let hitTargetPresentation = SpectrumActionHitTargetPresentation(
        visualSize: LoopdyTokens.primaryActionSize,
        minimumHeight: LoopdyTokens.primaryActionSize,
        expandsHorizontally: true
    )

    let accessibilityLabel: String
    let isAvailable: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        accessibilityLabel: String,
        isAvailable: Bool = true,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.isAvailable = isAvailable
        self.action = action
    }

    var body: some View {
        let presentation = FloatingTabBar.newChatPresentation(for: theme.themeID)
        let hitTarget = Self.hitTargetPresentation
        Button(action: action) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(presentation.foreground == .themeAccent
                        ? theme.action
                        : theme.primaryText)
                    .frame(width: hitTarget.visualSize, height: hitTarget.visualSize)
                    .modifier(
                        FloatingTabBarActionSurfaceModifier(
                            theme: theme,
                            reduceTransparency: reduceTransparency
                        )
                    )
                    .opacity(isAvailable ? 1 : 0.48)
                Spacer(minLength: 0)
            }
            .frame(
                maxWidth: hitTarget.expandsHorizontally ? .infinity : hitTarget.visualSize,
                minHeight: hitTarget.minimumHeight
            )
            .contentShape(.rect)
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(
            maxWidth: hitTarget.expandsHorizontally ? .infinity : hitTarget.visualSize,
            minHeight: hitTarget.minimumHeight
        )
        .contentShape(.rect)
        .disabled(!isAvailable)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isAvailable ? "Available" : "Unavailable")
    }

    @LoopdyThemeReader private var theme
}

struct FloatingTabBarActionSurfaceModifier: ViewModifier {
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    let theme: LoopdyTheme
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if uiV2Enabled {
            content.loopdySurface(.circularControl, isInteractive: true)
        } else if reduceTransparency {
            content.background(theme.raisedSurface, in: .circle)
        } else if #available(iOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: .circle)
        }
    }
}

private struct SpectrumPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                .easeOut(duration: LoopdyTokens.pressDuration),
                value: configuration.isPressed
            )
    }
}

struct LoopdyHeaderActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let presentation: LoopdyHeaderActionPresentation
    let symbolVerticalOffset: CGFloat
    let role: ButtonRole?
    let isEnabled: Bool
    let action: () -> Void


    init(
        systemImage: String,
        accessibilityLabel: String,
        presentation: LoopdyHeaderActionPresentation = .standard,
        symbolVerticalOffset: CGFloat = 0,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.presentation = presentation
        self.symbolVerticalOffset = symbolVerticalOffset
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: presentation.iconPointSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(theme.primaryText)
                .offset(y: symbolVerticalOffset)
                .frame(width: presentation.hitTarget, height: presentation.hitTarget)
                .contentShape(.rect)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
                .modifier(LoopdyHeaderSurfaceModifier())
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(width: presentation.hitTarget, height: presentation.hitTarget)
        .contentShape(.rect)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isEnabled ? "Available" : "Unavailable")
    }

    @LoopdyThemeReader private var theme
}

private struct LoopdyHeaderSurfaceModifier: ViewModifier {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled {
            content.loopdyNavigationGlass(in: Circle(), isInteractive: true)
        } else if uiV2Enabled {
            content.loopdySurface(.circularControl, isInteractive: true)
        } else {
            content
        }
    }
}

struct LoopdyCard<Content: View>: View {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .padding(LoopdyTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius16))
        } else {
            content
                .padding(LoopdyTokens.space16)
                .loopdySurface(.card)
        }
    }

    @LoopdyThemeReader private var theme
}

enum LoopdyIconButtonStyle: Equatable, Sendable {
    case themed
    case neutralGlass
}

struct LoopdyIconButtonPresentation: Equatable, Sendable {
    enum Foreground: Equatable, Sendable {
        case themed
        case primaryText
    }

    let surfaceRole: LoopdySurfaceRole
    let foreground: Foreground
    let usesThemedIconWell: Bool
    let usesAccentTint: Bool

    static func resolve(_ style: LoopdyIconButtonStyle) -> Self {
        switch style {
        case .themed:
            LoopdyIconButtonPresentation(
                surfaceRole: .circularControl,
                foreground: .themed,
                usesThemedIconWell: true,
                usesAccentTint: true
            )
        case .neutralGlass:
            LoopdyIconButtonPresentation(
                surfaceRole: .circularControl,
                foreground: .primaryText,
                usesThemedIconWell: false,
                usesAccentTint: false
            )
        }
    }
}

struct LoopdyIconButton: View {
    @Environment(\.loopdyUIV2Enabled) private var uiV2Enabled
    let systemImage: String
    let accessibilityLabel: String
    let role: ButtonRole?
    let isEnabled: Bool
    let style: LoopdyIconButtonStyle
    let action: () -> Void


    init(
        systemImage: String,
        accessibilityLabel: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        style: LoopdyIconButtonStyle = .themed,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.role = role
        self.isEnabled = isEnabled
        self.style = style
        self.action = action
    }

    var body: some View {
        let presentation = LoopdyIconButtonPresentation.resolve(style)
        Button(role: role, action: action) {
            presentedIcon
                .frame(
                    width: LoopdyTokens.minimumControlSize,
                    height: LoopdyTokens.minimumControlSize
                )
                .contentShape(.circle)
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(
            width: LoopdyTokens.minimumControlSize,
            height: LoopdyTokens.minimumControlSize
        )
        .loopdySurface(presentation.surfaceRole, isInteractive: true)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isEnabled ? "Available" : "Unavailable")
    }

    @ViewBuilder
    private var presentedIcon: some View {
        if uiV2Enabled {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(role == .destructive ? theme.danger : theme.primaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
        } else {
            legacyIcon
        }
    }

    @ViewBuilder
    private var legacyIcon: some View {
        switch style {
        case .themed:
            LoopdyPresentedIcon(systemName: systemImage)
        case .neutralGlass:
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(theme.primaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
        }
    }

    @LoopdyThemeReader private var theme
}

struct LoopdyPillControl<Label: View>: View {
    let role: ButtonRole?
    let usesNavigationGlass: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    private let label: Label


    init(
        role: ButtonRole? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        usesNavigationGlass: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.usesNavigationGlass = usesNavigationGlass
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) {
            label
                .loopdyFont(.label)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, LoopdyTokens.space16)
                .frame(minHeight: LoopdyTokens.minimumControlSize)
                .contentShape(.capsule)
        }
        .buttonStyle(SpectrumPressStyle())
        .modifier(LoopdyPillSurfaceModifier(usesNavigationGlass: usesNavigationGlass))
        .overlay {
            if isSelected {
                Capsule()
                    .fill(theme.action.opacity(0.12))
                    .allowsHitTesting(false)
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @LoopdyThemeReader private var theme
}

struct LoopdyPillSurfaceModifier: ViewModifier {
    let usesNavigationGlass: Bool

    func body(content: Content) -> some View {
        if usesNavigationGlass {
            content.loopdyNavigationGlass(in: Capsule(), isInteractive: true)
        } else {
            content.loopdySurface(.capsuleControl, isInteractive: true)
        }
    }
}

struct LoopdyMenuPanel<Content: View>: View {
    @Environment(\.loopdyUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .padding(LoopdyTokens.space8)
                .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius12))
        } else {
            content
                .padding(LoopdyTokens.space8)
                .loopdySurface(.menu)
        }
    }

    @LoopdyThemeReader private var theme
}

struct LoopdyMenuRow<Label: View>: View {
    let role: ButtonRole?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    private let label: Label

    init(
        role: ButtonRole? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: LoopdyTokens.minimumControlSize)
                .padding(.horizontal, LoopdyTokens.space12)
                .contentShape(.rect)
        }
        .buttonStyle(SpectrumPressStyle())
        .modifier(LoopdyMenuRowSurfaceModifier(isSelected: isSelected))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct LoopdySearchField: View {
    @Binding var text: String

    let prompt: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String?
    let onSubmit: () -> Void


    init(
        text: Binding<String>,
        prompt: String = "Search",
        accessibilityLabel: String = "Search",
        accessibilityIdentifier: String? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: LoopdyTokens.space8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.secondaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .loopdyFont(.body)
                .foregroundStyle(theme.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isSearchField)
                .modifier(LoopdySearchIdentifier(identifier: accessibilityIdentifier))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .frame(
                            width: LoopdyTokens.minimumControlSize,
                            height: LoopdyTokens.minimumControlSize
                        )
                        .contentShape(.rect)
                        .reflectiveVisionIcon()
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Removes the current search text")
                .modifier(LoopdySearchIdentifier(identifier: accessibilityIdentifier.map { "\($0).clear" }))
            }
        }
        .padding(.leading, LoopdyTokens.space12)
        .padding(.trailing, text.isEmpty ? LoopdyTokens.space12 : 0)
        .frame(minHeight: LoopdyTokens.searchMinimumHeight)
        .loopdySurface(.input, isInteractive: true)
    }

    @LoopdyThemeReader private var theme
}

private struct LoopdySearchIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct LoopdyMenuRowSurfaceModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.loopdySurface(.selected)
        } else {
            content
        }
    }
}

private struct LoopdyPresentedIcon: View {
    let systemName: String


    var body: some View {
        let presentation = LoopdyIconPresentation.resolve(style: theme.iconStyle)

        ZStack {
            iconWell(for: presentation)
            icon(for: presentation)
        }
    }

    @ViewBuilder
    private func iconWell(for presentation: LoopdyIconPresentation) -> some View {
        switch presentation.innerWell {
        case .tintedCircle:
            Circle()
                .fill(theme.action.opacity(0.12))
                .frame(width: 30, height: 30)
        case .outlinedRoundedRectangle:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.primaryText.opacity(0.55), lineWidth: LoopdyTokens.hairline)
                .frame(width: 30, height: 28)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func icon(for presentation: LoopdyIconPresentation) -> some View {
        let image = Image(systemName: systemName)
            .font(.system(size: 17, weight: fontWeight(for: presentation.glyphWeight)))
            .symbolRenderingMode(
                presentation.renderingMode == .hierarchical ? .hierarchical : .monochrome
            )
            .foregroundStyle(
                presentation.renderingMode == .hierarchical ? theme.action : theme.primaryText
            )
            .reflectiveVisionIcon()
            .accessibilityHidden(true)

        if presentation.symbolVariant == .filled {
            image.symbolVariant(.fill)
        } else {
            image.symbolVariant(.none)
        }
    }

    private func fontWeight(for weight: LoopdyIconGlyphWeight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .semibold: .semibold
        }
    }

    @LoopdyThemeReader private var theme
}

struct StatusBadge: View {
    enum Status {
        case success
        case warning
        case danger
        case information
    }

    let title: String
    let status: Status


    var body: some View {
        Label(title, systemImage: status.systemImage)
            .loopdyFont(.metadata, weight: .semibold)
            .foregroundStyle(status.color(in: theme))
            .padding(.horizontal, LoopdyTokens.space8)
            .padding(.vertical, LoopdyTokens.space4)
            .background(status.color(in: theme).opacity(0.12), in: .capsule)
            .accessibilityElement(children: .combine)
    }

    @LoopdyThemeReader private var theme
}

private extension StatusBadge.Status {
    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .information: "info.circle.fill"
        }
    }

    func color(in theme: LoopdyTheme) -> Color {
        switch self {
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        case .information: theme.information
        }
    }
}

/// The circular context indicator shown next to the chat model chip.
///
/// The ring is a button so the token breakdown stays reachable by keyboard and
/// VoiceOver. Colour is never the only cue: the remaining share is always
/// printed inside the ring and repeated in the accessibility value.
struct SessionContextRing: View {
    let snapshot: SessionContextSnapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(
                        theme.border,
                        lineWidth: SessionContextRingPresentation.lineWidth
                    )
                Circle()
                    .trim(from: 0, to: SessionContextRingPresentation.fill(
                        usedPercent: snapshot.contextPercent
                    ))
                    .stroke(
                        ringTintColor,
                        style: StrokeStyle(
                            lineWidth: SessionContextRingPresentation.lineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                Text(SessionContextRingPresentation.remainingLabel(
                    usedPercent: snapshot.contextPercent
                ))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .frame(
                width: SessionContextRingPresentation.diameter,
                height: SessionContextRingPresentation.diameter
            )
            .frame(
                minWidth: LoopdyTokens.hitTarget,
                minHeight: LoopdyTokens.hitTarget
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window")
        .accessibilityValue(
            SessionContextRingPresentation.accessibilityValue(for: snapshot)
        )
        .accessibilityHint("Shows the token breakdown for this session.")
        .accessibilityIdentifier("chat.session-context")
    }

    private var ringTintColor: Color {
        let tint = SessionContextRingPresentation.tint(
            usedPercent: snapshot.contextPercent,
            theme: ringTintTheme
        )
        return Color(
            .sRGB,
            red: tint.red,
            green: tint.green,
            blue: tint.blue,
            opacity: tint.alpha
        )
    }

    private var ringTintTheme: SessionContextRingPresentation.Theme {
        switch appAppearance.appearance {
        case .system:
            colorScheme == .dark ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    @LoopdyThemeReader private var theme

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAppearance) private var appAppearance
}

/// The token breakdown presented from the context ring.
struct SessionContextTokenPopover: View {
    let snapshot: SessionContextSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text("Context window")
                    .loopdyFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(SessionContextPresentation.summary(for: snapshot))
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: LoopdyTokens.space8) {
                ForEach(SessionContextPresentation.tokenRows(for: snapshot)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space12) {
                        Text(row.title)
                            .loopdyFont(.body)
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: LoopdyTokens.space12)
                        Text(row.value)
                            .loopdyFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat.session-context.\(row.id)")
                }
            }

            if !snapshot.hasTokenAccounting {
                Text("Detailed token usage is unavailable.")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.session-context.unavailable")
            }

            if snapshot.isCompacting {
                Label("Compacting the context window", systemImage: "arrow.down.right.and.arrow.up.left")
                    .loopdyFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.session-context.compacting")
            }
        }
        .padding(LoopdyTokens.space20)
        .frame(minWidth: 260, alignment: .leading)
        .background(theme.canvas)
        .accessibilityIdentifier("chat.session-context.popover")
    }

    @LoopdyThemeReader private var theme

}

/// A compact, iOS-native inline problem notice: tinted icon, readable text that
/// wraps rather than truncates, and optional recovery and dismissal controls
/// with full-size hit targets. Text stays in the primary color for contrast;
/// only the icon and hairline carry the danger tint.
struct LoopdyInlineNotice: View {
    enum Tone { case danger, warning }

    let message: String
    var tone: Tone = .danger
    var actionTitle: String?
    var actionIdentifier: String?
    var isActionEnabled = true
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoopdyTokens.space8) {
            Image(systemName: tone == .danger ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .loopdyFont(.metadata)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .loopdyFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .buttonStyle(.plain)
                    .frame(minHeight: LoopdyTokens.hitTarget)
                    .contentShape(.rect)
                    .disabled(!isActionEnabled)
                    .accessibilityIdentifier(actionIdentifier ?? "")
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, LoopdyTokens.space12)
        .padding(.trailing, onDismiss == nil ? LoopdyTokens.space12 : LoopdyTokens.space4)
        .padding(.vertical, onDismiss == nil && actionTitle == nil ? LoopdyTokens.space8 : 0)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: LoopdyTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoopdyTokens.radius16, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: LoopdyTokens.hairline)
        }
        .accessibilityElement(children: action == nil && onDismiss == nil ? .combine : .contain)
    }

    private var tint: Color { tone == .danger ? theme.danger : theme.warning }

    @LoopdyThemeReader private var theme
}

/// iMessage-style tactile press: a brief scale-down with no color change.
/// Honors Reduce Motion by dimming instead of scaling.
struct LoopdyPressFeedbackStyle: ButtonStyle {
    /// Compact glyph controls use the full press; larger tiles use a subtler one.
    var pressedScale: CGFloat = 0.88

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LoopdyPressFeedbackStyle {
    static var loopdyPress: LoopdyPressFeedbackStyle { LoopdyPressFeedbackStyle() }
    static var loopdyTilePress: LoopdyPressFeedbackStyle { LoopdyPressFeedbackStyle(pressedScale: 0.96) }
}

/// iOS Settings-style glyph tile: a white symbol on a small accent square.
struct LoopdyIconTile: View {
    let systemName: String
    var tint: Color?

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: side * 0.52, weight: .semibold))
            // Accent tiles use the accent's own ink (ink on after-dark lavender).
            .foregroundStyle(tint == nil ? theme.actionForeground : .white)
            .frame(width: side, height: side)
            .background(
                (tint ?? theme.action).opacity(colorSchemeContrast == .increased ? 1 : 0.92),
                in: .rect(cornerRadius: side * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @LoopdyThemeReader private var theme
}

/// Builds its content in its own SwiftUI update and erases its type.
///
/// Large grouped screens otherwise compile (in Release) into one function that
/// holds every section's view value on the stack at once and one enormous nested
/// generic type. On device the 1 MB main-thread stack can overflow while that
/// type is resolved. Wrapping each section keeps the parent small; List and
/// Form still see the Section inside.
struct LoopdyDeferredSection: View {
    private let make: () -> AnyView

    init<Content: View>(@ViewBuilder _ content: @escaping () -> Content) {
        make = { AnyView(content()) }
    }

    var body: some View { make() }
}
