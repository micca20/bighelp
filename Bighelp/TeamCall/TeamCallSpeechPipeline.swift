import Foundation

/// Audio a member's voice made for one piece of a reply.
struct TeamCallAudio: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

/// One member's voice: makes audio with that member's own Hermes `tts.*`.
@MainActor
protocol TeamCallVoice: AnyObject {
    func synthesize(_ text: String) async throws -> TeamCallAudio
}

/// The call's one speaker. Replies never overlap, so one player serves everyone.
@MainActor
protocol TeamCallAudioPlayer: AnyObject {
    func play(_ audio: TeamCallAudio, onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void) async throws
    func stop()
}

struct TeamCallSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let replyID: String
    let memberID: String
    let text: String
    let isFirstOfReply: Bool
}

/// Speaks queued replies in order. Audio for the next pieces is made while the
/// current one plays, so a reply's later sentences, and the next member's
/// reply, are ready the moment the speaker is free. `interrupt()` stops
/// everything at once for barge-in.
@MainActor
final class TeamCallSpeechPipeline {
    /// Pieces with audio being made at once, counting the one playing.
    let lookahead: Int
    var onStart: ((TeamCallSegment) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onFinish: ((TeamCallSegment) -> Void)?
    var onFailure: ((TeamCallSegment) -> Void)?
    var onIdle: (() -> Void)?

    /// Held while you're talking: audio keeps being made, nothing plays.
    var isHeld = false {
        didSet { if oldValue != isHeld { pump() } }
    }

    private(set) var pending: [TeamCallSegment] = []
    private(set) var playing: TeamCallSegment?
    private let player: any TeamCallAudioPlayer
    private let voice: @MainActor (String) -> (any TeamCallVoice)?
    private var synthesis: [UUID: Task<TeamCallAudio, any Error>] = [:]
    private var playTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        player: any TeamCallAudioPlayer,
        lookahead: Int = 3,
        voice: @escaping @MainActor (String) -> (any TeamCallVoice)?
    ) {
        self.player = player
        self.lookahead = max(lookahead, 1)
        self.voice = voice
    }

    var isBusy: Bool { playTask != nil || !pending.isEmpty }
    var isPlaying: Bool { playing != nil }

    func enqueue(replyID: String, memberID: String, chunks: [String]) {
        let segments = chunks.enumerated().map { index, text in
            TeamCallSegment(id: UUID(), replyID: replyID, memberID: memberID, text: text, isFirstOfReply: index == 0)
        }
        guard !segments.isEmpty else { return }
        pending += segments
        pump()
    }

    /// Stops the voice now and drops everything still waiting.
    func interrupt() {
        generation &+= 1
        playTask?.cancel()
        playTask = nil
        synthesis.values.forEach { $0.cancel() }
        synthesis.removeAll()
        pending.removeAll()
        let stopped = playing
        playing = nil
        player.stop()
        if let stopped { onFinish?(stopped) }
    }

    private func pump() {
        for segment in pending.prefix(lookahead) where synthesis[segment.id] == nil {
            synthesis[segment.id] = makeAudio(for: segment)
        }
        guard playTask == nil, !isHeld, let next = pending.first else { return }
        let owned = generation
        playTask = Task { @MainActor [weak self] in
            await self?.play(next, generation: owned)
        }
    }

    private func makeAudio(for segment: TeamCallSegment) -> Task<TeamCallAudio, any Error> {
        guard let voice = voice(segment.memberID) else {
            return Task<TeamCallAudio, any Error> { throw VoiceSessionError.unsupported }
        }
        let text = segment.text
        return Task { @MainActor in try await voice.synthesize(text) }
    }

    private func play(_ segment: TeamCallSegment, generation owned: UInt64) async {
        let audio: TeamCallAudio?
        do {
            audio = try await (synthesis[segment.id] ?? makeAudio(for: segment)).value
        } catch {
            audio = nil
        }
        guard owned == generation else { return }
        if let audio {
            playing = segment
            do {
                try await player.play(audio) { [weak self] event in
                    guard let self, owned == self.generation else { return }
                    switch event {
                    case .started: self.onStart?(segment)
                    case .level(let level): self.onLevel?(level)
                    case .finished, .failed: self.onLevel?(0)
                    }
                }
            } catch {
                guard owned == generation else { return }
                onFailure?(segment)
            }
        } else {
            onFailure?(segment)
        }
        guard owned == generation else { return }
        synthesis[segment.id] = nil
        pending.removeAll { $0.id == segment.id }
        playing = nil
        playTask = nil
        onFinish?(segment)
        pump()
        if !isBusy { onIdle?() }
    }
}
