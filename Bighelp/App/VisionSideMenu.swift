import Observation
import SwiftUI

/// Vision Pro: ☰ opens as a column beside the app instead of covering it. The
/// chat or list stays visible, only narrower, as on a wide iPad.
@MainActor
@Observable
final class VisionSideMenu {
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
    @Entry var visionSideMenu: VisionSideMenu? = nil
}

/// Lays the open menu beside the window's content on Vision Pro; elsewhere it
/// changes nothing.
struct VisionSideMenuHost: ViewModifier {
    let menu: VisionSideMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340

    func body(content: Content) -> some View {
        #if os(visionOS)
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
        .environment(\.visionSideMenu, menu)
        #else
        content
        #endif
    }
}
