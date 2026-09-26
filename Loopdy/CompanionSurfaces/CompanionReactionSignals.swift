import Foundation

struct CompanionChatSignal: Equatable {
    let clarificationIDs: Set<String>
    let runningIDs: Set<String>
    let meaningfulSuccessIDs: Set<String>

    var baselineReaction: CompanionReaction {
        if !clarificationIDs.isEmpty { return .question }
        if !runningIDs.isEmpty { return .thinking }
        return .idle
    }
}

/// A success animates only when this visible surface observed that same work
/// running. Every canonical history replacement starts a new baseline.
struct CompanionCompletionTracker {
    private var revision: Int?
    private var running: Set<String> = []

    mutating func consume(_ signal: CompanionChatSignal, historyRevision: Int, enabled: Bool) -> Bool {
        defer {
            revision = historyRevision
            running = enabled ? signal.runningIDs : []
        }
        guard enabled, revision == historyRevision, signal.clarificationIDs.isEmpty else { return false }
        return !signal.meaningfulSuccessIDs.intersection(running).isEmpty
    }
}

enum CompanionVoiceSignal {
    static func reaction(status: VoiceStatus, playbackActive: Bool, microphoneMonitoring: Bool) -> CompanionReaction {
        if playbackActive { return .speaking }
        switch status {
        case .listening: return microphoneMonitoring ? .listening : .idle
        case .working, .speaking: return .thinking
        case .paused: return .idle
        case .unavailable: return .failed
        }
    }
}

enum CompanionReactionDuration {
    static let chatCelebration: Duration = .seconds(2)
    static let homeAttention: Duration = .seconds(3)
}
