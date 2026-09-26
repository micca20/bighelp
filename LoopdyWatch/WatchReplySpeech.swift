import AVFoundation
import Foundation
import Observation

/// Explicit, foreground-only playback using watchOS speech synthesis (not iOS Speech recognition).
@MainActor
@Observable
final class WatchReplySpeech: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
        // watchOS 6+: let the synthesizer manage its supported playback session and route.
        synthesizer.usesApplicationAudioSession = false
    }

    func speak(_ text: String) -> Bool {
        guard !text.isEmpty,
              let voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
                ?? AVSpeechSynthesisVoice.speechVoices().first(where: { !$0.voiceTraits.contains(.isPersonalVoice) }) else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        currentUtterance = ObjectIdentifier(utterance)
        isSpeaking = true
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    private nonisolated func finished(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, currentUtterance == id else { return }
            currentUtterance = nil
            isSpeaking = false
        }
    }
}
