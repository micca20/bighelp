import Foundation

/// Native presentation readback, reactions, media, context and subagent projection.
extension DirectHermesConversationClient {
    func retainVisibleState() {
        if let model { projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents) }
    }

    func publishNativeMessageReactions() {
        guard let model else { return }
        for rowID in retainedMessageReactions.keys.sorted() {
            if let reaction = retainedMessageReactions[rowID] {
                model.reconcileNativeMessageReaction(reaction, from: self)
            }
        }
    }

    func retainNativeMessageReaction(_ reaction: DirectHermesMessageReaction) {
        if retainedMessageReactions[reaction.rowID] == nil,
           retainedMessageReactions.count >= 4_096,
           let smallestRowID = retainedMessageReactions.keys.min() {
            retainedMessageReactions[smallestRowID] = nil
        }
        retainedMessageReactions[reaction.rowID] = reaction
    }

    @discardableResult
    func publishMessageReactionReadback(
        _ result: DirectHermesMessageReactionResult,
        role: DirectHermesReactionRole,
        connectionGeneration: UUID
    ) -> Bool {
        guard connected, generation == connectionGeneration else { return false }
        let values = result.reactions.map { value -> LoopdyJSONValue in
            var object: [String: LoopdyJSONValue] = [
                "emoji": .string(value.emoji),
                "author": .string(value.author),
            ]
            if let at = value.at { object["at"] = .number(at) }
            if let seen = value.seen { object["seen"] = .boolean(seen) }
            return .object(object)
        }
        let event = DirectHermesEvent(
            type: "message.reaction",
            sessionID: runtimeID,
            payload: [
                "row_id": .integer(result.rowID),
                "role": .string(role.rawValue),
                "reactions": .array(values),
            ],
            sequence: nil
        )
        guard let reaction = try? DirectHermesMessageReaction(event: event) else { return false }
        retainNativeMessageReaction(reaction)
        model?.reconcileNativeMessageReaction(reaction, from: self)
        return true
    }

    func resetNativeMessageReactionsForEpochChange() {
        retainedMessageReactions.removeAll()
        model?.resetNativeMessageReactions(from: self)
    }

    private func hydrateDurableMessageReactions(
        activation: [String: LoopdyJSONValue],
        owner: UUID
    ) async {
        do {
            let snapshot: DirectHermesDurableReactionSnapshot?
            if usesCatalogHistory {
                guard let http = rpc as? any DirectHermesAuthenticatedHTTP else { return }
                let capturedRuntimeID = runtimeID
                let capturedStoredID = storedID
                snapshot = try await DirectHermesReactionHistoryLoader.load(
                    http: http,
                    storedSessionID: capturedStoredID,
                    profileID: profile,
                    remainsOwned: { [weak self] in
                        guard let self else { return false }
                        return self.connected && self.generation == owner
                            && Data(self.runtimeID.utf8) == Data(capturedRuntimeID.utf8)
                            && Data(self.storedID.utf8) == Data(capturedStoredID.utf8)
                    }
                )
            } else if let messages = activation["messages"]?.array {
                snapshot = try DirectHermesReactionHistoryDecoder.decode(messages: messages)
            } else {
                snapshot = nil
            }
            guard connected, generation == owner, let snapshot else { return }
            retainedMessageReactions = snapshot.reactionsByRowID
            model?.reconcileAuthoritativeNativeMessageReactions(
                snapshot.reactionsByRowID,
                from: self
            )
        } catch {
            // Reaction hydration is presentation-only. A malformed or legacy
            // response cannot authorize clearing live state or blocking the
            // canonical transcript recovery.
        }
    }

    /// Agent-authored reactions are durable SessionDB metadata and may not have
    /// a client event bridge on non-Desktop sessions. Refresh once at the native
    /// terminal event (and after recovery), never on a timer or in the replay
    /// critical path.
    func scheduleDurableMessageReactionHydration(
        activation: [String: LoopdyJSONValue]
    ) {
        guard usesCatalogHistory else { return }
        let owner = generation
        reactionHydrationTask?.cancel()
        reactionHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hydrateDurableMessageReactions(
                activation: activation,
                owner: owner
            )
            if self.generation == owner {
                self.reactionHydrationTask = nil
            }
        }
    }

    func publishSnapshot() {
        var record = workspaceRecord ?? SessionRecord(id: conversationID, kind: .direct, agentIDs: [profile], title: title,
            remoteStoredID: storedID, remoteSource: "direct-hermes", draft: journal.draft,
            items: projection.items, activityEvents: projection.activities, isActive: projection.running)
        record.remoteStoredID = storedID
        record.title = title
        record.items = projection.items
        record.activityEvents = projection.activities
        record.isActive = projection.running
        record.sessionContext = sessionContext ?? record.sessionContext
        if usesCatalogHistory { workspaceRecord = record }
        model?.adoptNativeSnapshot(from: self, session: record)
        scheduleMessageMedia()
    }

    /// Downloads never hold up text, turn settlement, or navigation. Failed
    /// references remain readable and can retry during explicit recovery.
    func scheduleMessageMedia() {
        guard connected, let attachmentResolver else { return }
        let owner = generation
        let stored = storedID
        for item in projection.items {
            guard attachmentTasks.count < 2 else { break }
            guard item.metadata.delivery != "Streaming", item.attachments.isEmpty,
                  case .message(let text) = item.content,
                  DirectHermesGeneratedMediaClient.hasAttachmentDirectives(text, role: item.role),
                  attachmentTasks[item.id] == nil else { continue }
            let key = stored + "\0" + item.role.rawValue + "\0" + text
            guard attachmentAttempts[item.id] != key else { continue }
            attachmentAttempts[item.id] = key
            attachmentTasks[item.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.generation == owner {
                        self.attachmentTasks[item.id] = nil
                        self.scheduleMessageMedia()
                    }
                }
                do {
                    let results = try await attachmentResolver.resolve(agentID: self.profile, storedID: stored,
                        items: [.init(id: item.id, text: text, role: item.role)])
                    try Task.checkCancellation()
                    guard self.connected, self.generation == owner, self.storedID == stored,
                          results.count == 1, let result = results.first, result.id == item.id,
                          !result.attachments.isEmpty,
                          let enriched = self.projection.resolveMedia(result, replacing: item) else { return }
                    self.model?.applyNativeMedia(enriched, replacing: item, from: self)
                } catch {
                    // Preserve the original marker on refusal or failure.
                }
            }
        }
    }

    func validatedActivationSnapshot(
        _ value: LoopdyJSONValue
    ) throws -> [String: LoopdyJSONValue] {
        guard let object = value.object,
              let snapshotRuntimeID = object["session_id"]?.string,
              Data(snapshotRuntimeID.utf8) == Data(runtimeID.utf8) else {
            throw DirectHermesError.invalidResponse
        }
        if usesCatalogHistory {
            guard let sessionKey = object["session_key"]?.string,
                  Data(sessionKey.utf8) == Data(storedID.utf8) else {
                throw DirectHermesError.invalidResponse
            }
        }
        let durableAliases = ["session_key", "stored_session_id", "resumed"].compactMap {
            object[$0]?.string
        }
        guard !durableAliases.isEmpty,
              durableAliases.allSatisfy({ Data($0.utf8) == Data(storedID.utf8) }) else {
            throw DirectHermesError.invalidResponse
        }
        if object.keys.contains(where: {
            ["session_key", "stored_session_id", "resumed"].contains($0)
                && object[$0]?.string == nil
        }) {
            throw DirectHermesError.invalidResponse
        }
        guard object["running"]?.boolean != nil else {
            throw DirectHermesError.invalidResponse
        }
        return object
    }

    func publishTodoSnapshot(_ snapshot: SessionTodoSnapshot) {
        if projection.todoSnapshot != snapshot,
           !projection.adoptTodoSnapshot(snapshot) { return }
        model?.reconcileTodos(snapshot)
        onSessionTodosChange?(snapshot)
    }

    func applySnapshotMetadata(_ snapshot: [String: LoopdyJSONValue]) {
        if let id = snapshot["session_id"]?.string, id != runtimeID {
            projection.resetCheckpoint()
            runtimeID = id
        }
        adoptStoredID(snapshot["stored_session_id"]?.string ?? snapshot["session_key"]?.string
            ?? snapshot["resumed"]?.string ?? storedID)
        let info = snapshot["info"]?.object ?? [:]
        if let name = info["model"]?.string { modelName = name }
        if let usage = info["usage"]?.object { acceptUsage(usage) }
        if let value = info["title"]?.string, !value.isEmpty {
            title = value
            model?.applyRenamedSessionTitle(value)
        }
    }

    func acceptUsage(_ usage: [String: LoopdyJSONValue]) {
        func count(_ key: String) -> Int? {
            guard let value = usage[key]?.integer, value >= 0, value <= 1_000_000_000_000 else { return nil }
            return value
        }
        // Missing usage on a lazy/older host does not erase a previously observed window.
        guard let used = count("context_used"), let maximum = count("context_max"), maximum > 0 else { return }
        let value = SessionContextSnapshot(sessionId: conversationID, title: title,
            model: usage["model"]?.string ?? modelName, contextUsed: used, contextMax: maximum,
            contextPercent: Int(min(100, (Double(used) / Double(maximum) * 100).rounded())),
            compressions: count("compressions") ?? 0, isCompacting: false,
            updatedAt: max(Int(Date.now.timeIntervalSince1970 * 1000), (sessionContext?.updatedAt ?? 0) + 1),
            sessionInputTokens: count("prompt"), sessionOutputTokens: count("output"),
            sessionCachedTokens: count("cached"), sessionTotalTokens: count("total"),
            sessionIncludesSubagents: false)
        sessionContext = value
        model?.reconcileSessionContext(value)
        onSessionContextChange?(value)
    }

    func publishNativeSubagent(_ item: NativeSubagentRailItem) {
        if item.lifecycle.isTerminal {
            nativeSubagentsByID[item.id] = nil
            terminalNativeSubagentIDs.insert(item.id)
        } else {
            terminalNativeSubagentIDs.remove(item.id)
            nativeSubagentsByID[item.id] = item.merging(nativeSubagentsByID[item.id])
        }
        nativeSubagents = nativeSubagentsByID.values.sorted {
            ($0.startedAt ?? Int.max, $0.id) < ($1.startedAt ?? Int.max, $1.id)
        }
        onNativeSubagentsChange?(nativeSubagents)
        model?.reconcileNativeSubagents(nativeSubagents)
    }

    private func clearNativeSubagents() {
        guard !nativeSubagents.isEmpty || !nativeSubagentsByID.isEmpty else { return }
        nativeSubagentsByID.removeAll(keepingCapacity: true)
        terminalNativeSubagentIDs.removeAll(keepingCapacity: true)
        nativeSubagents = []
        onNativeSubagentsChange?([])
        model?.reconcileNativeSubagents([])
    }

    func refreshNativeSubagents(owner: UUID) async {
        guard connected, generation == owner else { return }
        let eventRevision = nativeSubagentEventRevision
        do {
            let result = try await rpc.request("subagent.list", params: [
                "session_id": .string(runtimeID)
            ])
            guard !Task.isCancelled, connected, generation == owner,
                  nativeSubagentEventRevision == eventRevision else { return }
            guard let object = result.object,
                  let rows = object["subagents"]?.array else { return }
            let parsed = Self.nativeSubagentItems(from: object)
            guard parsed.count == rows.count,
                  Set(parsed.map(\.id)).count == parsed.count else { return }
            let listed = parsed.filter { !terminalNativeSubagentIDs.contains($0.id) }
            nativeSubagentsByID = Dictionary(uniqueKeysWithValues: listed.map { item in
                (item.id, item.merging(nativeSubagentsByID[item.id]))
            })
            nativeSubagents = nativeSubagentsByID.values.sorted {
                ($0.startedAt ?? Int.max, $0.id) < ($1.startedAt ?? Int.max, $1.id)
            }
            onNativeSubagentsChange?(nativeSubagents)
            model?.reconcileNativeSubagents(nativeSubagents)
        } catch {
            // The native stream remains authoritative when a host does not
            // expose the optional roster method or it races child cleanup.
        }
    }

    static func nativeSubagentItems(from object: [String: LoopdyJSONValue]) -> [NativeSubagentRailItem] {
        guard let rows = object["subagents"]?.array else { return [] }
        return rows.compactMap { value in
            guard let row = value.object,
                  let id = nonempty(row["subagent_id"]?.string) else { return nil }
            let status = nonempty(row["status"]?.string)
            let lifecycle: ChatActivityLifecycle = switch status?.lowercased() {
            case "failed", "error", "errored": .failed
            case "cancelled", "canceled", "interrupted": .cancelled
            case "completed", "complete", "done", "success", "succeeded": .succeeded
            default: .running
            }
            let startedAt = row["started_at"]?.number.flatMap {
                $0.isFinite && $0 >= 0 && $0 <= Double(Int.max) ? Int($0) : nil
            }
            let toolCount = row["tool_count"]?.integer.flatMap { $0 >= 0 ? $0 : nil }
            return NativeSubagentRailItem(
                id: id,
                childSessionID: nonempty(row["child_session_id"]?.string),
                parentID: nonempty(row["parent_id"]?.string),
                goal: nonempty(row["goal"]?.string) ?? "Subagent task",
                lifecycle: lifecycle,
                status: status,
                model: nonempty(row["model"]?.string),
                toolCount: toolCount,
                startedAt: startedAt
            )
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
