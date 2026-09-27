import SwiftUI

// Still consumed by SpectrumAction outside primary navigation.
enum FloatingTabBarActionSurface: Equatable, Sendable {
    case neutralGlass
}

enum FloatingTabBarActionForeground: Equatable, Sendable {
    case themeAccent
}

struct FloatingTabBarActionPresentation: Equatable, Sendable {
    let surface: FloatingTabBarActionSurface
    let foreground: FloatingTabBarActionForeground
    let usesGradient: Bool
    let showsBorder: Bool
    let usesGlow: Bool
}

enum FloatingTabBarBackgroundSurface: Equatable, Sendable {
    case regularLiquidGlass
    case regularMaterial
    case thickMaterial
    case opaque
}

struct FloatingTabBar: View {
    static let newChatVisibleLabel = "New chat"
    static let newChatAccessibilityLabel = "New chat"
    static let selectionShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    static func newChatPresentation(for _: BighelpThemeID) -> FloatingTabBarActionPresentation {
        FloatingTabBarActionPresentation(surface: .neutralGlass, foreground: .themeAccent,
                                        usesGradient: false, showsBorder: false, usesGlow: false)
    }

    static func backgroundSurface(
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> FloatingTabBarBackgroundSurface {
        if reduceTransparency { return .opaque }
        if supportsLiquidGlass { return .regularLiquidGlass }
        return increasedContrast ? .thickMaterial : .regularMaterial
    }

    /// The shell reserves navigation space only at the root, never over a pushed chat or keyboard.
    static func isRootBarVisible(for path: [AppRoute]) -> Bool {
        path.isEmpty
    }

    @Binding var selection: AppTab
    let onNewChat: (() -> Void)?
    /// Points the bar drops into the home indicator's area.
    let homeIndicatorSink: CGFloat

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var tabChanges = 0
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var captionHeight: CGFloat = 28

    init(selection: Binding<AppTab>, onNewChat: (() -> Void)? = nil, homeIndicatorSink: CGFloat = 0) {
        self._selection = selection
        self.onNewChat = onNewChat
        self.homeIndicatorSink = homeIndicatorSink
    }

    /// Like the system tab bar, the bar sits low, just above the home
    /// indicator, instead of a full safe-area inset above it. Clamped so a
    /// keyboard's inset never pushes it off screen.
    static func homeIndicatorSink(forBottomInset inset: CGFloat) -> CGFloat {
        min(max(0, inset - 14), 20)
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            // Five icons in one row, like a dock; names stay in VoiceOver and
            // the large content viewer.
            navigationRow(constrainsWidth: true) {
                ForEach(AppTab.allCases) { tab in
                    destination(tab, showsCaption: false)
                }
            }
            .padding(6)
            .bighelpNavigationGlass(in: Capsule())
            .sensoryFeedback(.selection, trigger: tabChanges)
            if let onNewChat {
                RootComposeButton { onNewChat() }
                    .accessibilityShowsLargeContentViewer {
                        Label(Self.newChatVisibleLabel, systemImage: "square.and.pencil")
                    }
            }
        }
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
        .accessibilityIdentifier("primary-navigation")
        .padding(.horizontal, 12)
        .padding(.vertical, isVerticallyCompact ? 4 : 8)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -homeIndicatorSink)
    }

    private var isVerticallyCompact: Bool { verticalSizeClass == .compact }

    private func navigationRow<Content: View>(
        constrainsWidth: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = NavigationRowLayout(constrainsWidth: constrainsWidth)
        return layout { content() }
    }


    private func destination(_ tab: AppTab, showsCaption: Bool = true) -> some View {
        let isSelected = selection == tab
        return Button {
            BighelpKeyboard.dismiss()
            if selection != tab { tabChanges += 1 }
            withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) {
                selection = tab
            }
        } label: {
            itemLabel(title: tab.title, symbol: tab.systemImage(selected: isSelected),
                      identifier: tab.accessibilityIdentifier, selected: isSelected,
                      showsCaption: showsCaption)
        }
        .buttonStyle(.bighelpTilePress)
        .accessibilityLabel(tab.title)
        .accessibilityShowsLargeContentViewer {
            Label(tab.title, systemImage: tab.systemImage(selected: isSelected))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    // Destinations share the existing neutral surface and equal touch targets.
    private func itemLabel(
        title: String, symbol: String, identifier: String, selected: Bool, showsCaption: Bool
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .frame(width: min(iconSize, 28), height: min(iconSize, 28))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityIdentifier(identifier + ".icon")
            if showsCaption {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(height: captionHeight)
                    .accessibilityIdentifier(identifier + ".label")
            }
        }
        .foregroundStyle(selected ? (increasedContrast ? Color.primary : theme.action) : Color.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, isVerticallyCompact ? 4 : 10)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
        .background {
            if selected {
                Self.selectionShape
                    .fill(increasedContrast ? Color.primary.opacity(0.18) : theme.action.opacity(0.14))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    @BighelpThemeReader private var theme
}

/// The labelled row reports its ideal width; the icon fallback respects its proposal.
/// Every destination gets the same measured width and height.
struct NavigationRowLayout: Layout {
    var constrainsWidth = false

    static func fittingSize(
        proposedWidth: CGFloat?, itemSizes: [CGSize], constrainsWidth: Bool = false
    ) -> CGSize {
        let requiredWidth = (itemSizes.map(\.width).max() ?? 44) * CGFloat(itemSizes.count)
        let availableWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? requiredWidth
        let width = constrainsWidth
            ? max(44 * CGFloat(itemSizes.count), availableWidth)
            : max(availableWidth, requiredWidth)
        return CGSize(width: width,
                      height: itemSizes.map(\.height).max() ?? 44)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = Self.fittingSize(
            proposedWidth: proposal.width,
            itemSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            constrainsWidth: constrainsWidth
        )
        guard constrainsWidth, !subviews.isEmpty else { return ideal }
        let cellProposal = ProposedViewSize(width: ideal.width / CGFloat(subviews.count), height: nil)
        return Self.fittingSize(
            proposedWidth: ideal.width,
            itemSizes: subviews.map { $0.sizeThatFits(cellProposal) },
            constrainsWidth: true
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

extension View {
    /// Neutral native navigation glass with an optional interactive response.
    /// No custom tint, glow or shadow; all consumers share its fallbacks.
    func bighelpNavigationGlass<S: InsettableShape>(in shape: S, isInteractive: Bool = false) -> some View {
        modifier(BighelpNavigationGlass(shape: shape, isInteractive: isInteractive))
    }
}

private struct BighelpNavigationGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content.modifier(NavigationSurface(
            shape: shape,
            isInteractive: isInteractive,
            surface: FloatingTabBar.backgroundSurface(
                supportsLiquidGlass: supportsLiquidGlass,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            ),
            increasedContrast: colorSchemeContrast == .increased
        ))
    }

    private var supportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

private struct NavigationSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let surface: FloatingTabBarBackgroundSurface
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        surfaced(content)
            .overlay {
                if increasedContrast {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        switch surface {
        case .opaque:
            content.background(Color(uiColor: .systemBackground), in: shape)
        case .regularMaterial:
            content.background(.regularMaterial, in: shape)
        case .thickMaterial:
            content.background(.thickMaterial, in: shape)
        case .regularLiquidGlass:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
            #else
            content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

private extension AppTab {
    var title: String {
        switch self {
        case .home: "Activity"
        case .agents: "Agents"
        case .sessions: "Chat"
        case .inbox: "Inbox"
        case .profile: "Settings"
        case .scheduledTasks: "Tasks"
        case .workspace: "Workspace"
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .apps: "Apps"
        }
    }

    func systemImage(selected: Bool) -> String {
        switch (self, selected) {
        case (.home, true): "waveform.path"
        case (.home, false): "waveform.path"
        case (.agents, true): "person.2.fill"
        case (.agents, false): "person.2"
        case (.sessions, true): "bubble.left.fill"
        case (.sessions, false): "bubble.left"
        case (.inbox, true): "tray.full.fill"
        case (.inbox, false): "tray"
        case (.profile, true): "gearshape.fill"
        case (.profile, false): "gearshape"
        case (.scheduledTasks, _): "calendar.badge.clock"
        case (.workspace, true): "square.grid.2x2.fill"
        case (.workspace, false): "square.grid.2x2"
        case (.feed, true): "newspaper.fill"
        case (.feed, false): "newspaper"
        case (.ideas, true): "lightbulb.fill"
        case (.ideas, false): "lightbulb"
        case (.goals, true): "checkmark.square.fill"
        case (.goals, false): "checkmark.square"
        case (.apps, true): "square.on.circle.fill"
        case (.apps, false): "square.on.circle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .home: "tab.home"
        case .agents: "tab.agents"
        case .sessions: "tab.sessions"
        case .inbox: "tab.inbox"
        case .profile: "tab.profile"
        case .scheduledTasks: "tab.scheduled-tasks"
        case .workspace: "tab.workspace"
        case .feed: "tab.feed"
        case .ideas: "tab.ideas"
        case .goals: "tab.goals"
        case .apps: "tab.apps"
        }
    }
}
