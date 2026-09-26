import SwiftUI
import Testing
@testable import Loopdy

@MainActor
struct LoopdyThinkingOrbTests {
    @Test func scenariosResolveToTheIntendedPackageStates() {
        let cases: [(LoopdyThinkingOrbScenario, String)] = [
            (.working, "working"),
            (.searching, "searching"),
            (.reasoning, "solving"),
            (.listening, "listening"),
            (.connecting, "connecting"),
            (.coordinating, "weaving"),
            (.composing, "composing"),
            (.waiting, "breathing"),
            (.shaping, "shaping"),
        ]

        for (scenario, expectedState) in cases {
            let resolved = LoopdyThinkingOrbPresentation.resolve(
                scenario: scenario,
                scale: .standard
            )

            #expect(resolved.state.rawValue == expectedState)
        }
    }

    @Test func presentationScalesPreserveThePurposeTunedPackageSizes() {
        let inline = LoopdyThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline
        )
        let standard = LoopdyThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .standard
        )

        #expect(inline.size.rawValue == 20)
        #expect(inline.displaySize == nil)
        #expect(standard.size.rawValue == 64)
        #expect(standard.displaySize == nil)
    }

    @Test func visibleLabelsSuppressThePackagesDuplicateAccessibilityElement() {
        let unlabeled = LoopdyThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline
        )
        let labeled = LoopdyThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline,
            visibleLabel: "Working"
        )

        #expect(unlabeled.visibleLabel == nil)
        #expect(!unlabeled.hidesOrbFromAccessibility)
        #expect(labeled.visibleLabel == "Working")
        #expect(labeled.hidesOrbFromAccessibility)
    }

    @Test func animationPausesOutsideTheActiveSceneOrWhenExplicitlyRequested() {
        #expect(!LoopdyThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .active
        ))
        #expect(LoopdyThinkingOrbPresentation.shouldPause(
            explicitly: true,
            scenePhase: .active
        ))
        #expect(LoopdyThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .inactive
        ))
        #expect(LoopdyThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .background
        ))
    }

    @Test func filledActionControlsUseTheThemesDeclaredForegroundContrast() {
        #expect(LoopdyTheme.light.actionThinkingOrbSurface == .dark)
        // Lavender dark-mode actions carry ink, so the orb renders for a light surface.
        #expect(LoopdyTheme.dark.actionThinkingOrbSurface == .light)
        #expect(LoopdyTheme.nousDark.actionThinkingOrbSurface == .light)
        #expect(LoopdyTheme.superpilotDark.actionThinkingOrbSurface == .light)
    }

    @Test func pendingAgentIndicatorIsATypingBubble() {
        #expect(PendingMessagePresentation.showsContainer)
        #expect(PendingMessagePresentation.dotSize == 8)
        #expect(PendingMessagePresentation.restingDotOpacity > 0)
        #expect(PendingMessagePresentation.restingDotOpacity < 1)
    }
}
