import Testing
@testable import Bighelp

@MainActor
struct VoiceStagePresentationTests {
    /// Speech reaches the meter at roughly 0.03–0.15; the bars should visibly move for it.
    @Test func microphoneLevelsShowOnALoudnessScale() {
        #expect(VoiceWaveformBars.displayLevel(microphone: 0) == 0)
        #expect(VoiceWaveformBars.displayLevel(microphone: 0.004) < 0.1)  // room tone
        #expect(VoiceWaveformBars.displayLevel(microphone: 0.05) > 0.4)   // quiet speech
        #expect(VoiceWaveformBars.displayLevel(microphone: 0.15) > 0.6)   // normal speech
        #expect(VoiceWaveformBars.displayLevel(microphone: 1) == 1)
    }

    @Test func barsRestAtTheSilhouetteAndRiseWithSound() {
        let rest = VoiceWaveformBars.barHeight(3, amplitude: 0, phase: 0)
        let loud = VoiceWaveformBars.barHeight(3, amplitude: 1, phase: 0)
        #expect(abs(rest - VoiceWaveformBars.silhouette(3) * 0.18) < 0.0001)
        #expect(abs(loud - VoiceWaveformBars.silhouette(3)) < 0.0001)
        // While sound plays, neighbouring bars move differently.
        let a = VoiceWaveformBars.barHeight(3, amplitude: 1, phase: 12.3)
        let b = VoiceWaveformBars.barHeight(4, amplitude: 1, phase: 12.3)
        #expect(a != b)
    }

    @Test func avatarActsOutTalkingAndTheChatsWork() {
        #expect(VoiceAvatarActivity.resolve(isSpeaking: true, isWorking: false, chatActivity: .coding) == .replying)
        #expect(VoiceAvatarActivity.resolve(isSpeaking: false, isWorking: true, chatActivity: .coding) == .coding)
        #expect(VoiceAvatarActivity.resolve(isSpeaking: false, isWorking: true, chatActivity: .web) == .web)
        #expect(VoiceAvatarActivity.resolve(isSpeaking: false, isWorking: true, chatActivity: .idle) == .thinking)
        #expect(VoiceAvatarActivity.resolve(isSpeaking: false, isWorking: true, chatActivity: .replying) == .thinking)
        #expect(VoiceAvatarActivity.resolve(isSpeaking: false, isWorking: false, chatActivity: .coding) == .idle)
    }
}
