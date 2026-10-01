import Foundation

/// Main retains one runtime alongside the notification service. Entries own an
/// exact account/host/profile/stored-session/original-parent-turn, never the UI's
/// current selection. Only live, already-admitted projections enter `receive`.
@MainActor
final class BighelpManagedNativeActivityRuntime {
    private final class Entry {
        let host: BighelpConfiguredHost
        let profile: String
        let session: String
        let localTurn: String
        let canonicalTurn: String?
        let grantID: String
        let opaqueID: String
        let coordinator: BighelpLiveActivityCoordinator
        let driver: BighelpManagedActivityDriver
        let registrar: BighelpManagedLiveActivityRegistrar
        init(host: BighelpConfiguredHost, grantID: String, profile: String, session: String, localTurn: String, canonicalTurn: String?,
             coordinator: BighelpLiveActivityCoordinator, driver: BighelpManagedActivityDriver,
             registrar: BighelpManagedLiveActivityRegistrar) {
            self.host = host; self.profile = profile; self.session = session; self.localTurn = localTurn
            self.grantID = grantID; self.canonicalTurn = canonicalTurn; self.coordinator = coordinator; self.driver = driver; self.registrar = registrar
            opaqueID = ManagedNotificationValidation.nativeSessionID(host: host, profile: profile, session: session)
        }
    }
    private weak var service: BighelpManagedNotificationService?
    private let nativeDriver: any BighelpLiveActivityDriving
    private let environment: BighelpLinkPushEnvironment
    private let topic: String
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var retired = Set<String>()

    init(service: BighelpManagedNotificationService, driver: any BighelpLiveActivityDriving = BighelpActivityKitDriver(),
         environment: BighelpLinkPushEnvironment, topic: String, now: @escaping () -> Date = Date.init) {
        self.service = service; nativeDriver = driver; self.environment = environment; self.topic = topic; self.now = now
    }

    /// canonicalHostTurnID must be supplied from a real authenticated producer,
    /// never `event.turnID` merely because a projection gave it that label.
    /// nil deliberately remains local-only; no late current/next-turn adoption.
    func receive(host: BighelpConfiguredHost, chat: DirectHermesChat, event: ChatActivityEvent,
                 canonicalHostTurnID: String?, workSnapshot: BighelpManagedWorkSnapshot? = nil) async throws {
        guard let service else { return }
        _ = try service.credentials(for: host)
        let profile = chat.client.profile; let session = chat.client.storedID
        guard service.ownsChat(host: host, client: chat.client),
              event.sessionID == chat.client.conversationID,
              ManagedNotificationValidation.coordinate(session), !event.turnID.isEmpty, event.turnID.utf8.count <= 512,
              event.occurredAt > 0, event.occurredAt <= Int(now().timeIntervalSince1970) + 120,
              canonicalHostTurnID.map({ ManagedNotificationValidation.coordinate($0) }) ?? true,
              let enrollment = service.ledger.record(host: host, profile: profile), enrollment.enabled, enrollment.richLiveActivitySupported,
              !enrollment.revokePending, let grant = enrollment.grant,
              grant.state == "active", grant.expiresAt > Int(now().timeIntervalSince1970) else { return }
        if let snapshot = workSnapshot {
            guard snapshot.version == 1, snapshot.grantId == grant.grantId,
                  snapshot.work?.turnId == canonicalHostTurnID,
                  snapshot.work.map({ $0.profile == profile && $0.sessionId == session }) ?? true else {
                throw DirectHermesError.identityChanged
            }
        }
        if let canonicalHostTurnID {
            // Several native message.start segments can select the SAME public
            // work. Keep one Activity and never feed their unrelated local unit
            // lifecycle into that authoritative work's reducer.
            if let selected = entries.values.first(where: {
                $0.host.notificationScope == host.notificationScope && $0.host.id == host.id
                    && $0.grantID == grant.grantId && $0.profile == profile && $0.session == session && $0.canonicalTurn == canonicalHostTurnID
            }) {
                if workSnapshot?.work?.outcome == .cancelled {
                    try await cancel(host: host, profile: profile, storedSessionID: session,
                        originalLocalTurnID: selected.localTurn)
                } else {
                    await selected.coordinator.flushPendingOperations()
                }
                return
            }
            // Cancellation is not a successful/failed rich-v1 phase. Do not
            // create a new remote activity for already cancelled work.
            guard workSnapshot?.work?.outcome != .cancelled else { return }
            // Retained ledger ownership also prevents duplicating a system card
            // not adopted by the coordinator (e.g. already terminal at recovery).
            if service.ledger.activities.contains(where: {
                $0.accountScope == host.notificationScope && $0.hostConnectionID == host.hostConnectionID
                    && $0.grantID == grant.grantId && $0.profile == profile
                    && $0.storedSessionID == session && $0.canonicalTurnID == canonicalHostTurnID
            }) { return }
        }
        let key = Self.key(host: host, profile: profile, session: session, turn: event.turnID)
        guard !retired.contains(key) else { return }
        let entry: Entry
        if let current = entries[key] {
            guard current.canonicalTurn == canonicalHostTurnID, current.grantID == grant.grantId else { throw DirectHermesError.identityChanged }
            entry = current
        } else {
            guard !event.lifecycle.isTerminal, entries.count < 64 else { return }
            // One live card on the Lock Screen at a time: the newest chat's work
            // replaces an older card (whose reply still arrives as a notification)
            // instead of stacking a card per chat.
            for (otherKey, other) in Array(entries) where otherKey != key {
                try? await cancel(host: other.host, profile: other.profile, storedSessionID: other.session,
                                  originalLocalTurnID: other.localTurn)
            }
            guard !retired.contains(key) else { return }
            if let raced = entries[key] {
                // Another update for this chat made its card while older ones were closing.
                entry = raced
            } else {
                // No activity begins from an isolated stop, notification or history.
                entry = try makeEntry(host: host, grant: grant, session: session, localTurn: event.turnID,
                    canonicalTurn: canonicalHostTurnID, firstObservedAt: workSnapshot?.work?.observedAt ?? event.occurredAt,
                    observedState: workSnapshot?.work?.contentState)
                entries[key] = entry
            }
        }
        // Coalescing and exact child/parent ownership are in the existing reducer.
        // The driver stops local content writes as soon as cloud ownership begins.
        let configuredName = service.registry.workspace(for: host).profiles.first(where: { $0.id == profile })?.name ?? "Your agent"
        await entry.coordinator.receive(event.routed(to: entry.opaqueID), sessionTitle: "Active session",
            agentID: profile, agentName: configuredName)
    }

    /// Correlate the admitted native running->false terminal, NOT message.complete.
    /// Managed terminal delivery belongs to the real host hooks; do not locally
    /// end/revoke its token while the host's durable terminal may still be queued.
    func finish(host: BighelpConfiguredHost, profile: String, storedSessionID: String,
                originalLocalTurnID: String, outcome: BighelpLiveActivityOutcome) async throws {
        guard let service else { return }
        _ = try service.credentials(for: host)
        let key = Self.key(host: host, profile: profile, session: storedSessionID, turn: originalLocalTurnID)
        // A local frame final is not proof about selected authoritative work,
        // including the interval BEFORE its APNs token has registered.
        guard let entry = entries[key], entry.canonicalTurn == nil, !entry.driver.remoteOwned else { return }
        if case .cancelled = outcome {
            try await cancel(host: host, profile: profile, storedSessionID: storedSessionID, originalLocalTurnID: originalLocalTurnID)
            return
        }
        await entry.coordinator.finish(sessionID: entry.opaqueID, turnID: originalLocalTurnID, outcome: outcome)
        if entry.coordinator.activeSessionIDs.isEmpty {
            guard retired.count < 512 else { return }
            retired.insert(key); entries[key] = nil
        }
    }

    /// Explicit stop/cancel is different from a remote authoritative terminal.
    /// Revoke cloud ownership first; uncertain revocation stays in Keychain.
    func cancel(host: BighelpConfiguredHost, profile: String, storedSessionID: String, originalLocalTurnID: String) async throws {
        guard let service else { return }
        _ = try service.credentials(for: host)
        let key = Self.key(host: host, profile: profile, session: storedSessionID, turn: originalLocalTurnID)
        guard let entry = entries[key] else { return }
        for owner in service.ledger.activities where owner.accountScope == host.notificationScope
            && owner.hostConnectionID == host.hostConnectionID && owner.profile == profile
            && owner.storedSessionID == storedSessionID && owner.localTurnID == originalLocalTurnID && !owner.retired {
            if let request = try service.activityKeys.load(owner.relayActivityID) {
                try await entry.registrar.revoke(.init(activityID: owner.relayActivityID,
                    revision: request.revision + 1, timestamp: Int(now().timeIntervalSince1970)))
            }
        }
        entry.driver.retire(); await entry.coordinator.resetForAccountBoundary()
        if retired.count < 512 { retired.insert(key) }
        entries[key] = nil
    }

    /// Restore only exact persisted native owners, not every app activity per host.
    /// Token/revision recovery replays the original request; never guesses revision 1.
    func recover(host: BighelpConfiguredHost) async throws {
        guard let service else { return }
        _ = try service.credentials(for: host)
        try reapExpiredOwners(host: host)
        for owner in service.ledger.activities where owner.accountScope == host.notificationScope
            && owner.hostConnectionID == host.hostConnectionID && !owner.retired {
            guard let enrollment = service.ledger.record(host: host, profile: owner.profile), enrollment.enabled,
                  !enrollment.revokePending, let grant = enrollment.grant, grant.grantId == owner.grantID,
                  grant.expiresAt > Int(now().timeIntervalSince1970), entries.count < 64 else { continue }
            let key = Self.key(host: host, profile: owner.profile, session: owner.storedSessionID, turn: owner.localTurnID)
            if retired.contains(key) { continue }
            let entry: Entry
            if let retained = entries[key] { entry = retained }
            else {
                entry = try makeEntry(host: host, grant: grant, session: owner.storedSessionID,
                    localTurn: owner.localTurnID, canonicalTurn: owner.canonicalTurnID, firstObservedAt: owner.firstObservedAt)
            }
            if try await entry.registrar.resumePendingRevocation(owner) {
                entry.driver.retire(); entries[key] = nil
                if retired.count < 512 { retired.insert(key) }
                continue
            }
            guard entry.coordinator.activeSessionIDs.contains(owner.opaqueSessionID) else { continue }
            entries[key] = entry
            if let registration = try entry.registrar.restoreRegistration(owner) {
                await entry.coordinator.reconcileRestoredRegistration(registration)
            }
            _ = try service.credentials(for: host)
        }
    }
    /// Garbage-collect only absent system records whose original registration
    /// lease has expired. Unknown/live registrations and pending revokes remain.
    func reapExpiredOwners(host: BighelpConfiguredHost) throws {
        guard let service else { return }
        _ = try service.credentials(for: host)
        let activeIDs = Set(nativeDriver.existingActivities().map(\.nativeActivityID))
        let timestamp = Int(now().timeIntervalSince1970)
        for var owner in service.ledger.activities where owner.accountScope == host.notificationScope
            && owner.hostConnectionID == host.hostConnectionID && !activeIDs.contains(owner.nativeActivityID) {
            let request = try service.activityKeys.load(owner.relayActivityID)
            guard request?.pendingRevocationBody == nil,
                  (request?.leaseExpires ?? (owner.firstObservedAt + 86_400)) < timestamp else { continue }
            owner.retired = true; try service.ledger.save(owner)
            try service.activityKeys.remove(owner.relayActivityID)
            try service.ledger.forgetRetiredActivity(owner.relayActivityID)
            let key = Self.key(host: host, profile: owner.profile, session: owner.storedSessionID, turn: owner.localTurnID)
            if let entry = entries.removeValue(forKey: key) { entry.driver.retire() }
            if retired.count < 512 { retired.insert(key) }
        }
    }
    func flushPendingOperations() async {
        for entry in Array(entries.values) { await entry.coordinator.flushPendingOperations() }
    }
    func retire(host: BighelpConfiguredHost) {
        for (key, entry) in entries where entry.host.notificationScope == host.notificationScope && entry.host.id == host.id {
            entry.driver.retire()
            Task { await entry.coordinator.resetForAccountBoundary() }
            entries[key] = nil
        }
    }
    func resetForAccountBoundary() async {
        let previous = Array(entries.values); entries.removeAll(); retired.removeAll()
        for entry in previous { entry.driver.retire() }
        for entry in previous { await entry.coordinator.resetForAccountBoundary() }
    }
    /// For `loopdy://chat/native-*` ActivityKit taps: only a local scoped mapping
    /// is returned. Main may use the same exact host/profile/session open flow;
    /// a URL alone never constitutes a verified managed alert event.
    func destination(opaqueSessionID: String) -> BighelpManagedActivityOwner? {
        guard let service, opaqueSessionID.hasPrefix("native-") else { return nil }
        let matches = service.ledger.activities.filter { owner in
            owner.opaqueSessionID == opaqueSessionID && !owner.retired && service.registry.hosts.contains { host in
                host.hostConnectionID == owner.hostConnectionID && host.notificationScope == owner.accountScope
                    && (try? service.credentials(for: host)) != nil
            }
        }
        guard let first = matches.first, matches.allSatisfy({ $0.hostConnectionID == first.hostConnectionID
            && $0.profile == first.profile && $0.storedSessionID == first.storedSessionID }) else { return nil }
        return first
    }
    private func makeEntry(host: BighelpConfiguredHost, grant: BighelpManagedGrant, session: String,
                           localTurn: String, canonicalTurn: String?, firstObservedAt: Int,
                           observedState: LoopdySessionActivityAttributes.ContentState? = nil) throws -> Entry {
        guard let service else { throw DirectHermesError.secureStorageChanged }
        let source: any BighelpLiveActivityDriving = canonicalTurn == nil ? nativeDriver
            : BighelpManagedObservedActivityDriver(underlying: nativeDriver, initialState: observedState)
        let driver = BighelpManagedActivityDriver(underlying: source, ledger: service.ledger,
            activityKeys: service.activityKeys, host: host, grantID: grant.grantId, profile: grant.profile,
            sessionID: session, localTurnID: localTurn, canonicalTurnID: canonicalTurn, firstObservedAt: firstObservedAt)
        let registrar = try BighelpManagedLiveActivityRegistrar(service: service, host: host, grant: grant,
            environment: environment, topic: topic)
        registrar.onRegistrationConfirmed = { [weak driver] in driver?.registrationConfirmed() }
        let coordinator = BighelpLiveActivityCoordinator(driver: driver, registrar: registrar, now: now)
        return Entry(host: host, grantID: grant.grantId, profile: grant.profile, session: session, localTurn: localTurn, canonicalTurn: canonicalTurn,
            coordinator: coordinator, driver: driver, registrar: registrar)
    }
    private static func key(host: BighelpConfiguredHost, profile: String, session: String, turn: String) -> String {
        ManagedNotificationValidation.digest([host.notificationScope, host.hostConnectionID, profile, session, turn].joined(separator: "\0"))
    }
}

/// A canonical selection is server-owned from intent, not only token admission.
/// Bootstrap the native card from the bounded snapshot; local segment changes
/// may trigger registration retries but never overwrite or end that projection.
@MainActor
private final class BighelpManagedObservedActivityDriver: BighelpLiveActivityDriving {
    private let underlying: any BighelpLiveActivityDriving
    private let initialState: LoopdySessionActivityAttributes.ContentState?
    init(underlying: any BighelpLiveActivityDriving, initialState: LoopdySessionActivityAttributes.ContentState?) {
        self.underlying = underlying; self.initialState = initialState
    }
    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        underlying.existingActivities().map { snapshot in
            guard snapshot.state.phase.isTerminal else { return snapshot }
            // The coordinator only restores running bookkeeping. Keep a token
            // observer for a live system card seeded terminal before its token
            // arrived. This control-only state is NEVER written to ActivityKit;
            // the system retains the actual authoritative terminal projection.
            return BighelpLiveActivitySnapshot(nativeActivityID: snapshot.nativeActivityID,
                attributes: snapshot.attributes,
                state: .initial(agentName: snapshot.attributes.agentName, timestamp: snapshot.state.timestamp),
                pushToken: snapshot.pushToken)
        }
    }
    func start(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState) throws -> String {
        try underlying.start(attributes: attributes, state: initialState ?? state)
    }
    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async {}
    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {}
    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        await underlying.dismiss(id: id, state: state)
    }
    func currentPushToken(id: String) -> Data? { underlying.currentPushToken(id: id) }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> { underlying.pushTokenUpdates(id: id) }
}

/// Inject this wrapper into the EXISTING Link coordinator. A legacy driver must
/// never adopt a managed host's opaque native-session attributes on cold launch.
@MainActor
final class BighelpNonManagedActivityDriver: BighelpLiveActivityDriving {
    private let underlying: any BighelpLiveActivityDriving
    private var started = Set<String>()
    init(_ underlying: any BighelpLiveActivityDriving) { self.underlying = underlying }
    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        underlying.existingActivities().filter { !$0.attributes.sessionID.hasPrefix("native-") }
    }
    func start(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState) throws -> String {
        guard !attributes.sessionID.hasPrefix("native-") else { throw DirectHermesError.invalidResponse }
        let id = try underlying.start(attributes: attributes, state: state); started.insert(id); return id
    }
    private func permits(_ id: String) -> Bool { started.contains(id) || existingActivities().contains { $0.nativeActivityID == id } }
    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        if permits(id) { await underlying.update(id: id, state: state) }
    }
    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        if permits(id) { await underlying.end(id: id, state: state); started.remove(id) }
    }
    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        if permits(id) { await underlying.dismiss(id: id, state: state); started.remove(id) }
    }
    func currentPushToken(id: String) -> Data? { permits(id) ? underlying.currentPushToken(id: id) : nil }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> {
        permits(id) ? underlying.pushTokenUpdates(id: id) : AsyncStream { $0.finish() }
    }
}
