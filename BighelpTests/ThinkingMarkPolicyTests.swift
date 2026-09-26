import Foundation
import Testing
@testable import Bighelp

struct ThinkingMarkPolicyTests {
    @Test func lightStreaksMoveAndWarmBurstIsOccasional() {
        let start = BighelpThinkingMarkPhasePresentation.resolve(cyclePhase: 0.1)
        let later = BighelpThinkingMarkPhasePresentation.resolve(cyclePhase: 0.3)
        let warm = BighelpThinkingMarkPhasePresentation.resolve(cyclePhase: 0.78)
        #expect(start.primaryStreakPhase != later.primaryStreakPhase)
        #expect(start.secondaryStreakPhase != later.secondaryStreakPhase)
        #expect(warm.warmBurstOpacity > start.warmBurstOpacity + 0.5)
        #expect(BighelpThinkingMarkPhasePresentation.resolve(cyclePhase: 1.3).normalizedPhase - later.normalizedPhase < 0.00001)
    }

    @Test func inactiveHiddenPausedOrReducedMotionNeverAnimates() {
        #expect(BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: true, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: true, sceneIsActive: true, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: false, isVisible: true))
        #expect(!BighelpThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: false))
        #expect(BighelpThinkingMarkPhasePresentation.quiet.highlightOpacity == 0)
    }
}
