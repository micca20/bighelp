import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesVoiceMediaTests {
    @Test func controlFramesRequireExactPCMShape() throws {
        #expect(try DirectHermesVoiceMediaTransport.controlFrame(#"{"type":"start","sample_rate":24000,"channels":1}"#) == .start(sampleRate: 24_000, channels: 1))
        #expect(try DirectHermesVoiceMediaTransport.controlFrame(#"{"type":"fallback"}"#) == .fallback)
        #expect(try DirectHermesVoiceMediaTransport.controlFrame(#"{"type":"end"}"#) == .end)
        for invalid in [
            #"{"type":"start","sample_rate":24000,"channels":2}"#,
            #"{"type":"start","sample_rate":1,"channels":1}"#,
            #"{"type":"start","sample_rate":24000.5,"channels":1}"#,
            #"{"type":"end","unexpected":true}"#,
            #"{"type":"unknown"}"#
        ] {
            #expect(throws: (any Error).self) { try DirectHermesVoiceMediaTransport.controlFrame(invalid) }
        }
    }

    @Test func nativePCMSilenceActuallySchedulesAndDrains() async throws {
        var starts = 0
        var finishes = 0
        var failures = 0
        let player = DirectHermesPCMStreamingPlayer(sessionCoordinator: .shared,
            operationID: UUID(), sampleRate: 24_000, channels: 1) { event in
                switch event {
                case .started: starts += 1
                case .finished: finishes += 1
                case .failed: failures += 1
                default: break
                }
            }
        defer { player.stop(notifyFailure: false) }
        try player.start()
        try await player.schedule(Data(repeating: 0, count: 24_000 / 50 * 2))
        try await player.finish()
        #expect(starts == 1)
        #expect(finishes == 1)
        #expect(failures == 0)
    }
}
