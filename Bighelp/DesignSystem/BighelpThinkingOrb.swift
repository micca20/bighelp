import SwiftUI
import ThinkingOrbsKit

enum BighelpThinkingOrbScenario: Sendable, Equatable {
    case working
    case searching
    case reasoning
    case listening
    case connecting
    case coordinating
    case composing
    case waiting
    case shaping
}

enum BighelpThinkingOrbScale: Sendable {
    case inline
    case standard
}

enum BighelpThinkingOrbSurface: Sendable, Equatable {
    case automatic
    case light
    case dark

    var packageTheme: OrbTheme {
        switch self {
        case .automatic:
            .auto
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

extension BighelpTheme {
    var actionThinkingOrbSurface: BighelpThinkingOrbSurface {
        let normalized = actionForegroundHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return .automatic
        }
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        let perceivedBrightness = (red * 299 + green * 587 + blue * 114) / 1_000
        return perceivedBrightness >= 128 ? .dark : .light
    }
}

struct BighelpThinkingOrbPresentation: Sendable {
    let state: OrbState
    let size: OrbSize
    let displaySize: Double?
    let visibleLabel: String?

    var hidesOrbFromAccessibility: Bool {
        visibleLabel != nil
    }

    static func resolve(
        scenario: BighelpThinkingOrbScenario,
        scale: BighelpThinkingOrbScale,
        visibleLabel: String? = nil
    ) -> Self {
        Self(
            state: state(for: scenario),
            size: size(for: scale),
            displaySize: nil,
            visibleLabel: visibleLabel
        )
    }

    static func shouldPause(
        explicitly: Bool,
        scenePhase: ScenePhase
    ) -> Bool {
        explicitly || scenePhase != .active
    }

    private static func state(for scenario: BighelpThinkingOrbScenario) -> OrbState {
        switch scenario {
        case .working:
            .working
        case .searching:
            .searching
        case .reasoning:
            .solving
        case .listening:
            .listening
        case .connecting:
            .connecting
        case .coordinating:
            .weaving
        case .composing:
            .composing
        case .waiting:
            .breathing
        case .shaping:
            .shaping
        }
    }

    private static func size(for scale: BighelpThinkingOrbScale) -> OrbSize {
        switch scale {
        case .inline:
            .px20
        case .standard:
            .px64
        }
    }
}

struct BighelpThinkingOrb: View {
    let scenario: BighelpThinkingOrbScenario
    let scale: BighelpThinkingOrbScale
    let speed: Double
    let isPaused: Bool
    let displaySize: Double?
    let visibleLabel: String?
    let surface: BighelpThinkingOrbSurface
    let tint: Color?

    @Environment(\.scenePhase) private var scenePhase

    init(
        scenario: BighelpThinkingOrbScenario,
        scale: BighelpThinkingOrbScale = .standard,
        speed: Double = 1,
        isPaused: Bool = false,
        displaySize: Double? = nil,
        visibleLabel: String? = nil,
        surface: BighelpThinkingOrbSurface = .automatic,
        tint: Color? = nil
    ) {
        self.scenario = scenario
        self.scale = scale
        self.speed = speed
        self.isPaused = isPaused
        self.displaySize = displaySize
        self.visibleLabel = visibleLabel
        self.surface = surface
        self.tint = tint
    }

    @ViewBuilder
    var body: some View {
        let presentation = BighelpThinkingOrbPresentation.resolve(
            scenario: scenario,
            scale: scale,
            visibleLabel: visibleLabel
        )

        if let visibleLabel = presentation.visibleLabel {
            HStack(spacing: BighelpTokens.space8) {
                orb(for: presentation)
                    .accessibilityHidden(presentation.hidesOrbFromAccessibility)
                Text(verbatim: visibleLabel)
            }
        } else {
            orb(for: presentation)
        }
    }

    private func orb(for presentation: BighelpThinkingOrbPresentation) -> some View {
        BighelpThinkingMark(
            scenario: scenario,
            displaySize: CGFloat(
                displaySize ?? presentation.displaySize ?? Double(presentation.size.rawValue)
            ),
            speed: speed,
            isPaused: BighelpThinkingOrbPresentation.shouldPause(
                explicitly: isPaused,
                scenePhase: scenePhase
            ),
            surface: surface,
            accessibilityLabel: presentation.state.label,
            tint: tint
        )
    }
}
