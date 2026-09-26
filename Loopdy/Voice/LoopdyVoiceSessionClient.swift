import AVFoundation
import Foundation

@MainActor
protocol VoiceSpeechOutput: AnyObject {
    func speak(_ text: String, rate: Float) async throws
    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stop()
}

extension VoiceSpeechOutput {
    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await speak(text, rate: rate)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
}

@MainActor
protocol VoiceAudioPlayback: AnyObject {
    func play(_ audio: Data, mimeType: String) async throws
    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stop()
}

extension VoiceAudioPlayback {
    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await play(audio, mimeType: mimeType)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
}

@MainActor
final class LoopdyVoiceSessionClient: VoiceSessionClient {
    private let conversation: any ConversationClient
    private let output: any VoiceSpeechOutput
    private let speechRate: () -> Float

    init(
        conversation: any ConversationClient,
        output: any VoiceSpeechOutput,
        speechRate: @escaping () -> Float
    ) {
        self.conversation = conversation
        self.output = output
        self.speechRate = speechRate
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        let response: ConversationResponse
        if let streaming = conversation as? any StreamingConversationClient {
            response = try await streaming.send(
                message: transcript,
                conversationID: conversationID,
                onDraft: { item in
                    guard case .message(let text) = item.content else { return }
                    onDraft(text)
                }
            )
        } else {
            response = try await conversation.send(
                message: transcript,
                conversationID: conversationID
            )
        }

        guard let item = response.items.last(where: { item in
            guard item.role == .assistant, case .message(let text) = item.content else {
                return false
            }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), case .message(let text) = item.content else {
            throw VoiceSessionError.emptyResponse
        }
        return VoiceAgentReply(
            speaker: item.sender.snapshot.name,
            text: text,
            timelineItems: response.items
        )
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        guard let conversation = conversation as? any MidSessionConversationClient else {
            throw VoiceSessionError.unsupported
        }
        _ = try await conversation.sendMidSession(
            message: transcript,
            attachments: [],
            conversationID: conversationID,
            behavior: .steer,
            onDraft: { _ in }
        )
    }

    func speak(_ text: String) async throws {
        try await output.speak(text, rate: min(max(speechRate(), 0.25), 4.0))
    }

    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try await output.speak(
            text,
            rate: min(max(speechRate(), 0.25), 4.0),
            onPlayback: onPlayback
        )
    }

    func stopSpeaking() {
        output.stop()
    }

    func endSession(conversationID: String) async throws {
        output.stop()
    }
}

@MainActor
final class LoopdyLinkVoiceSpeechOutput: VoiceSpeechOutput {
    private let messaging: any LoopdyLinkVoiceMessaging
    private let sessionID: String
    private let agentID: String
    private let playback: any VoiceAudioPlayback
    private let requestID: () -> String
    private let now: () -> Date
    private var generation: UInt64 = 0

    init(
        messaging: any LoopdyLinkVoiceMessaging,
        sessionID: String,
        agentID: String,
        playback: any VoiceAudioPlayback = AVAudioPlayerVoicePlayback(),
        requestID: @escaping () -> String = { "voice_\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        self.messaging = messaging
        self.sessionID = sessionID
        self.agentID = agentID
        self.playback = playback
        self.requestID = requestID
        self.now = now
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        generation &+= 1
        let ownedGeneration = generation
        playback.stop()
        let audio = try await messaging.synthesize(
            LoopdyLinkVoiceSpeakRequest(
                requestID: requestID(),
                sessionID: sessionID,
                agentID: agentID,
                text: String(normalized.prefix(20_000)),
                speed: min(max(rate, 0.25), 4),
                sentAt: Int(now().timeIntervalSince1970)
            )
        )
        try Task.checkCancellation()
        guard generation == ownedGeneration else { throw CancellationError() }
        try await playback.play(
            audio.audio,
            mimeType: audio.mimeType,
            onPlayback: onPlayback
        )
    }

    func stop() {
        generation &+= 1
        playback.stop()
    }
}

@MainActor
final class AVAudioPlayerVoicePlayback: NSObject, VoiceAudioPlayback, AVAudioPlayerDelegate {
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var sessionClaim: VoiceAudioSessionClaim?
    private var playbackEvent: (@MainActor (VoicePlaybackEvent) -> Void)?
    private var meterTask: Task<Void, Never>?

    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.sessionCoordinator = sessionCoordinator
        super.init()
    }

    func play(_ audio: Data, mimeType: String) async throws {
        try await play(audio, mimeType: mimeType) { _ in }
    }

    func play(
        _ audio: Data,
        mimeType: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        guard !audio.isEmpty, audio.count <= LoopdyLinkVoiceAudioChunk.maximumAudioBytes else {
            onPlayback(.failed)
            throw VoiceSessionError.emptyResponse
        }
        stop()
        playbackEvent = onPlayback

        do {
            sessionClaim = try sessionCoordinator.acquire()
        } catch {
            playbackEvent?(.failed)
            playbackEvent = nil
            throw error
        }

        let nextPlayer: AVAudioPlayer
        do {
            nextPlayer = try AVAudioPlayer(data: audio)
            guard nextPlayer.prepareToPlay() else { throw VoiceSessionError.emptyResponse }
        } catch {
            playbackEvent?(.failed)
            playbackEvent = nil
            releaseSession()
            throw error
        }
        nextPlayer.delegate = self
        nextPlayer.isMeteringEnabled = true
        player = nextPlayer

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard nextPlayer.play() else {
                    self.continuation = nil
                    self.player = nil
                    self.playbackEvent?(.failed)
                    self.playbackEvent = nil
                    self.releaseSession()
                    continuation.resume(throwing: VoiceSessionError.emptyResponse)
                    return
                }
                self.playbackEvent?(.started)
                self.startMetering(player: nextPlayer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        let pending = continuation
        continuation = nil
        meterTask?.cancel()
        meterTask = nil
        player?.stop()
        player = nil
        playbackEvent?(.failed)
        playbackEvent = nil
        releaseSession()
        pending?.resume(throwing: CancellationError())
    }

    private func startMetering(player: AVAudioPlayer) {
        let identity = ObjectIdentifier(player)
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard let self, let current = self.player,
                      ObjectIdentifier(current) == identity else { return }
                current.updateMeters()
                let decibels = Double(current.averagePower(forChannel: 0))
                let linear = decibels.isFinite ? pow(10, decibels / 20) : 0
                self.playbackEvent?(.level(min(max(sqrt(linear), 0), 1)))
            }
        }
    }

    private func releaseSession() {
        sessionClaim?.release()
        sessionClaim = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(for: identity, success: flag, error: nil)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(for: identity, success: false, error: error)
        }
    }

    /// A callback from a superseded player must not settle the current
    /// operation or tear down the session it now owns.
    private func finishPlayback(for identity: ObjectIdentifier, success: Bool, error: (any Error)?) {
        guard let current = player, ObjectIdentifier(current) == identity else { return }
        let pending = continuation
        continuation = nil
        meterTask?.cancel()
        meterTask = nil
        player = nil
        playbackEvent?(success ? .finished : .failed)
        playbackEvent = nil
        releaseSession()
        if success {
            pending?.resume(returning: ())
        } else {
            pending?.resume(throwing: error ?? VoiceSessionError.emptyResponse)
        }
    }
}
