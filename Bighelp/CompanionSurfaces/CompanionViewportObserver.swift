import SwiftUI
import UIKit

/// Scroll containers may retain an appeared child after it leaves the viewport.
struct CompanionViewportObserver: ViewModifier {
    @Binding var isInViewport: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if os(visionOS) // Always has scroll visibility; there's no UIScreen.
        content.onScrollVisibilityChange(threshold: 0.01) { isInViewport = $0 }
        #else
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { isInViewport = $0 }
        } else {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                            isInViewport = !frame.isEmpty && frame.intersects(UIScreen.main.bounds)
                        }
                }
                .allowsHitTesting(false)
            }
        }
        #endif
    }
}
