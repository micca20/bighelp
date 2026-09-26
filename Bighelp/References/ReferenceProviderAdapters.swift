import Foundation
import Observation

/// Optional, inert factories. The composition owner must discard/rebind providers
/// synchronously when chat authority, credential selection or Wiki context changes.
@MainActor
enum ReferenceProviderAdapters {
    /// Only the trusted local composition may bridge its authenticated hub account
    /// to the existing device-keyed GitHub namespace. Both IDs remain pinned;
    /// ownerIsCurrent must still validate the full live chat authority.
    /// Omitting the bridge preserves same-namespace validation for other callers.
    static func github(
        store: GitHubConnectionStore,
        expectedHubAccountID: String? = nil,
        ownerIsCurrent: @escaping (ReferenceHubOwner) -> Bool
    ) -> ReferenceHubProvider? {
        guard let ownerID = store.ownerID, let credential = store.selectedCredential else { return nil }
        return ReferenceGitHubAdapter(store: store, ownerID: ownerID,
                                      credentialID: credential.id, userID: credential.identity.id,
                                      generation: store.generation, expectedHubAccountID: expectedHubAccountID,
                                      ownerIsCurrent: ownerIsCurrent).provider
    }

    static func wiki(
        store: WikiStore, client: (any WikiClientProtocol)?,
        ownerIsCurrent: @escaping (ReferenceHubOwner) -> Bool
    ) -> ReferenceHubProvider? {
        guard let owner = store.owner, owner.isValid, let client,
              client.owner == owner, store.isAvailable,
              !store.connections.isEmpty,
              store.connections.count <= WikiLimits.maxConnections,
              store.connections.allSatisfy({ $0.owner == owner }) else { return nil }
        return ReferenceWikiAdapter(store: store, client: client, owner: owner,
                                    connections: store.connections, ownerIsCurrent: ownerIsCurrent).provider
    }
}

/// Errors intentionally exclude provider diagnostics, tokens and host paths.
enum ReferenceAdapterError: Error, LocalizedError {
    case unavailable, partialFailure, authorityChanged, invalidSource, expiredResult

    var errorDescription: String? {
        switch self {
        case .unavailable: "This reference cannot be verified now. Retry or remove it; the draft is retained."
        case .partialFailure: "This reference search is incomplete. Retry to load all categories."
        case .authorityChanged: "Reference access changed. Reopen the drawer for the current connection."
        case .invalidSource: "This source cannot be included with an exact, bounded reference snapshot."
        case .expiredResult: "This search result expired. Search again to resolve the current source."
        }
    }
}

/// Observation callbacks may execute outside an actor. A one-way invalidation
/// latch detects even a change-away/change-back during an awaited operation.
final class ReferenceAdapterLease: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated
    }
}

enum ReferenceAdapterContent {
    static let truncationMarker = "\n\n[Reference truncated; only the exact source prefix above is included.]"

    /// Cut only at a UTF-8 scalar boundary; do not normalize BOM, combining
    /// scalars, CRLF, trailing whitespace or malformed-looking Markdown.
    static func prefix(_ source: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        let bytes = Data(source.utf8)
        guard bytes.count > maximumBytes else { return (source, false) }
        var end = max(0, maximumBytes)
        while end > 0, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return (String(decoding: bytes.prefix(end), as: UTF8.self), true)
    }

    static func fits(_ snapshot: ReferenceSnapshot) -> Bool {
        (try? ReferenceCodec.encode(source: snapshot.anchor, references: [snapshot])) != nil
    }
}
