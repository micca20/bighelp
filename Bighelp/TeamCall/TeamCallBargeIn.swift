import Foundation

/// Decides when you're talking over a reply, following Hermes' full-duplex
/// listener: the quiet room is measured before a reply plays, cutting in takes
/// `barge_in_threshold_multiplier` times that, and for `barge_in_grace_seconds`
/// after each reply starts its own sound can't count. Words that only echo
/// what's being said never count (`VoiceBargeInDetector`).
@MainActor
final class TeamCallBargeIn {
    /// The app's tuned level for speaker-volume replies; a noisy room raises it.
    static let minimumThreshold: Float = 0.18
    static let maximumThreshold: Float = 0.6

    private(set) var quietLevel: Float = 0.03
    private var settings: TeamCallVoiceSettings
    private let now: () -> ContinuousClock.Instant
    private var detector = VoiceBargeInDetector()
    private var spokenText = ""
    private var graceEndsAt: ContinuousClock.Instant?

    init(settings: TeamCallVoiceSettings = .init(), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.settings = settings
        self.now = now
    }

    var threshold: Float {
        min(max(quietLevel * Float(settings.bargeInThresholdMultiplier), Self.minimumThreshold), Self.maximumThreshold)
    }

    func update(settings: TeamCallVoiceSettings) {
        self.settings = settings
    }

    /// A level heard while nobody talks and nothing plays.
    func calibrate(quietLevel level: Float) {
        guard level.isFinite, level >= 0, level < Self.maximumThreshold else { return }
        quietLevel = quietLevel * 0.9 + level * 0.1
    }

    /// A piece of a reply started playing.
    func beginReply(_ text: String) {
        spokenText = spokenText.isEmpty ? text : spokenText + " " + text
        // Keep the last few sentences: that's all a microphone can echo.
        if spokenText.count > 2_000 { spokenText = String(spokenText.suffix(2_000)) }
        detector = VoiceBargeInDetector(activityThreshold: threshold)
        detector.begin(spokenText: spokenText)
        graceEndsAt = now().advanced(by: settings.bargeInGrace)
    }

    /// The microphone started a new listening session mid-reply: what it
    /// heard before is gone, the reply's words still count as echo.
    func restartListening() {
        detector = VoiceBargeInDetector(activityThreshold: threshold)
        detector.begin(spokenText: spokenText)
    }

    /// Nothing is playing any more.
    func endReplies() {
        spokenText = ""
        graceEndsAt = nil
        detector.reset()
    }

    func receiveLevel(_ level: Float) {
        if let graceEndsAt, now() < graceEndsAt { return }
        detector.receiveLevel(level)
    }

    /// True when these words are you, talking over the reply.
    func receiveTranscript(_ text: String, isFinal: Bool) -> Bool {
        detector.receiveTranscript(text, isFinal: isFinal)
    }
}
