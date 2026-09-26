import SwiftUI
import WidgetKit

/// The app's colors for widgets: the bubble color and the Cream/Paper or
/// Graphite/Black page picked in Settings › Colors. Tinted and Lock Screen
/// widgets fall back to the system's own styles.
struct LoopdyWidgetColors: Sendable {
    let canvas: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    let accentForeground: Color
    let isFullColor: Bool

    static let fallback = LoopdyWidgetColors(palette: .emberLight, isFullColor: true)

    init(snapshot: LoopdyWidgetSnapshot, scheme: ColorScheme, isFullColor: Bool) {
        let palette = scheme == .dark
            ? snapshot.darkPalette ?? .emberDark
            : snapshot.lightPalette ?? .emberLight
        self.init(palette: palette, isFullColor: isFullColor)
    }

    private init(palette: LoopdyWidgetSnapshot.Palette, isFullColor: Bool) {
        self.isFullColor = isFullColor
        if isFullColor {
            canvas = Color(widgetHex: palette.canvasHex)
            primary = Color(widgetHex: palette.primaryTextHex)
            secondary = Color(widgetHex: palette.secondaryTextHex)
            accent = Color(widgetHex: palette.accentHex)
            accentForeground = Color(widgetHex: palette.accentForegroundHex)
        } else {
            canvas = .clear
            primary = .primary
            secondary = .secondary
            accent = .primary
            accentForeground = .black
        }
    }
}

extension LoopdyWidgetSnapshot.Palette {
    static let emberLight = Self(canvasHex: "FFF9F5", surfaceHex: "FFFFFF", primaryTextHex: "1C1A19",
                                 secondaryTextHex: "6F6762", accentHex: "7B52E0", accentForegroundHex: "FFFFFF")
    static let emberDark = Self(canvasHex: "1C1C1F", surfaceHex: "27272B", primaryTextHex: "F4F4F6",
                                secondaryTextHex: "A3A3AA", accentHex: "C9B6FF", accentForegroundHex: "1C1A19")
}

private struct LoopdyWidgetColorsKey: EnvironmentKey {
    static let defaultValue = LoopdyWidgetColors.fallback
}

extension EnvironmentValues {
    var loopdyWidgetColors: LoopdyWidgetColors {
        get { self[LoopdyWidgetColorsKey.self] }
        set { self[LoopdyWidgetColorsKey.self] = newValue }
    }
}

extension Color {
    /// "RRGGBB" or "#RRGGBB"; anything else draws gray.
    init(widgetHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Every widget's frame: the app's page color with a soft glow of the bubble
/// color, text in the app's colors, and the colors in the environment.
struct LoopdyWidgetScaffold<Content: View>: View {
    let snapshot: LoopdyWidgetSnapshot
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let colors = LoopdyWidgetColors(snapshot: snapshot, scheme: scheme, isFullColor: mode == .fullColor)
        content
            .environment(\.loopdyWidgetColors, colors)
            .foregroundStyle(colors.primary)
            .tint(colors.accent)
            .containerBackground(for: .widget) {
                if colors.isFullColor, !family.isAccessory {
                    ZStack {
                        colors.canvas
                        RadialGradient(colors: [colors.accent.opacity(scheme == .dark ? 0.22 : 0.14), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: 220)
                    }
                } else {
                    Color.clear
                }
            }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }
}

/// The agent's real picture (or its initial), ringed in the bubble color with
/// a badge for the work while it runs.
struct LoopdyWidgetAvatar: View {
    let agentID: String?
    let name: String
    let diameter: CGFloat
    var pose: LoopdyActivityPose? = nil

    @Environment(\.loopdyWidgetColors) private var colors

    var body: some View {
        face
            .frame(width: diameter, height: diameter)
            .padding(pose == nil ? 0 : ringGap)
            .overlay {
                if pose != nil {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [colors.accent, colors.accent.opacity(0.15), colors.accent],
                                                      center: .center),
                                      lineWidth: max(2, diameter * 0.05))
                        .widgetAccentable()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let pose {
                    Image(systemName: pose.symbolName)
                        .font(.system(size: max(9, diameter * 0.2), weight: .bold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: max(18, diameter * 0.36), height: max(18, diameter * 0.36))
                        .background(Circle().fill(colors.accent))
                        .overlay(Circle().strokeBorder(colors.canvas, lineWidth: colors.isFullColor ? 2 : 0))
                        .widgetAccentable()
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }

    private var ringGap: CGFloat { max(3, diameter * 0.07) }

    @ViewBuilder
    private var face: some View {
        if let agentID, let image = LoopdyActivityAvatarStore.image(agentID: agentID) {
            Image(uiImage: image)
                .resizable()
                .loopdyWidgetFullColor()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Text(String(name.first ?? "b").uppercased())
                .font(.system(size: diameter * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(colors.accentForeground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(colors.accent.gradient))
                .widgetAccentable()
        }
    }
}

extension Image {
    /// Photos keep their colors on a tinted Home Screen (iOS 18 and later).
    @ViewBuilder
    func loopdyWidgetFullColor() -> some View {
        if #available(iOS 18.0, *) {
            widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}

/// A small uppercase section title.
struct LoopdyWidgetSectionTitle: View {
    let title: String
    var symbol: String? = nil
    @Environment(\.loopdyWidgetColors) private var colors

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).foregroundStyle(colors.accent).widgetAccentable() }
            Text(title.uppercased()).tracking(0.6).foregroundStyle(colors.secondary)
        }
        .font(.system(size: 10, weight: .bold))
        .lineLimit(1)
    }
}

extension LoopdyWidgetSnapshot {
    /// The default agent's running chat, if any, else any running chat.
    var agentRunningSession: Session? {
        let running = runningSessions.sorted { $0.updatedAt > $1.updatedAt }
        return running.first { $0.agentID != nil && $0.agentID == defaultAgentID } ?? running.first
    }

    /// What the default agent is doing, nil while idle.
    var agentPose: LoopdyActivityPose? {
        guard let session = agentRunningSession else { return nil }
        return session.activity.flatMap(LoopdyActivityPose.init(rawValue:)) ?? .thinking
    }

    var agentDisplayName: String { defaultAgentName ?? "Your agent" }
}
