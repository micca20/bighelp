import SwiftUI

/// A small spinner: a quarter arc turning over a faint ring, on the shared
/// loader clock. Still loaders show the arc resting at the top.
struct BighelpSpinner: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.6
    /// Defaults to the current foreground style, like text beside it.
    var color: Color?
    var trackOpacity: Double = 0.25
    var period: TimeInterval = BighelpLoaderTiming.stepSpin

    var body: some View {
        BighelpLoaderClock(cadence: .smooth) { time in
            arc
                .frame(width: size, height: size)
                .rotationEffect(.degrees(360 * time.phase(period)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var arc: some View {
        let drawing = ZStack {
            Circle().strokeBorder(lineWidth: lineWidth).opacity(trackOpacity)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: 0.25)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-135))
        }
        if let color { drawing.foregroundStyle(color) } else { drawing }
    }
}
