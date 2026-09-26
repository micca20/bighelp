import Foundation
import Observation

/// A verified open (managed notification, Live Activity) resolves a durable
/// Hermes coordinate on the host workspace. The visible shell navigates by its
/// own catalog, so the coordinate is handed across here and consumed once.
struct LoopdyExternalSessionOpen: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A durable Hermes coordinate verified by a native host.
        case stored(profileID: String, storedSessionID: String)
        /// A shell catalog session ID (Loopdy Link notifications).
        case catalog(sessionID: String)
    }
    let id = UUID()
    let target: Target
}

@MainActor
@Observable
final class LoopdyExternalSessionOpenCenter {
    static let shared = LoopdyExternalSessionOpenCenter()
    init() {}
    private(set) var pending: LoopdyExternalSessionOpen?

    func request(profileID: String, storedSessionID: String) {
        pending = LoopdyExternalSessionOpen(target: .stored(profileID: profileID, storedSessionID: storedSessionID))
    }

    func request(catalogSessionID: String) {
        pending = LoopdyExternalSessionOpen(target: .catalog(sessionID: catalogSessionID))
    }

    func consume(_ open: LoopdyExternalSessionOpen) -> Bool {
        guard pending == open else { return false }
        pending = nil
        return true
    }
}
