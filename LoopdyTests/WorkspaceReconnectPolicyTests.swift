import Testing
@testable import Loopdy

struct WorkspaceReconnectPolicyTests {
    @Test func backoffGrowsThenHoldsAtThirtySeconds() {
        let delays = (0..<8).map(WorkspaceReconnectPolicy.delay(afterAttempt:))
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
                           .seconds(30), .seconds(30), .seconds(30)])
        #expect(WorkspaceReconnectPolicy.delay(afterAttempt: -1) == .seconds(1))
    }

    @Test func retryIsOfferedOnlyAfterQuietAttempts() {
        #expect(WorkspaceReconnectPolicy.quietAttempts == 3)
        // The first three tries (about 7 seconds) show "Reconnecting…" only.
        let quietWindow = (0..<WorkspaceReconnectPolicy.quietAttempts)
            .map(WorkspaceReconnectPolicy.delay(afterAttempt:))
            .reduce(Duration.zero, +)
        #expect(quietWindow == .seconds(7))
    }
}
