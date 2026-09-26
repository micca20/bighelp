import Testing
@testable import Bighelp

struct CompanionReactionTests {
    @Test func completionRequiresObservedWorkAndNeverReplaysHistory() {
        var tracker = CompanionCompletionTracker()
        let idle = CompanionChatSignal(clarificationIDs: [], runningIDs: [], meaningfulSuccessIDs: [])
        let work = CompanionChatSignal(clarificationIDs: [], runningIDs: ["a"], meaningfulSuccessIDs: [])
        let done = CompanionChatSignal(clarificationIDs: [], runningIDs: [], meaningfulSuccessIDs: ["a"])
        let observation0 = !tracker.consume(idle, historyRevision: 0, enabled: true)
        #expect(observation0)
        let observation1 = !tracker.consume(done, historyRevision: 1, enabled: true)
        #expect(observation1)
        let observation2 = !tracker.consume(work, historyRevision: 1, enabled: true)
        #expect(observation2)
        let observation3 = tracker.consume(done, historyRevision: 1, enabled: true)
        #expect(observation3)
        let observation4 = !tracker.consume(done, historyRevision: 1, enabled: true)
        #expect(observation4)
        _ = tracker.consume(work, historyRevision: 1, enabled: true)
        let observation5 = !tracker.consume(done, historyRevision: 2, enabled: true)
        #expect(observation5)
        _ = tracker.consume(work, historyRevision: 2, enabled: false)
        let observation6 = !tracker.consume(done, historyRevision: 2, enabled: true)
        #expect(observation6)
    }

    @Test func questionTakesPriorityOverCompletion() {
        var tracker = CompanionCompletionTracker()
        _ = tracker.consume(.init(clarificationIDs: [], runningIDs: ["a"], meaningfulSuccessIDs: []), historyRevision: 0, enabled: true)
        let question = CompanionChatSignal(clarificationIDs: ["q"], runningIDs: [], meaningfulSuccessIDs: ["a"])
        let observation7 = !tracker.consume(question, historyRevision: 0, enabled: true)
        #expect(observation7)
        #expect(question.baselineReaction == .question)
    }

    @Test func voiceReactionsRequireActualMonitoringAndPlayback() {
        #expect(CompanionVoiceSignal.reaction(status: .listening, playbackActive: false, microphoneMonitoring: false) == .idle)
        #expect(CompanionVoiceSignal.reaction(status: .listening, playbackActive: false, microphoneMonitoring: true) == .listening)
        #expect(CompanionVoiceSignal.reaction(status: .speaking, playbackActive: false, microphoneMonitoring: false) == .thinking)
        #expect(CompanionVoiceSignal.reaction(status: .speaking, playbackActive: true, microphoneMonitoring: false) == .speaking)
    }

    @Test func accountHostScopeIsUnambiguous() {
        #expect(CompanionSurfaceScope.accountHost(deviceID: "a:1", authorizationEpoch: 2, hostID: "b") !=
                CompanionSurfaceScope.accountHost(deviceID: "a", authorizationEpoch: 1, hostID: "2:b"))
        #expect(CompanionSurfaceScope.accountHost(deviceID: "a", authorizationEpoch: 1, hostID: "b") !=
                CompanionSurfaceScope.accountHost(deviceID: "a", authorizationEpoch: 2, hostID: "b"))
    }
}
