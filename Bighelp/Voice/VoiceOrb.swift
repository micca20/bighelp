import SwiftUI

struct VoiceOrb: View {
    let status: VoiceStatus
    let isSessionActive: Bool
    let inputLevel: Float
    let size: CGFloat

    @State private var isSurfaceVisible = false

    init(
        status: VoiceStatus,
        isSessionActive: Bool,
        inputLevel: Float = 0,
        size: CGFloat = 208
    ) {
        self.status = status
        self.isSessionActive = isSessionActive
        self.inputLevel = inputLevel
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            theme.action.opacity(0.18),
                            theme.information.opacity(0.10),
                            theme.canvas.opacity(0.02)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.52
                    )
                )
                .overlay {
                    Circle()
                        .stroke(theme.border.opacity(0.75), lineWidth: BighelpTokens.hairline)
                }
            BighelpThinkingOrb(
                scenario: VoiceOrbPresentation.scenario(for: status),
                isPaused: !shouldRenderMotion,
                displaySize: Double(size * 0.72)
            )
            .scaleEffect(listeningScale)
        }
        .frame(width: size, height: size)
        .onAppear { isSurfaceVisible = true }
        .onDisappear { isSurfaceVisible = false }
        .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme

    private var shouldRenderMotion: Bool {
        isSurfaceVisible
            && isSessionActive
            && status.usesContinuousMotion
    }

    private var listeningScale: CGFloat {
        guard status == .listening else { return 1 }
        return 1 + CGFloat(min(max(inputLevel, 0), 1)) * 0.05
    }
}

private extension VoiceStatus {
    var usesContinuousMotion: Bool {
        switch self {
        case .listening, .working, .speaking:
            true
        case .paused, .unavailable:
            false
        }
    }
}

/// The brand-kit voice waveform: 28 rounded bars whose silhouette is fixed and
/// whose height follows a real audio level (microphone or playback). A zero
/// level renders a quiet resting line; nothing animates on its own.
struct VoiceWaveformBars: View {
    let level: Double
    let color: Color
    var width: CGFloat = 220
    var height: CGFloat = 44

    static let barCount = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // While there's sound the bars ripple one by one, not just grow together.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || level < 0.02)) { context in
            bars(phase: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: width, height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func bars(phase: Double) -> some View {
        let slot = width / CGFloat(Self.barCount)
        let amplitude = min(max(level, 0), 1)
        return HStack(alignment: .center, spacing: 0) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(
                        width: max(2, slot * 0.45),
                        height: max(3, height * Self.barHeight(index, amplitude: amplitude, phase: phase))
                    )
                    .frame(width: slot, height: height)
            }
        }
    }

    /// At rest the kit's silhouette at 18%; sound lifts each bar with its own wobble.
    static func barHeight(_ index: Int, amplitude: Double, phase: Double) -> CGFloat {
        let wobble = phase == 0 ? 1 : 0.6 + 0.4 * sin(phase * 9 + Double(index) * 0.8)
        return silhouette(index) * CGFloat(0.18 + 0.82 * amplitude * wobble)
    }

    /// The microphone meter is raw loudness: speech sits near 0.03–0.15, so
    /// linear bars barely moved. Show it on a loudness scale (-55 dB to -15 dB).
    static func displayLevel(microphone level: Float) -> Double {
        let rms = Double(level) / 3.2
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 55) / 40, 0), 1)
    }

    /// Same deterministic silhouette as the kit's `bars()` helper.
    static func silhouette(_ index: Int) -> CGFloat {
        let i = Double(index)
        return CGFloat(0.25 + 0.75 * abs(sin(i * 1.7)) * (0.4 + 0.6 * abs(cos(i * 0.6))))
    }
}

/// Voice stage backdrop. Light: the canvas fading into a 12% wash of the
/// agent's color. Dark: an agent-color glow behind the avatar on near-black.
struct VoiceStageBackground: View {
    let agentColor: Color

    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if theme.isDarkPalette {
                ZStack {
                    Color(hex: "0B0A0A")
                    RadialGradient(
                        colors: [agentColor.opacity(0.32), agentColor.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 0.38),
                        startRadius: 0,
                        endRadius: 420
                    )
                }
            } else {
                LinearGradient(
                    stops: [
                        .init(color: theme.canvas, location: 0.3),
                        .init(color: agentColor.opacity(0.12), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .background(theme.canvas)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// What the agent's face acts out in voice mode: talking while it speaks, the
/// chat's current work (thinking, writing code, browsing…) while it works.
enum VoiceAvatarActivity {
    static func resolve(isSpeaking: Bool, isWorking: Bool, chatActivity: AgentActivityKind) -> AgentActivityKind {
        if isSpeaking { return .replying }
        guard isWorking else { return .idle }
        // The chat says "replying" while text streams; out loud that's still work.
        return chatActivity == .idle || chatActivity == .replying ? .thinking : chatActivity
    }
}
