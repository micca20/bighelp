import Foundation
import Testing
@testable import Loopdy

@MainActor
struct CompanionVoicePlaybackTests {
    @Test func petSpeakingWaitsForActualPlaybackAndUsesOutputLevel() async {
        let client = CompanionPlaybackFixture()
        let model = VoiceModel(conversationID: "voice-pet", client: client)
        #expect(model.submitTranscript("A question"))
        await client.waitForSpeech()
        #expect(model.status == .speaking)
        #expect(!model.isPlaybackActive)
        client.emit(.started)
        client.emit(.level(0.72))
        #expect(model.isPlaybackActive)
        #expect(model.outputLevel == 0.72)
        client.emit(.level(.nan))
        #expect(model.outputLevel == 0)
        client.finish()
        await model.waitUntilTurnSettles()
        #expect(!model.isPlaybackActive)
        #expect(model.outputLevel == 0)
    }

    @Test func latePlaybackCallbacksCannotReanimateMutedPet() async {
        let client = CompanionPlaybackFixture()
        let model = VoiceModel(conversationID: "voice-muted-pet", client: client)
        #expect(model.submitTranscript("A question"))
        await client.waitForSpeech()
        client.emit(.started)
        model.toggleAgentAudio()
        client.emit(.started)
        client.emit(.level(0.9))
        #expect(!model.isPlaybackActive)
        #expect(model.outputLevel == 0)
        client.finish()
        await model.waitUntilTurnSettles()
    }

    @Test func terminalPlaybackCannotRestartFromDelayedStartInSameTurn() async {
        let client = CompanionPlaybackFixture()
        let model = VoiceModel(conversationID: "voice-terminal-pet", client: client)
        #expect(model.submitTranscript("A question"))
        await client.waitForSpeech()
        client.emit(.started)
        client.emit(.finished)
        client.emit(.started)
        #expect(!model.isPlaybackActive)
        client.finish()
        await model.waitUntilTurnSettles()
    }
}

@MainActor
private final class CompanionPlaybackFixture: VoiceSessionClient {
    var callback: (@MainActor (VoicePlaybackEvent) -> Void)?
    var continuation: CheckedContinuation<Void, Error>?

    func respond(to transcript: String, conversationID: String, onDraft: @escaping (String) -> Void) async throws -> VoiceAgentReply {
        VoiceAgentReply(speaker: "Assistant", text: "A reply", timelineItems: [])
    }
    func speak(_ text: String, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws {
        callback = onPlayback
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func stopSpeaking() {}
    func endSession(conversationID: String) async throws { finish() }
    func emit(_ event: VoicePlaybackEvent) { callback?(event) }
    func finish() {
        callback?(.finished)
        continuation?.resume()
        continuation = nil
    }
    func waitForSpeech() async {
        for _ in 0..<1000 {
            if continuation != nil { return }
            await Task.yield()
        }
        Issue.record("Voice did not reach the speech output")
    }
}
