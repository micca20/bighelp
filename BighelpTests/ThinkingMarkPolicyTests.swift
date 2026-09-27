import Foundation
import Testing
@testable import Bighelp

struct ThinkingMarkPolicyTests {
    @Test func theBlobMorphsGentlyWhileWorkingAndRestsRound() {
        let start = BighelpThinkingMarkPhasePresentation.resolve(time: 10, scenario: .working, speed: 1)
        let later = BighelpThinkingMarkPhasePresentation.resolve(time: 10.4, scenario: .working, speed: 1)
        #expect(start != later)
        // Organic, never spiky: every lobe stays within ~13% of round.
        for frame in stride(from: 0.0, to: 30, by: 0.37) {
            let phase = BighelpThinkingMarkPhasePresentation.resolve(time: frame, scenario: .reasoning, speed: 1)
            #expect(phase.lobes.allSatisfy { (0.86...1.14).contains($0) })
            #expect((0.9...1.0).contains(phase.breath))
        }
        #expect(BighelpThinkingMarkPhasePresentation.quiet.lobes.allSatisfy { $0 == 1 })
        #expect(BighelpThinkingMarkPhasePresentation.resolve(time: 5, scenario: .working, speed: 0)
                    == BighelpThinkingMarkPhasePresentation.resolve(time: 9, scenario: .working, speed: 0))
    }

    @Test func inactiveHiddenPausedOrReducedMotionNeverAnimates() {
        #expect(BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: true, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: true, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: false, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: false))
    }
}
