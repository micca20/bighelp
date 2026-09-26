import Foundation

// Decode-only legacy storage contracts retained for protected-cache migration.
// Nothing in app composition constructs an outbox or replays these frames.
enum LoopdyLinkSocketError: Error, Equatable {
    case invalidConfiguration
    case invalidMessage
    case sequenceMismatch
    case acknowledgementMismatch
    case pendingFrameExists
}

struct LoopdyLinkSocketStateSnapshot: Codable, Equatable, Sendable {
    var outboundSequence = 0
    var pendingFrame: String?
    /// Stable owner across transport re-enveloping; never reused by a new action.
    var pendingFrameOwnerID: String?
    /// Set only after the owning operation has surfaced a bounded failure to
    /// the user. The frame remains durable until a fresh authenticated
    /// socket.ready proves whether the relay accepted it, avoiding both silent
    /// loss and a permanently replayed poison frame.
    var failedPendingFrameID: String?
    /// A relay readiness handoff is kept separately while another outbound
    /// frame owns the sequence slot. It is promoted only after that frame is
    /// accepted, so it cannot be dropped during the ready transition.
    /// The queued handoff is account-encrypted before it touches durable
    /// state. This keeps device metadata out of UserDefaults even while the
    /// socket is offline.
    var pendingRelayReadyCiphertext: String?
    var pendingRelayReadyFingerprint: String?
    var pendingRelayReadyAcknowledgementRevision: Int?
    var relayReadyInFlightFingerprint: String?
    var lastRelayReadyFingerprint: String?
    var receivedSequences: [String: Int] = [:]
    var lastReceivedSequence = 0
    /// Optional for backwards-compatible decoding of existing durable state.
    /// Each value identifies the latest authenticated gap for that sender.
    var stateRecoverySequences: [String: Int]?
    var needsStateRecovery: Bool { !(stateRecoverySequences ?? [:]).isEmpty }
}

protocol LoopdyLinkSocketStateStoring: AnyObject {
    var snapshot: LoopdyLinkSocketStateSnapshot { get set }
}
