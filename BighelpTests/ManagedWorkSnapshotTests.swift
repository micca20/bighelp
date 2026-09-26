import Foundation
import Testing
@testable import Bighelp

struct ManagedWorkSnapshotTests {
    private let grant = "97c36e37-72b3-4da1-9e5a-7b59df0cad01"
    @Test func scopedCanonicalWorkDecodesWithoutAnyTimelineIdentityGuess() throws {
        let work: [String: BighelpJSONValue] = ["profile":.string("default"),"sessionId":.string("stored-session"),"turnId":.string("canonical-turn"),
            "phase":.string("delegating"),"activeSubagentCount":.integer(2),"terminal":.boolean(false),"outcome":.string("completed"),"observedAt":.integer(100)]
        let envelope: BighelpJSONValue = .object(["version":.integer(1),"grantId":.string(grant),"work":.object(work)])
        let value = try BighelpManagedWorkSnapshot.validated(envelope,grantID:grant,profile:"default",sessionID:"stored-session",now:101)
        #expect(value.work?.turnId == "canonical-turn")
        #expect(value.work?.terminal == false)
        #expect(value.work?.activeSubagentCount == 2)
        #expect(throws: DirectHermesError.self) { try BighelpManagedWorkSnapshot.validated(envelope,grantID:grant,profile:"other",sessionID:"stored-session",now:101) }
        var privateWork = work; privateWork["prompt"] = .string("must not escape")
        #expect(throws: DirectHermesError.self) { try BighelpManagedWorkSnapshot.validated(.object(["version":.integer(1),"grantId":.string(grant),"work":.object(privateWork)]),grantID:grant,profile:"default",sessionID:"stored-session",now:101) }
    }
    @Test func cancelledSnapshotUsesNeutralTerminalPresentation() throws {
        let work: [String: BighelpJSONValue] = ["profile":.string("default"),"sessionId":.string("stored-session"),"turnId":.string("canonical-turn"),
            "phase":.string("completed"),"activeSubagentCount":.integer(0),"terminal":.boolean(true),"outcome":.string("cancelled"),"observedAt":.integer(100)]
        let value = try BighelpManagedWorkSnapshot.validated(.object(["version":.integer(1),"grantId":.string(grant),"work":.object(work)]),grantID:grant,profile:"default",sessionID:"stored-session",now:101)
        #expect(value.work?.contentState.currentAction == "Stopped")
        #expect(value.work?.contentState.phase.isTerminal == true)
    }
    @Test func absentWorkIsNotInventedFromSessionExistence() throws {
        let value = try BighelpManagedWorkSnapshot.validated(.object(["version":.integer(1),"grantId":.string(grant),"work":.null]),grantID:grant,profile:"default",sessionID:"stored",now:101)
        #expect(value.work == nil)
    }
}
