import Foundation

struct Identity: Sendable, Equatable {
    var externalId: String
    var identityHash: String?
    var isAnonymous: Bool

    var subscriberIdentity: SubscriberIdentity {
        SubscriberIdentity(externalId: externalId, identityHash: identityHash)
    }
}

struct IdentitySnapshot: Sendable, Equatable {
    let anonymousId: String
    let externalId: String?
    let identityHash: String?
    let isRetired: Bool
    let retirementGeneration: UInt64

    var current: Identity {
        guard !isRetired, let externalId else {
            return Identity(externalId: anonymousId, identityHash: nil, isAnonymous: true)
        }
        return Identity(externalId: externalId, identityHash: identityHash, isAnonymous: false)
    }

    var retirementIdentity: Identity? {
        guard isRetired else { return nil }
        if let externalId {
            return Identity(externalId: externalId, identityHash: identityHash, isAnonymous: false)
        }
        return Identity(externalId: anonymousId, identityHash: nil, isAnonymous: true)
    }
}

actor IdentityStore {
    private let store: KeyValueStore
    // The durable Boolean masks authority across launches. This process-local revision
    // separately invalidates in-flight responses on EVERY retirement, including a
    // second logout while already retired. One lock makes compare/commit and the
    // synchronous retirement boundary atomic; no new persisted identity is introduced.
    private let authority = LockedState<UInt64>(0)

    init(store: KeyValueStore) {
        self.store = store
        if store.string(StorageKey.anonymousId) == nil {
            store.set(Self.makeAnonymousId(), for: StorageKey.anonymousId)
        }
    }

    var snapshot: IdentitySnapshot {
        authority.withLock { persistedSnapshot(generation: $0) }
    }

    var current: Identity { snapshot.current }
    var retirementIdentity: Identity? { snapshot.retirementIdentity }
    var isRetired: Bool { snapshot.isRetired }

    nonisolated func retireSynchronously() {
        authority.withLock { generation in
            generation &+= 1
            store.set(true, for: StorageKey.identityRetired)
        }
    }

    static func retirePersistedIdentity(appGroup: String?) {
        KeyValueStore(appGroup: appGroup).set(true, for: StorageKey.identityRetired)
    }

    @discardableResult
    func retire() -> IdentitySnapshot {
        authority.withLock { generation in
            generation &+= 1
            store.set(true, for: StorageKey.identityRetired)
            return persistedSnapshot(generation: generation)
        }
    }

    func identify(externalId newExternalId: String, identityHash newHash: String?) -> (identity: Identity, changed: Bool) {
        authority.withLock { generation in
            commitIdentity(externalId: newExternalId, identityHash: newHash,
                previous: persistedSnapshot(generation: generation), generation: &generation)
        }
    }

    func identify(
        externalId newExternalId: String,
        identityHash newHash: String?,
        ifUnchangedFrom expected: IdentitySnapshot
    ) -> (identity: Identity, changed: Bool)? {
        authority.withLock { generation in
            guard persistedSnapshot(generation: generation) == expected else { return nil }
            return commitIdentity(externalId: newExternalId, identityHash: newHash,
                previous: expected, generation: &generation)
        }
    }

    /// Provider deletion must be exact before raw cleanup identity is removed.
    /// Keep the durable mask until a later explicit identify commits new authority.
    func completeRetirement(ifUnchangedFrom expected: IdentitySnapshot) -> Bool {
        authority.withLock { generation in
            guard expected.isRetired, persistedSnapshot(generation: generation) == expected else { return false }
            store.set(nil as String?, for: StorageKey.externalId)
            store.set(nil as String?, for: StorageKey.identityHash)
            store.set(Self.makeAnonymousId(), for: StorageKey.anonymousId)
            generation &+= 1
            return true
        }
    }

    func allowsPublishing(_ candidate: SubscriberIdentity) -> Bool {
        let snapshot = self.snapshot
        guard !snapshot.isRetired else { return false }
        let current = snapshot.current
        return current.externalId == candidate.externalId && current.identityHash == candidate.identityHash
    }

    /// Upstream test compatibility only. Production uses durable retirement.
    func logout() -> Identity {
        authority.withLock { generation in
            store.set(nil as String?, for: StorageKey.externalId)
            store.set(nil as String?, for: StorageKey.identityHash)
            store.set(Self.makeAnonymousId(), for: StorageKey.anonymousId)
            store.set(false, for: StorageKey.identityRetired)
            generation &+= 1
            return persistedSnapshot(generation: generation).current
        }
    }

    private func commitIdentity(
        externalId newExternalId: String,
        identityHash newHash: String?,
        previous: IdentitySnapshot,
        generation: inout UInt64
    ) -> (identity: Identity, changed: Bool) {
        let changed = previous.isRetired || newExternalId != previous.externalId || newHash != previous.identityHash
        store.set(newExternalId, for: StorageKey.externalId)
        store.set(newHash, for: StorageKey.identityHash)
        store.set(false, for: StorageKey.identityRetired)
        generation &+= 1
        return (persistedSnapshot(generation: generation).current, changed)
    }

    private func persistedSnapshot(generation: UInt64) -> IdentitySnapshot {
        IdentitySnapshot(
            anonymousId: store.string(StorageKey.anonymousId) ?? Self.makeAnonymousId(),
            externalId: store.string(StorageKey.externalId),
            identityHash: store.string(StorageKey.identityHash),
            isRetired: store.bool(StorageKey.identityRetired) == true,
            retirementGeneration: generation
        )
    }

    private static func makeAnonymousId() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<21).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return "anon_" + String(suffix)
    }
}
