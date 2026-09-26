import Foundation

enum VoiceStatus: String, CaseIterable, Identifiable, Sendable {
    case listening
    case working
    case speaking
    case paused
    case unavailable

    var id: Self { self }

    var label: String {
        switch self {
        case .listening:
            "Listening"
        case .working:
            "Working"
        case .speaking:
            "Speaking"
        case .paused:
            "Paused"
        case .unavailable:
            "Unavailable"
        }
    }
}

enum VoiceOrbPresentation {
    static let usesThinkingOrbsKitSurface = true

    static func scenario(for status: VoiceStatus) -> LoopdyThinkingOrbScenario {
        switch status {
        case .listening:
            .listening
        case .working:
            .reasoning
        case .speaking:
            .waiting
        case .paused:
            .waiting
        case .unavailable:
            .working
        }
    }
}

enum VoiceViewPresentation {
    /// Voice mode keeps the state cue compact so the orb remains the visual focus.
    static let statusUsesFullWidthSurface = false
    static let statusVerticalPadding: CGFloat = 8
    static let controlMinimumHeight: CGFloat = 64
    static let controlIconDiameter: CGFloat = 52
    static let transcriptMinimumHeight: CGFloat = 64
}

struct VoiceInputLevelSmoother: Sendable {
    private(set) var value: Float = 0

    mutating func update(target: Float) -> Float {
        let boundedTarget = min(max(target, 0), 1)
        let coefficient: Float = boundedTarget >= value ? 0.42 : 0.16
        value += (boundedTarget - value) * coefficient
        value = min(max(value, 0), 1)
        return value
    }

    mutating func reset() {
        value = 0
    }
}

struct VoiceTranscriptRow: Identifiable, Equatable, Sendable {
    let id: String
    let speaker: String
    let time: String
    let text: String
}

struct VoiceRecognitionUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

struct VoiceAgentReply: Equatable, Sendable {
    let speaker: String
    let text: String
    let timelineItems: [TimelineItem]
}

enum VoiceSessionError: Error, Equatable, Sendable {
    case unsupported
    case emptyResponse
}

enum VoicePlaybackEvent: Equatable, Sendable {
    case started
    case level(Double)
    case finished
    case failed
}

@MainActor
protocol VoiceSessionClient {
    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply
    func steer(_ transcript: String, conversationID: String) async throws
    func speak(_ text: String) async throws
    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws
    func stopSpeaking()
    func endSession(conversationID: String) async throws
}

@MainActor
extension VoiceSessionClient {
    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        throw VoiceSessionError.unsupported
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        throw VoiceSessionError.unsupported
    }

    func speak(_ text: String) async throws {}
    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        onPlayback(.started)
        do {
            try await speak(text)
            onPlayback(.finished)
        } catch {
            onPlayback(.failed)
            throw error
        }
    }
    func stopSpeaking() {}
}
