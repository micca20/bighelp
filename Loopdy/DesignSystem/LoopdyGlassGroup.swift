import SwiftUI

/// Groups sibling glass controls without introducing another glass surface.
/// Reading content and single-surface bars do not need a glass container.
struct LoopdyGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let isEnabled: Bool
    private let content: Content

    init(spacing: CGFloat = 12, isEnabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.isEnabled = isEnabled
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), isEnabled {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
