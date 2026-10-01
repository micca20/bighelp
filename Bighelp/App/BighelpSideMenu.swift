import Observation
import SwiftUI

/// Vision Pro and Mac: ☰ opens as a column beside the app instead of covering
/// it. The chat or list stays visible, only narrower. On the Mac it's the
/// window's sidebar: it stays open while you pick chats and pages.
@MainActor
@Observable
final class BighelpSideMenu {
    private(set) var content: AnyView?
    @ObservationIgnored private var onClose: (@MainActor () -> Void)?

    var isOpen: Bool { content != nil }

    func show(_ view: AnyView, onClose: @escaping @MainActor () -> Void) {
        content = view
        self.onClose = onClose
    }

    func hide() {
        guard content != nil else { return }
        content = nil
        let close = onClose
        onClose = nil
        close?()
    }
}

extension EnvironmentValues {
    @Entry var bighelpSideMenu: BighelpSideMenu? = nil
}

/// Lays the open menu beside the window's content on Vision Pro and Mac;
/// elsewhere it changes nothing.
struct BighelpSideMenuHost: ViewModifier {
    let menu: BighelpSideMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Mac's sidebar widens with bigger text so rows don't wrap.
    static var width: CGFloat {
        #if targetEnvironment(macCatalyst)
        min(max(330 * BighelpInterfaceSize.shared.textSize.macFactor / BighelpTextSize.standard.macFactor, 300), 420)
        #else
        340
        #endif
    }

    func body(content: Content) -> some View {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            if let panel = menu.content {
                panel
                    .frame(width: Self.width)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            content
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: menu.isOpen)
        .environment(\.bighelpSideMenu, menu)
        #else
        content
        #endif
    }
}

/// The Mac opens its sidebar the way you left it (open the first time), once
/// there's a host: during first-run onboarding and host setup it has nothing to offer.
struct MacSidebarMemory: ViewModifier {
    @Binding var isOpen: Bool
    let canShow: Bool
    @AppStorage("bighelp.mac.sidebar-open") private var savedOpen = true

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .onAppear { if canShow, savedOpen, !isOpen { isOpen = true } }
            .onChange(of: canShow) { _, canShow in
                if canShow { if savedOpen { isOpen = true } } else { isOpen = false }
            }
            // Closing it for onboarding isn't your choice, so it isn't remembered.
            .onChange(of: isOpen) { _, open in if canShow { savedOpen = open } }
        #else
        content
        #endif
    }
}
