import SwiftUI
import UIKit

// Small differences between iPhone/iPad and Vision Pro, kept in one place.

extension View {
    /// Vision Pro's keyboard floats apart from the window, so scrolling
    /// never needs to put it away there.
    @ViewBuilder
    func dismissesKeyboardOnScroll(_ dismisses: Bool) -> some View {
        #if os(visionOS)
        self
        #else
        scrollDismissesKeyboard(dismisses ? .interactively : .never)
        #endif
    }
}

/// Taps and confirmations you can feel. Vision Pro has no haptics, so these
/// do nothing there.
@MainActor
enum BighelpHaptics {
    static func success() {
        #if !os(visionOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func tap(rigid: Bool = false) {
        #if !os(visionOS)
        UIImpactFeedbackGenerator(style: rigid ? .rigid : .light).impactOccurred()
        #endif
    }
}
