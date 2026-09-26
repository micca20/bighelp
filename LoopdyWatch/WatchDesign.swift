import SwiftUI

enum WatchDesign {
    static let minimumControlHeight: CGFloat = 44
    enum Spacing {
        static let tight: CGFloat = 3
        static let compact: CGFloat = 6
        static let standard: CGFloat = 8
        static let section: CGFloat = 10
    }

    enum Radius {
        static let card: CGFloat = 16
        static let button: CGFloat = 16
    }

    enum Color {
        static let canvas = SwiftUI.Color.black
        static let cardTop = SwiftUI.Color(red: 0.13, green: 0.13, blue: 0.13)
        static let cardBottom = SwiftUI.Color(red: 0.075, green: 0.075, blue: 0.075)
        static let raised = SwiftUI.Color(red: 0.17, green: 0.17, blue: 0.18)
        static let border = SwiftUI.Color.white.opacity(0.11)
        static let secondaryText = SwiftUI.Color.white.opacity(0.66)
        static let tertiaryText = SwiftUI.Color.white.opacity(0.44)
        static let orange = SwiftUI.Color(red: 1.0, green: 0.48, blue: 0.12)
        static let yellow = SwiftUI.Color(red: 1.0, green: 0.68, blue: 0.12)
        static let pink = SwiftUI.Color(red: 1.0, green: 0.18, blue: 0.40)
        static let danger = SwiftUI.Color(red: 1.0, green: 0.36, blue: 0.31)
    }

    static let warmGradient = LinearGradient(
        colors: [Color.yellow, Color.orange, Color.pink],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let avatarGradient = LinearGradient(
        colors: [Color.orange, Color.pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [Color.cardTop, Color.cardBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct WatchCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(WatchDesign.cardGradient)
            .clipShape(RoundedRectangle(cornerRadius: WatchDesign.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: WatchDesign.Radius.card)
                    .stroke(WatchDesign.Color.border, lineWidth: 1)
            }
    }
}

extension View {
    func watchCard(padding: CGFloat = WatchDesign.Spacing.section) -> some View {
        modifier(WatchCardModifier(padding: padding))
    }
}
