import SwiftUI

/// The Mac window (Mac Catalyst, "Optimize for Mac"): no title text over the
/// app's own header, a size floor, a roomy first size, and icon menus that look
/// like the buttons beside them instead of Mac pull-down buttons.
struct BighelpMacWindowStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .menuStyle(BighelpMacMenuStyle())
            .menuIndicator(.hidden)
            .background(MacWindowConfigurator().allowsHitTesting(false).accessibilityHidden(true))
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// A menu draws exactly its label, as on iPhone and iPad; the Mac's pull-down
/// style would put a bezel inside the app's own round buttons. Its whole label
/// (at least 28 points each way) opens it and lights up under the pointer.
private struct BighelpMacMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.button).buttonStyle(MenuLabelStyle())
            .bighelpHover(in: Capsule())
    }

    /// Draws the label as `.plain` does, at least 28 points each way: the Mac
    /// opens a menu from its label's frame, so a bare "…" glyph was a sliver.
    /// A menu hands its label only to a `ButtonStyle` (a primitive style gets
    /// just its title).
    private struct MenuLabelStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(minWidth: BighelpPointer.minimumTarget, minHeight: BighelpPointer.minimumTarget)
                .contentShape(.rect)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

private struct MacWindowConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowConfiguringView { WindowConfiguringView() }
    func updateUIView(_ view: WindowConfiguringView, context: Context) {}

    final class WindowConfiguringView: UIView {
        private static let sizedKey = "bighelp.mac.window-first-size"

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard let scene = window?.windowScene else { return }
            scene.titlebar?.titleVisibility = .hidden
            scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 600)
            // macOS remembers the window's frame after this; only the very first
            // launch opens at a comfortable size instead of the 1024×768 default.
            guard !UserDefaults.standard.bool(forKey: Self.sizedKey) else { return }
            // A request made while the window is still being set up is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak scene] in
                guard let scene else { return }
                let screen = scene.screen.bounds
                let size = CGSize(width: min(1280, screen.width * 0.9), height: min(900, screen.height * 0.88))
                let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height)
                scene.requestGeometryUpdate(.Mac(systemFrame: frame))
                UserDefaults.standard.set(true, forKey: Self.sizedKey)
            }
        }
    }
}
#endif
