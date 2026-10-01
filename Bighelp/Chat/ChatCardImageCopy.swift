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
            .environment(\.isCardSnapshot, true)
            .frame(width: width)
            .padding(16)
            .background(background)
            .environment(\.self, environment))
        renderer.scale = max(scale, 2)
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }
}

extension EnvironmentValues {
    /// True while a card is drawn for Copy as Image. An image can't scroll, and
    /// ImageRenderer leaves scroll views blank, so sideways rows lay out flat (#17).
    @Entry var isCardSnapshot = false
}

/// A card row that scrolls sideways on screen and wraps onto more lines when
/// the card becomes an image, so nothing it shows goes missing.
struct CardScrollingRow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.isCardSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            CardWrappingLayout(spacing: spacing) { content }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: spacing) { content }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Left to right, starting a new line when one is full.
private struct CardWrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, width: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                lines.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
