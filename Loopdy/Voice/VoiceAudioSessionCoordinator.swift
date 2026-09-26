import AVFoundation
import Foundation

/// Seam over the process-wide audio session so ownership can be observed in
/// tests without real audio hardware.
protocol VoiceAudioSessionControlling: AnyObject, Sendable {
    func configurePlayAndRecord() throws
    func setActive(_ active: Bool) throws
}

final class SystemVoiceAudioSession: VoiceAudioSessionControlling, @unchecked Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func configurePlayAndRecord() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker]
        )
    }

    func setActive(_ active: Bool) throws {
        if active {
            try session.setActive(true, options: [])
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Microphone capture and agent playback share one `AVAudioSession`. Each takes
/// an independent claim; the session is deactivated only once the last claim is
/// released, so stopping the mic can never cut off audio that is still playing.
///
/// Deliberately not actor-isolated: `release` must be reachable from the
/// nonisolated `deinit` teardown paths that own these claims.
final class VoiceAudioSessionCoordinator: @unchecked Sendable {
    static let shared = VoiceAudioSessionCoordinator()

    private let session: any VoiceAudioSessionControlling
    private let lock = NSLock()
    private var activeClaims: Set<UUID> = []

    init(session: any VoiceAudioSessionControlling = SystemVoiceAudioSession()) {
        self.session = session
    }

    var isSessionActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeClaims.isEmpty
    }

    var claimCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClaims.count
    }

    /// Activates the shared session if it is not already owned. The claim is
    /// only recorded once activation succeeds, so a throwing activation cannot
    /// strand a claim that would pin the session active forever.
    func acquire() throws -> VoiceAudioSessionClaim {
        lock.lock()
        defer { lock.unlock() }

        if activeClaims.isEmpty {
            try session.configurePlayAndRecord()
            try session.setActive(true)
        }
        let id = UUID()
        activeClaims.insert(id)
        return VoiceAudioSessionClaim(id: id, coordinator: self)
    }

    fileprivate func release(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard activeClaims.remove(id) != nil else { return }
        guard activeClaims.isEmpty else { return }
        try? session.setActive(false)
    }
}

/// Releasing is idempotent: the coordinator drops unknown identifiers, so a
/// double release can never deactivate a session a later claim now owns.
final class VoiceAudioSessionClaim: @unchecked Sendable {
    private let id: UUID
    private let coordinator: VoiceAudioSessionCoordinator

    fileprivate init(id: UUID, coordinator: VoiceAudioSessionCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func release() {
        coordinator.release(id)
    }
}
