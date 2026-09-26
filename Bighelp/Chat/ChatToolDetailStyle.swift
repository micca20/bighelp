import SwiftUI

/// Work evidence deliberately keeps its V2 typography inside the shipping V3 canvas.
struct ChatToolDetailStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.bighelpUIV3Enabled, false)
    }
}
