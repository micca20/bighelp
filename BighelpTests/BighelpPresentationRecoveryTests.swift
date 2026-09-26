import Foundation
import Testing
@testable import Bighelp

struct BighelpPresentationRecoveryTests {
    @Test func malformedOrForeignResetCannotRetireCurrentPresentation() throws {
        var state = BighelpPresentationRecovery()
        let payload: [String: Any] = ["version":1,"type":"presentation.reset","deviceId":"phone","authorizationEpoch":2,"reason":"gap"]
        let data=try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try state.accept(data, deviceID:"other",epoch:2) }
        #expect(state.pending == nil)
        try state.accept(data,deviceID:"phone",epoch:2)
        let old=state.pending
        try state.accept(data,deviceID:"phone",epoch:2)
        state.complete(old)
        #expect(state.pending != nil)
        state.complete(state.pending)
        #expect(state.pending == nil)
    }
}
