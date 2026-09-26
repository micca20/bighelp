import Foundation
import Testing
@testable import Loopdy

struct ThinkingMarkPolicyTests {
    @Test func lightStreaksMoveAndWarmBurstIsOccasional() {
        let start = LoopdyThinkingMarkPhasePresentation.resolve(cyclePhase: 0.1)
        let later = LoopdyThinkingMarkPhasePresentation.resolve(cyclePhase: 0.3)
        let warm = LoopdyThinkingMarkPhasePresentation.resolve(cyclePhase: 0.78)
        #expect(start.primaryStreakPhase != later.primaryStreakPhase)
        #expect(start.secondaryStreakPhase != later.secondaryStreakPhase)
        #expect(warm.warmBurstOpacity > start.warmBurstOpacity + 0.5)
        #expect(LoopdyThinkingMarkPhasePresentation.resolve(cyclePhase: 1.3).normalizedPhase - later.normalizedPhase < 0.00001)
    }

    @Test func inactiveHiddenPausedOrReducedMotionNeverAnimates() {
        #expect(LoopdyThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!LoopdyThinkingMarkAnimationPolicy.shouldAnimate(isPaused: true, reduceMotion: false, sceneIsActive: true, isVisible: true))
        #expect(!LoopdyThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: true, sceneIsActive: true, isVisible: true))
        #expect(!LoopdyThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: false, isVisible: true))
        #expect(!LoopdyThinkingMarkAnimationPolicy.shouldAnimate(isPaused: false, reduceMotion: false, sceneIsActive: true, isVisible: false))
        #expect(LoopdyThinkingMarkPhasePresentation.quiet.highlightOpacity == 0)
    }
}
