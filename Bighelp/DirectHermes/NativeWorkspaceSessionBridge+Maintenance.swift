import Foundation

/// Reviewed runtime closure and profile retirement, preserving protected journals.
extension NativeWorkspaceSessionBridge {
    struct ProfileSessionOwnership: Equatable, Sendable {
        let sessionID: String
        let hasDraft: Bool
        let hasUnresolvedSubmission: Bool
        let hasActiveOperation: Bool

        var blocksDestructiveRetirement: Bool {
            hasDraft || hasUnresolvedSubmission || hasActiveOperation
        }
    }

    /// Validates the current-owner binding for the exact runtime discovered by
    /// stock `session.active_list`. Maintenance must never activate or resume a
    /// durable row merely to close it.
    func resolveClosableRuntime(
        _ request: HermesSessionRuntimeCloseRequest
    ) async throws -> HermesSessionRuntimeCloseTarget {
        try DirectHermesSessionValidation.coordinate(request.profileID, maximum: 128)
        try DirectHermesSessionValidation.coordinate(request.storedSessionID)
        try DirectHermesSessionValidation.coordinate(request.runtimeSessionID)
        guard !DirectHermesSessionValidation.same(
            request.runtimeSessionID, request.storedSessionID
        ) else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let owner = try currentOwner()

        // Visibility changes can legitimately retire the mounted stream: a
        // hidden durable row is absent from the ordinary catalog, and stock
        // active-list reports an idle runtime without calling it active work.
        // Refresh only the read-only catalog binding when needed. This performs
        // no session.activate/session.resume and does not manufacture identity.
        if closeMapping(
            profileID: request.profileID,
            storedSessionID: request.storedSessionID,
            runtimeSessionID: request.runtimeSessionID,
            owner: owner
        ) == nil {
            _ = try await list()
            guard try currentOwner() == owner else {
                throw HermesSessionMaintenanceError.ownerChanged
            }
        }
        _ = try closeCandidate(
            profileID: request.profileID,
            storedSessionID: request.storedSessionID,
            runtimeSessionID: request.runtimeSessionID,
            owner: owner,
            requiresRecoveredRuntime: true
        )
        return HermesSessionRuntimeCloseTarget(
            profileID: request.profileID,
            storedSessionID: request.storedSessionID,
            runtimeSessionID: request.runtimeSessionID
        )
    }

    /// Retires only the exact runtime that Hermes confirmed closed. Durable
    /// history and submission journals remain in place for later explicit use.
    @discardableResult
    func reconcileClosedRuntime(_ result: HermesSessionCloseResult) throws -> String {
        try DirectHermesSessionValidation.coordinate(result.profileID, maximum: 128)
        try DirectHermesSessionValidation.coordinate(result.storedSessionID)
        try DirectHermesSessionValidation.coordinate(result.runtimeSessionID)
        guard !DirectHermesSessionValidation.same(
            result.runtimeSessionID, result.storedSessionID
        ) else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let owner = try currentOwner()
        let candidate = try closeCandidate(
            profileID: result.profileID,
            storedSessionID: result.storedSessionID,
            runtimeSessionID: result.runtimeSessionID,
            owner: owner,
            requiresRecoveredRuntime: false
        )
        let visibleID = candidate.visibleID

        // Reconcile the retained catalog binding before publishing retirement.
        // This is local state only and cannot recreate the closed runtime.
        let catalog = try box.value()
        try catalog.reconcileRuntimeLiveness(runtimeID: result.runtimeSessionID, isActive: false)
        guard !retired, connections.owner == owner else {
            throw HermesSessionMaintenanceError.ownerChanged
        }

        let retiredMountedStream: Bool
        if let stream = candidate.stream {
            guard let retained = streams[visibleID], retained.client === stream.client else {
                throw HermesSessionMaintenanceError.ownerChanged
            }
            retained.client.model?.flushPersistence()
            streams.removeValue(forKey: visibleID)
            unbindPromptSession(retained, visibleSessionID: visibleID)
            retained.client.suspend()
            retiredMountedStream = true
        } else {
            retiredMountedStream = false
        }
        activeMappings = activeMappings.filter { _, mapping in
            !(mapping.owner == owner
                && DirectHermesSessionValidation.same(mapping.visibleID, visibleID)
                && DirectHermesSessionValidation.same(mapping.profileID, result.profileID)
                && DirectHermesSessionValidation.same(mapping.sessionKey, result.storedSessionID)
                && DirectHermesSessionValidation.same(mapping.runtimeID, result.runtimeSessionID))
        }
        onSessionLivenessChange?(owner, visibleID, false)
        if retiredMountedStream { onSessionRetired?(visibleID) }
        return visibleID
    }

    private func closeCandidate(
        profileID: String,
        storedSessionID: String,
        runtimeSessionID: String,
        owner: WorkspaceOwner,
        requiresRecoveredRuntime: Bool
    ) throws -> (visibleID: String, stream: Stream?) {
        guard !retired, connections.owner == owner, owner.authority == authority else {
            throw HermesSessionMaintenanceError.ownerChanged
        }
        let relatedStreams = streams.compactMap { visibleID, stream -> (String, Stream)? in
            let sameStored = DirectHermesSessionValidation.same(
                stream.client.storedID, storedSessionID
            )
            let sameRuntime = DirectHermesSessionValidation.same(
                stream.client.runtimeID, runtimeSessionID
            )
            guard sameStored || sameRuntime else { return nil }
            return (visibleID, stream)
        }
        let candidates = relatedStreams.filter { _, stream in
            guard stream.owner == owner,
                  DirectHermesSessionValidation.same(stream.client.profile, profileID),
                  DirectHermesSessionValidation.same(stream.client.storedID, storedSessionID),
                  DirectHermesSessionValidation.same(stream.client.runtimeID, runtimeSessionID) else {
                return false
            }
            return true
        }
        guard relatedStreams.count == candidates.count, candidates.count <= 1 else {
            throw HermesSessionMaintenanceError.reviewChanged
        }

        guard let mapping = closeMapping(
            profileID: profileID,
            storedSessionID: storedSessionID,
            runtimeSessionID: runtimeSessionID,
            owner: owner
        ) else {
            throw HermesSessionMaintenanceError.reviewChanged
        }

        if let (visibleID, stream) = candidates.first {
            guard DirectHermesSessionValidation.same(mapping.visibleID, visibleID),
                  stream.record.kind == .direct, stream.record.agentIDs.count == 1,
                  DirectHermesSessionValidation.same(stream.record.agentIDs[0], profileID),
                  stream.record.remoteStoredID.map({
                      DirectHermesSessionValidation.same($0, storedSessionID)
                  }) == true else {
                throw HermesSessionMaintenanceError.reviewChanged
            }
            if requiresRecoveredRuntime {
                guard stream.client.connected, stream.client.isReadyForSubmission,
                      !stream.client.projection.epoch.isEmpty,
                      let recovered = stream.recoveredCoordinate,
                      recovered.owner == owner,
                      DirectHermesSessionValidation.same(recovered.sessionID, visibleID),
                      DirectHermesSessionValidation.same(recovered.profileID, profileID),
                      recovered.storedSessionID.map({
                          DirectHermesSessionValidation.same($0, storedSessionID)
                      }) == true,
                      recovered.runtimeSessionID.map({
                          DirectHermesSessionValidation.same($0, runtimeSessionID)
                      }) == true else {
                    throw HermesSessionMaintenanceError.reviewChanged
                }
            }
            let ownership = Self.profileSessionOwnership(visibleID: visibleID, stream: stream)
            guard !ownership.blocksDestructiveRetirement,
                  try !hasProtectedJournal(profileID: profileID, storedSessionID: storedSessionID) else {
                throw HermesSessionMaintenanceError.reviewChanged
            }
            return (visibleID, stream)
        }

        // The stream may have been retired by a visibility refresh. Local
        // submission journals remain authoritative even without a mounted
        // model/client, so inspect them before permitting destructive runtime
        // retirement. Failure to read the journal set fails closed.
        guard try !hasProtectedJournal(
            profileID: profileID,
            storedSessionID: storedSessionID
        ) else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        return (mapping.visibleID, nil)
    }

    private func closeMapping(
        profileID: String,
        storedSessionID: String,
        runtimeSessionID: String,
        owner: WorkspaceOwner
    ) -> DirectHermesActiveSessionMapping? {
        let related = activeMappings.values.filter { mapping in
            DirectHermesSessionValidation.same(mapping.sessionKey, storedSessionID)
                || DirectHermesSessionValidation.same(mapping.runtimeID, runtimeSessionID)
        }
        guard related.count == 1, let mapping = related.first,
              mapping.owner == owner,
              DirectHermesSessionValidation.same(mapping.profileID, profileID),
              DirectHermesSessionValidation.same(mapping.sessionKey, storedSessionID),
              DirectHermesSessionValidation.same(mapping.runtimeID, runtimeSessionID),
              let decodedVisible = try? DirectHermesSessionIdentity.decode(
                mapping.visibleID, owner: owner
              ),
              DirectHermesSessionValidation.same(decodedVisible.profileID, profileID) else {
            return nil
        }
        return mapping
    }

    private func hasProtectedJournal(
        profileID: String,
        storedSessionID: String
    ) throws -> Bool {
        do {
            return try drafts.recoveryRecords(
                hostIdentity: authority.cacheScopeID
            ).contains { recovery in
                guard let journalOwner = recovery.record.owner else { return false }
                return DirectHermesSessionValidation.same(
                    journalOwner.hostIdentity, authority.cacheScopeID
                )
                    && DirectHermesSessionValidation.same(journalOwner.profile, profileID)
                    && DirectHermesSessionValidation.same(journalOwner.storedID, storedSessionID)
                    && (!recovery.record.draft.isEmpty || !recovery.record.unresolved.isEmpty)
            }
        } catch {
            throw HermesSessionMaintenanceError.reviewChanged
        }
    }

    private static func profileSessionOwnership(
        visibleID: String,
        stream: Stream
    ) -> ProfileSessionOwnership {
        ProfileSessionOwnership(
            sessionID: visibleID,
            hasDraft: !stream.record.draft.isEmpty
                || !stream.client.journal.draft.isEmpty
                || stream.boundModel.map { !$0.draft.isEmpty } == true,
            hasUnresolvedSubmission: !stream.client.journal.unresolved.isEmpty
                || stream.client.needsRecovery
                || stream.record.referenceState?.submission != nil
                || stream.record.hasDeferredReferenceState,
            hasActiveOperation: stream.client.projection.running
                || stream.boundModel?.isSending == true
                || !stream.client.prompts.isEmpty
        )
    }

    /// Reports only app-owned state for the exact profile bytes. This is a
    /// destructive profile-operation guard, not a session catalog projection.
    func profileSessionOwnership(profileID: String) throws -> [ProfileSessionOwnership] {
        var result = streams.compactMap { id, stream -> ProfileSessionOwnership? in
            guard DirectHermesSessionValidation.same(stream.client.profile, profileID) else {
                return nil
            }
            return Self.profileSessionOwnership(visibleID: id, stream: stream)
        }
        let attachedStoredIDs = Set(streams.values.compactMap { stream in
            DirectHermesSessionValidation.same(stream.client.profile, profileID)
                ? Data(stream.client.storedID.utf8) : nil
        })
        do {
            for recovery in try drafts.recoveryRecords(
                hostIdentity: authority.cacheScopeID,
                profile: profileID
            ) {
                guard let recoveryOwner = recovery.record.owner,
                      !attachedStoredIDs.contains(Data(recoveryOwner.storedID.utf8)) else {
                    continue
                }
                result.append(ProfileSessionOwnership(
                    sessionID: recoveryOwner.storedID,
                    hasDraft: !recovery.record.draft.isEmpty,
                    hasUnresolvedSubmission: !recovery.record.unresolved.isEmpty,
                    hasActiveOperation: false
                ))
            }
        } catch {
            throw NativeWorkspaceLifecycleError.profileStateCouldNotBeVerified(
                profileID: profileID
            )
        }
        return result.sorted { $0.sessionID < $1.sessionID }
    }

    /// Retires transport/prompt/model bindings without deleting any journal.
    /// The caller must resolve every blocker before a rename or delete can
    /// proceed; this method repeats the guard immediately before retirement.
    func retireProfileSessions(profileID: String) throws -> [String] {
        let ownership = try profileSessionOwnership(profileID: profileID)
        guard !ownership.contains(where: \.blocksDestructiveRetirement) else {
            throw NativeWorkspaceLifecycleError.protectedProfileState(
                profileID: profileID,
                sessionIDs: ownership.filter(\.blocksDestructiveRetirement).map(\.sessionID)
            )
        }
        let ids = streams.compactMap { id, stream in
            DirectHermesSessionValidation.same(stream.client.profile, profileID) ? id : nil
        }.sorted()
        for id in ids {
            canonicalSessionReentryFlights.removeValue(forKey: id)?.task.cancel()
            authoritativeRecoveryFlights.removeValue(forKey: id)?.task.cancel()
            guard let stream = streams.removeValue(forKey: id) else { continue }
            stream.client.model?.flushPersistence()
            unbindPromptSession(stream, visibleSessionID: id)
            stream.client.suspend()
            onSessionRetired?(id)
        }
        activeMappings = activeMappings.filter { _, mapping in
            !DirectHermesSessionValidation.same(mapping.profileID, profileID)
        }
        return ids
    }

    /// Profile rows and visible session IDs can change while the socket owner
    /// remains the same. Force the next catalog read through a fresh typed
    /// client; retained sessions from unrelated profiles keep their journals.
    func invalidateCatalogAfterProfileChange() {
        activeMappings.removeAll()
        box.reset()
    }
}
