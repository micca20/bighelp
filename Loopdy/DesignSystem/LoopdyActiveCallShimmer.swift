import SwiftUI

enum LoopdyActiveCallShimmerPolicy {
    static func isAnimated(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }
}

struct LoopdyActiveCallShimmer: ViewModifier {
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if LoopdyActiveCallShimmerPolicy.isAnimated(
                    isActive: isActive,
                    reduceMotion: reduceMotion
                ) {
                    GeometryReader { geometry in
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            let duration = 1.7
                            let progress = CGFloat(
                                timeline.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: duration) / duration
                            )
                            LinearGradient(
                                colors: [.clear, color.opacity(0.72), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(width: max(44, geometry.size.width * 0.38))
                            .offset(x: (geometry.size.width * 1.45 * progress) - geometry.size.width * 0.4)
                        }
                    }
                    .mask(content.accessibilityHidden(true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func loopdyActiveCallShimmer(isActive: Bool, color: Color) -> some View {
        modifier(LoopdyActiveCallShimmer(isActive: isActive, color: color))
    }
}
