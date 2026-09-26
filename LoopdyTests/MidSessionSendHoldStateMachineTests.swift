import Testing
@testable import Loopdy

struct MidSessionSendHoldStateMachineTests {
    @Test func thresholdPresentsOptionsBeforeTheTouchEnds() {
        var machine = MidSessionSendHoldStateMachine()

        #expect(machine.begin(at: 0) == [])
        #expect(machine.advance(to: 2.999) == [])
        #expect(machine.advance(to: 3.0) == [.presentOptions])
        #expect(machine.isOptionsPresented)
    }

    @Test func releaseAfterThresholdConsumesTheOriginalActivation() {
        var machine = MidSessionSendHoldStateMachine()

        _ = machine.begin(at: 0)
        _ = machine.advance(to: 3.1)

        #expect(machine.end(at: 3.1) == [])
        #expect(machine.end(at: 3.2) == [])
    }

    @Test func deliberateHoldReleasedBeforeThresholdCancelsWithoutSending() {
        var machine = MidSessionSendHoldStateMachine()

        _ = machine.begin(at: 0)
        #expect(machine.advance(to: 2.999) == [])
        #expect(machine.end(at: 2.999) == [])
    }

    @Test func shortTapSendsExactlyOnce() {
        var machine = MidSessionSendHoldStateMachine()

        _ = machine.begin(at: 0)
        #expect(machine.end(at: 0.1) == [.sendDefault])
        #expect(machine.end(at: 0.2) == [])
    }

    @Test func dragBeyondMaximumDistanceCancelsWithoutSending() {
        var machine = MidSessionSendHoldStateMachine()

        _ = machine.begin(at: 0)
        #expect(machine.move(distance: 50.1) == [])
        #expect(machine.end(at: 0.1) == [])
    }
}
