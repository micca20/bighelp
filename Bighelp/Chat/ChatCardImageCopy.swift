import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// Touch and hold a card for Copy as Image: a PNG of the card, ready to
    /// paste into Messages or Mail. `card` draws it again at its current width.
    func cardImageCopy<Card: View>(_ card: Card) -> some View {
        modifier(ChatCardImageCopy(card: card))
    }
}

private struct ChatCardImageCopy<Card: View>: ViewModifier {
    let card: Card
    @Environment(\.self) private var environment
    @Environment(\.displayScale) private var displayScale
    @BighelpThemeReader private var theme
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contextMenu {
                Button {
                    guard let png = ChatCardImage.png(card, width: width, scale: displayScale,
                                                     background: theme.canvas, environment: environment) else { return }
                    UIPasteboard.general.setItems([[UTType.png.identifier: png]])
                    BighelpHaptics.success()
                    UIAccessibility.post(notification: .announcement, argument: "Card copied as an image")
                } label: {
                    Label("Copy as Image", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("chat.card.copy-image")
            }
            .accessibilityAction(named: "Copy as Image") {
                if let png = ChatCardImage.png(card, width: width, scale: displayScale,
                                               background: theme.canvas, environment: environment) {
                    UIPasteboard.general.setItems([[UTType.png.identifier: png]])
                }
            }
    }
}

@MainActor
enum ChatCardImage {
    /// The card on the chat's own background with a little room around it,
    /// drawn at the screen's scale.
    static func png<Card: View>(_ card: Card, width: CGFloat, scale: CGFloat, background: Color,
                                environment: EnvironmentValues) -> Data? {
        guard width > 0 else { return nil }
        let renderer = ImageRenderer(content: card
            .frame(width: width)
            .padding(16)
            .background(background)
            .environment(\.self, environment))
        renderer.scale = max(scale, 2)
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }
}
