import CryptoKit
import Foundation

extension DirectHermesKanbanClient {
    // MARK: Fixed typed reads

    func assignees(board slug: String) async throws -> [String] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/assignees", method: .get,
            query: [.init(name: "board", value: try Self.identifier(slug, maximum: 120))],
            maximumResponseBytes: 128 * 1_024
        ))
        return try Self.strings(value.object?["assignees"], maximum: 512)
    }

    func configuration() async throws -> HermesKanbanConfiguration {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/config", method: .get,
            maximumResponseBytes: 64 * 1_024
        ))
        guard let row = value.object,
              let lane = row["lane_by_profile"]?.boolean,
              let archived = row["include_archived_by_default"]?.boolean,
              let markdown = row["render_markdown"]?.boolean else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(
            defaultTenant: try Self.optionalResponseText(row["default_tenant"], maximum: 240) ?? "",
            laneByProfile: lane,
            includesArchivedByDefault: archived,
            rendersMarkdown: markdown
        )
    }

    func statistics(board slug: String) async throws -> HermesKanbanStatistics {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/stats", method: .get,
            query: [.init(name: "board", value: try Self.identifier(slug, maximum: 120))],
            maximumResponseBytes: 256 * 1_024
        ))
        guard let row = value.object,
              let statusRows = row["by_status"]?.object,
              let assigneeRows = row["by_assignee"]?.object,
              let now = row["now"]?.number else { throw HermesKanbanError.invalidResponse }
        var byStatus: [HermesKanbanTaskStatus: Int] = [:]
        for (key, value) in statusRows {
            guard let status = HermesKanbanTaskStatus(rawValue: key), let count = value.integer, count >= 0 else {
                throw HermesKanbanError.invalidResponse
            }
            byStatus[status] = count
        }
        var byAssignee: [String: [HermesKanbanTaskStatus: Int]] = [:]
        for (assignee, value) in assigneeRows {
            guard assignee.utf8.count <= 160, let counts = value.object else { throw HermesKanbanError.invalidResponse }
            var typed: [HermesKanbanTaskStatus: Int] = [:]
            for (key, value) in counts {
                guard let status = HermesKanbanTaskStatus(rawValue: key), let count = value.integer, count >= 0 else {
                    throw HermesKanbanError.invalidResponse
                }
                typed[status] = count
            }
            byAssignee[assignee] = typed
        }
        let oldest = try Self.optionalAdminInteger(row["oldest_ready_age_seconds"], minimum: 0)
        return .init(
            countsByStatus: byStatus, countsByAssignee: byAssignee,
            oldestReadyAgeSeconds: oldest, fetchedAt: Date(timeIntervalSince1970: now)
        )
    }

    func diagnostics(
        board slug: String,
        minimumSeverity: HermesKanbanDiagnosticSeverity? = nil
    ) async throws -> [HermesKanbanDiagnostic] {
        try await requireMount()
        var query = [URLQueryItem(name: "board", value: try Self.identifier(slug, maximum: 120))]
        if let minimumSeverity { query.append(.init(name: "severity", value: minimumSeverity.rawValue)) }
        let value = try await request(.init(
            path: "/api/plugins/kanban/diagnostics", method: .get,
            query: query, maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        guard let groups = value.object?["diagnostics"]?.array, groups.count <= 2_000 else {
            throw HermesKanbanError.invalidResponse
        }
        var result: [HermesKanbanDiagnostic] = []
        for groupValue in groups {
            guard let group = groupValue.object,
                  let taskID = group["task_id"]?.string,
                  let rows = group["diagnostics"]?.array, rows.count <= 32 else {
                throw HermesKanbanError.invalidResponse
            }
            for value in rows {
                guard let row = value.object,
                      let severityRaw = row["severity"]?.string,
                      let severity = HermesKanbanDiagnosticSeverity(rawValue: severityRaw),
                      let count = row["count"]?.integer, count >= 1 else {
                    throw HermesKanbanError.invalidResponse
                }
                result.append(.init(
                    taskID: try Self.identifier(taskID, maximum: 240),
                    taskTitle: try Self.optionalResponseText(group["task_title"], maximum: 8_192),
                    taskStatus: group["task_status"]?.string.flatMap(HermesKanbanTaskStatus.init(rawValue:)),
                    taskAssignee: try Self.optionalResponseText(group["task_assignee"], maximum: 160),
                    kind: try Self.responseText(row["kind"], maximum: 120),
                    severity: severity,
                    title: try Self.responseText(row["title"], maximum: 2_048),
                    detail: try Self.responseText(row["detail"], maximum: 16_384, empty: true),
                    count: count,
                    firstSeenAt: try Self.optionalAdminDate(row["first_seen_at"]),
                    lastSeenAt: try Self.optionalAdminDate(row["last_seen_at"]),
                    runID: try Self.optionalAdminInteger(row["run_id"], minimum: 1)
                ))
            }
        }
        guard Set(result.map { Data($0.id.utf8) }).count == result.count else { throw HermesKanbanError.invalidResponse }
        return result
    }

    func projects() async throws -> [HermesKanbanProject] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/projects", method: .get,
            maximumResponseBytes: 512 * 1_024
        ))
        guard let rows = value.object?["projects"]?.array, rows.count <= 1_000 else {
            throw HermesKanbanError.invalidResponse
        }
        let decoded = try rows.map { value -> HermesKanbanProject in
            guard let row = value.object else { throw HermesKanbanError.invalidResponse }
            return .init(
                id: try Self.responseText(row["id"], maximum: 240),
                slug: try Self.responseText(row["slug"], maximum: 240),
                name: try Self.responseText(row["name"], maximum: 512),
                primaryPath: try Self.optionalResponseText(row["primary_path"], maximum: 4_096) ?? "",
                icon: try Self.optionalResponseText(row["icon"], maximum: 120),
                color: try Self.optionalResponseText(row["color"], maximum: 120)
            )
        }
        guard Set(decoded.map { Data($0.id.utf8) }).count == decoded.count else { throw HermesKanbanError.invalidResponse }
        return decoded
    }

    func modelOptions() async throws -> [HermesKanbanModelProvider] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/model-options", method: .get,
            maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        guard let rows = value.object?["providers"]?.array, rows.count <= 256 else {
            throw HermesKanbanError.invalidResponse
        }
        let providers = try rows.map { value -> HermesKanbanModelProvider in
            guard let row = value.object else { throw HermesKanbanError.invalidResponse }
            return .init(
                slug: try Self.responseText(row["slug"], maximum: 256),
                label: try Self.responseText(row["label"], maximum: 512),
                models: try Self.strings(row["models"], maximum: 2_000)
            )
        }
        guard Set(providers.map { Data($0.slug.utf8) }).count == providers.count else { throw HermesKanbanError.invalidResponse }
        return providers
    }

    func profiles() async throws -> [HermesKanbanProfile] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/profiles", method: .get,
            maximumResponseBytes: 512 * 1_024
        ))
        guard let rows = value.object?["profiles"]?.array, rows.count <= 1_000 else {
            throw HermesKanbanError.invalidResponse
        }
        let profiles = try rows.map(Self.decodeProfile)
        guard Set(profiles.map { Data($0.name.utf8) }).count == profiles.count else { throw HermesKanbanError.invalidResponse }
        return profiles
    }

    func orchestration() async throws -> HermesKanbanOrchestration {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/orchestration", method: .get,
            maximumResponseBytes: 64 * 1_024
        ))
        return try Self.decodeOrchestration(value)
    }

    func homeChannels(taskID: String? = nil, board slug: String) async throws -> [HermesKanbanHomeChannel] {
        try await requireMount()
        var query = [URLQueryItem(name: "board", value: try Self.identifier(slug, maximum: 120))]
        if let taskID { query.append(.init(name: "task_id", value: try Self.identifier(taskID, maximum: 240))) }
        let value = try await request(.init(
            path: "/api/plugins/kanban/home-channels", method: .get,
            query: query, maximumResponseBytes: 256 * 1_024
        ))
        guard let rows = value.object?["home_channels"]?.array, rows.count <= 64 else {
            throw HermesKanbanError.invalidResponse
        }
        let channels = try rows.map { value -> HermesKanbanHomeChannel in
            guard let row = value.object, let subscribed = row["subscribed"]?.boolean else {
                throw HermesKanbanError.invalidResponse
            }
            return .init(
                platform: try Self.responseText(row["platform"], maximum: 120),
                name: try Self.responseText(row["name"], maximum: 240),
                isSubscribed: subscribed
            )
        }
        guard Set(channels.map { Data($0.platform.utf8) }).count == channels.count else { throw HermesKanbanError.invalidResponse }
        return channels
    }

    func activeWorkers(board slug: String) async throws -> [HermesKanbanActiveWorker] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/workers/active", method: .get,
            query: [.init(name: "board", value: try Self.identifier(slug, maximum: 120))],
            maximumResponseBytes: 512 * 1_024
        ))
        guard let rows = value.object?["workers"]?.array, rows.count <= 2_000 else {
            throw HermesKanbanError.invalidResponse
        }
        let workers = try rows.map { value -> HermesKanbanActiveWorker in
            guard let row = value.object,
                  let runID = row["run_id"]?.integer, runID > 0,
                  let processID = row["worker_pid"]?.integer, processID > 0 else {
                throw HermesKanbanError.invalidResponse
            }
            return .init(
                runID: runID,
                taskID: try Self.responseText(row["task_id"], maximum: 240),
                taskTitle: try Self.responseText(row["task_title"], maximum: 8_192),
                assignee: try Self.optionalResponseText(row["task_assignee"], maximum: 160),
                profile: try Self.optionalResponseText(row["profile"], maximum: 160),
                processID: processID,
                startedAt: try Self.adminDate(row["started_at"]),
                lastHeartbeatAt: try Self.optionalAdminDate(row["last_heartbeat_at"]),
                maximumRuntimeSeconds: try Self.optionalAdminInteger(row["max_runtime_seconds"], minimum: 1)
            )
        }
        guard Set(workers.map(\.runID)).count == workers.count else { throw HermesKanbanError.invalidResponse }
        return workers
    }

    /// The endpoint always returns raw worker content. Loopdy deliberately drops it
    /// at the decoding boundary because the mounted API offers no redacted-log mode.
    func taskLogMetadata(taskID: String, board slug: String, tailBytes: Int = 65_536) async throws
        -> HermesKanbanTaskLog {
        try await requireMount()
        guard (1...2_000_000).contains(tailBytes) else { throw HermesKanbanError.invalidRequest }
        let taskID = try Self.identifier(taskID, maximum: 240)
        let value = try await request(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(taskID))/log", method: .get,
            query: [
                .init(name: "board", value: try Self.identifier(slug, maximum: 120)),
                .init(name: "tail", value: String(tailBytes)),
            ], maximumResponseBytes: min(tailBytes + 128 * 1_024, 2_200_000)
        ))
        guard let row = value.object,
              row["task_id"]?.string.map({ Self.exact($0, taskID) }) == true,
              let exists = row["exists"]?.boolean,
              let size = row["size_bytes"]?.integer, size >= 0,
              let truncated = row["truncated"]?.boolean,
              row["content"]?.string != nil else { throw HermesKanbanError.invalidResponse }
        return .init(taskID: taskID, exists: exists, byteCount: size, isTruncated: truncated)
    }

    func estimate(title: String, body: String?) async throws -> HermesKanbanEstimate {
        try await requireMount()
        let title = try Self.text(title.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 8_192)
        let body = try body.map { try Self.text($0, maximum: Self.maximumTextBytes, empty: true) }
        return try Self.decodeEstimate(await request(.init(
            path: "/api/plugins/kanban/estimate", method: .post,
            body: ["title": .string(title), "body": body.map(LoopdyJSONValue.string) ?? .null],
            maximumResponseBytes: 64 * 1_024
        )))
    }

    func estimate(taskID: String, board slug: String) async throws -> HermesKanbanEstimate {
        try await requireMount()
        let taskID = try Self.identifier(taskID, maximum: 240)
        return try Self.decodeEstimate(await request(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(taskID))/estimate", method: .post,
            query: [.init(name: "board", value: try Self.identifier(slug, maximum: 120))],
            maximumResponseBytes: 64 * 1_024
        )))
    }

    // MARK: Review preparation

    func prepareBoardCreation(_ draft: HermesKanbanBoardDraft) async throws -> HermesKanbanAdministrationReview {
        var draft = draft
        draft.slug = try Self.boardSlug(draft.slug)
        draft.name = try Self.text(draft.name, maximum: 240, empty: true)
        draft.summary = try Self.text(draft.summary, maximum: 16_384, empty: true)
        draft.icon = try Self.text(draft.icon, maximum: 120, empty: true)
        draft.color = try Self.text(draft.color, maximum: 120, empty: true)
        draft.defaultWorkdir = try Self.text(draft.defaultWorkdir, maximum: 4_096, empty: true)
        draft.projectID = try Self.text(draft.projectID, maximum: 240, empty: true)
        let catalog = try await boards(includeArchived: true)
        guard !catalog.contains(where: { Self.exact($0.slug, draft.slug) }) else { throw HermesKanbanError.invalidRequest }
        return .init(action: .createBoard(draft, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareBoardEdit(slug: String, patch: HermesKanbanBoardPatch) async throws -> HermesKanbanAdministrationReview {
        guard !patch.isEmpty else { throw HermesKanbanError.invalidRequest }
        let catalog = try await boards(includeArchived: true)
        guard let board = catalog.first(where: { Self.exact($0.slug, slug) }), !board.isArchived else {
            throw HermesKanbanError.invalidRequest
        }
        let patch = try Self.validated(patch)
        guard !Self.verify(patch, in: board) else { throw HermesKanbanError.invalidRequest }
        return .init(action: .editBoard(board, patch, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareBoardSwitch(slug: String) async throws -> HermesKanbanAdministrationReview {
        let catalog = try await boards(includeArchived: true)
        guard let board = catalog.first(where: { Self.exact($0.slug, slug) }), !board.isArchived, !board.isCurrent else {
            throw HermesKanbanError.invalidRequest
        }
        return .init(action: .switchBoard(board, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareBoardRemoval(slug: String, mode: HermesKanbanBoardRemovalMode) async throws
        -> HermesKanbanAdministrationReview {
        let catalog = try await boards(includeArchived: true)
        guard let board = catalog.first(where: { Self.exact($0.slug, slug) }), board.slug != "default" else {
            throw HermesKanbanError.invalidRequest
        }
        return .init(action: .removeBoard(board, mode, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareBoardExport(slug: String, options: HermesKanbanBoardExportOptions) async throws
        -> HermesKanbanAdministrationReview {
        let catalog = try await boards(includeArchived: true)
        guard let board = catalog.first(where: { Self.exact($0.slug, slug) }), !board.isArchived else {
            throw HermesKanbanError.invalidRequest
        }
        return .init(action: .exportBoard(board, options, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareBoardImport(_ request: HermesKanbanBoardImportRequest) async throws -> HermesKanbanAdministrationReview {
        var request = request
        request.hostArchivePath = try Self.identifier(
            request.hostArchivePath.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 4_096
        )
        let slugOverride = request.slugOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if slugOverride.isEmpty {
            request.slugOverride = ""
        } else {
            request.slugOverride = try Self.boardSlug(slugOverride)
        }
        let catalog = try await boards(includeArchived: true)
        return .init(action: .importBoard(request, catalogRevision: try Self.catalogRevision(catalog)))
    }

    func prepareOrchestrationEdit(_ patch: HermesKanbanOrchestrationPatch) async throws
        -> HermesKanbanAdministrationReview {
        guard !patch.isEmpty else { throw HermesKanbanError.invalidRequest }
        let current = try await orchestration()
        guard !Self.verify(patch, in: current) else { throw HermesKanbanError.invalidRequest }
        return .init(action: .editOrchestration(current, patch, revision: try Self.orchestrationRevision(current)))
    }

    func prepareProfileEdit(name: String, summary: String) async throws -> HermesKanbanAdministrationReview {
        let roster = try await profiles()
        guard let profile = roster.first(where: { Self.exact($0.name, name) }) else { throw HermesKanbanError.invalidRequest }
        let summary = try Self.text(summary.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 16_384, empty: true)
        guard summary != profile.summary else { throw HermesKanbanError.invalidRequest }
        return .init(action: .editProfile(profile, summary: summary, revision: try Self.profileRevision(profile)))
    }

    func prepareAutomaticProfileDescription(name: String, overwrite: Bool) async throws
        -> HermesKanbanAdministrationReview {
        let roster = try await profiles()
        guard let profile = roster.first(where: { Self.exact($0.name, name) }), overwrite || profile.summary.isEmpty else {
            throw HermesKanbanError.invalidRequest
        }
        return .init(action: .autoDescribeProfile(profile, overwrite: overwrite, revision: try Self.profileRevision(profile)))
    }

    func prepareBulkTasks(ids: [String], board slug: String, patch: HermesKanbanBulkPatch) async throws
        -> HermesKanbanAdministrationReview {
        var patch = patch
        patch.assignee = try patch.assignee.map { try Self.text($0, maximum: 160, empty: true) }
        patch.modelOverride = try patch.modelOverride.map { try Self.text($0, maximum: 512) }
        patch.providerOverride = try patch.providerOverride.map { try Self.text($0, maximum: 256) }
        patch.reasoningEffort = try patch.reasoningEffort.map { try Self.text($0, maximum: 80) }
        guard !patch.isEmpty, !ids.isEmpty, ids.count <= 100,
              !(patch.clearsModelOverride && patch.modelOverride != nil),
              patch.providerOverride == nil || patch.modelOverride != nil,
              patch.reasoningEffort.map({ ["none", "minimal", "low", "medium", "high", "xhigh", "ultra"].contains($0) }) ?? true,
              patch.status.map({ $0.canBeSetDirectly && $0 != .archived }) ?? true,
              patch.priority.map({ (-1_000...1_000).contains($0) }) ?? true else {
            throw HermesKanbanError.invalidRequest
        }
        if let model = patch.modelOverride {
            guard let provider = patch.providerOverride,
                  let options = try await modelOptions().first(where: { Self.exact($0.slug, provider) }),
                  options.models.contains(where: { Self.exact($0, model) }) else {
                throw HermesKanbanError.invalidRequest
            }
        }
        let unique = try ids.map { try Self.identifier($0, maximum: 240) }
        guard Set(unique.map { Data($0.utf8) }).count == unique.count else { throw HermesKanbanError.invalidRequest }
        var revisions: [HermesKanbanReviewedTaskRevision] = []
        var changesAtLeastOneTask = false
        for id in unique {
            let detail = try await task(id: id, board: slug)
            revisions.append(.init(taskID: id, revision: detail.revision))
            if !Self.verify(patch, in: detail.task) { changesAtLeastOneTask = true }
        }
        guard changesAtLeastOneTask else { throw HermesKanbanError.invalidRequest }
        return .init(action: .bulkTasks(
            boardSlug: try Self.identifier(slug, maximum: 120), taskIDs: unique,
            patch: patch, revisions: revisions
        ))
    }

    func prepareTaskDeletion(taskID: String, board slug: String) async throws -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        return .init(action: .deleteTask(boardSlug: slug, task: detail.task, revision: detail.revision))
    }

    func prepareTaskLink(parentID: String, childID: String, board slug: String, remove: Bool) async throws
        -> HermesKanbanAdministrationReview {
        guard !Self.exact(parentID, childID) else { throw HermesKanbanError.invalidRequest }
        let parent = try await task(id: parentID, board: slug)
        let child = try await task(id: childID, board: slug)
        let exists = child.parentIDs.contains(where: { Self.exact($0, parentID) })
        guard exists == remove else { throw HermesKanbanError.invalidRequest }
        return .init(action: .linkTasks(
            boardSlug: slug, parent: parent.task, child: child.task, remove: remove,
            revisions: [
                .init(taskID: parent.task.id, revision: parent.revision),
                .init(taskID: child.task.id, revision: child.revision),
            ]
        ))
    }

    func prepareReassignment(
        taskID: String, board slug: String, profile: String?, reclaimFirst: Bool, reason: String?
    ) async throws -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        let profile = try profile.map { try Self.text($0, maximum: 160, empty: true) }
        let reason = try reason.map { try Self.text($0, maximum: 2_048, empty: true) }
        guard reclaimFirst || detail.task.assignee != profile else { throw HermesKanbanError.invalidRequest }
        return .init(action: .reassignTask(
            boardSlug: slug, task: detail.task, profile: profile, reclaimFirst: reclaimFirst,
            reason: reason, revision: detail.revision
        ))
    }

    func prepareReclaim(taskID: String, board slug: String, reason: String?) async throws
        -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        guard detail.task.status == .running, detail.task.currentRunID != nil else { throw HermesKanbanError.invalidRequest }
        return .init(action: .reclaimTask(
            boardSlug: slug, task: detail.task,
            reason: try reason.map { try Self.text($0, maximum: 2_048, empty: true) },
            revision: detail.revision
        ))
    }

    func prepareSpecify(taskID: String, board slug: String) async throws -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        guard detail.task.status == .triage else { throw HermesKanbanError.invalidRequest }
        return .init(action: .specifyTask(boardSlug: slug, task: detail.task, revision: detail.revision))
    }

    func prepareDecompose(taskID: String, board slug: String) async throws -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        guard detail.task.status == .triage else { throw HermesKanbanError.invalidRequest }
        return .init(action: .decomposeTask(boardSlug: slug, task: detail.task, revision: detail.revision))
    }

    func prepareHomeSubscription(
        taskID: String, board slug: String, platform: String, subscribed: Bool
    ) async throws -> HermesKanbanAdministrationReview {
        let detail = try await task(id: taskID, board: slug)
        let channels = try await homeChannels(taskID: taskID, board: slug)
        guard let channel = channels.first(where: { Self.exact($0.platform, platform) }),
              channel.isSubscribed != subscribed else { throw HermesKanbanError.invalidRequest }
        return .init(action: .setHomeSubscription(
            boardSlug: slug, task: detail.task, channel: channel, subscribed: subscribed,
            revision: detail.revision
        ))
    }

    // MARK: Reviewed mutation execution

    func perform(approved review: HermesKanbanAdministrationReview) async throws -> HermesKanbanAdministrationResult {
        switch review.action {
        case .createBoard(let draft, let revision):
            return .boards(try await createBoard(draft, catalogRevision: revision))
        case .editBoard(let board, let patch, let revision):
            return .boards(try await editBoard(board, patch: patch, catalogRevision: revision))
        case .switchBoard(let board, let revision):
            return .boards(try await switchBoard(board, catalogRevision: revision))
        case .removeBoard(let board, let mode, let revision):
            return .boards(try await removeBoard(board, mode: mode, catalogRevision: revision))
        case .exportBoard(let board, let options, let revision):
            return .boardExport(try await exportBoard(board, options: options, catalogRevision: revision))
        case .importBoard(let request, let revision):
            let result = try await importBoard(request, catalogRevision: revision)
            return .boardImport(result.0, result.1)
        case .editOrchestration(let before, let patch, let revision):
            return .orchestration(try await editOrchestration(before, patch: patch, revision: revision))
        case .editProfile(let profile, let summary, let revision):
            return .profile(try await editProfile(profile, summary: summary, revision: revision), nil)
        case .autoDescribeProfile(let profile, let overwrite, let revision):
            let result = try await describeProfile(profile, overwrite: overwrite, revision: revision)
            return .profile(result.0, result.1)
        case .bulkTasks(let board, let ids, let patch, let revisions):
            let result = try await bulkTasks(board: board, ids: ids, patch: patch, revisions: revisions)
            return .bulk(result, try await self.board(slug: board))
        case .deleteTask(let board, let task, let revision):
            try await deleteTask(board: board, task: task, revision: revision)
            return .task(nil)
        case .linkTasks(let board, let parent, let child, let remove, let revisions):
            return .task(try await setLink(
                board: board, parent: parent, child: child, remove: remove, revisions: revisions
            ))
        case .reassignTask(let board, let task, let profile, let reclaimFirst, let reason, let revision):
            return .task(try await reassignTask(
                board: board, task: task, profile: profile, reclaimFirst: reclaimFirst,
                reason: reason, revision: revision
            ))
        case .reclaimTask(let board, let task, let reason, let revision):
            return .task(try await reclaimTask(board: board, task: task, reason: reason, revision: revision))
        case .specifyTask(let board, let task, let revision):
            let result = try await runAuxiliary(.specify, board: board, task: task, revision: revision)
            return .auxiliary(result.0, result.1)
        case .decomposeTask(let board, let task, let revision):
            let result = try await runAuxiliary(.decompose, board: board, task: task, revision: revision)
            return .auxiliary(result.0, result.1)
        case .setHomeSubscription(let board, let task, let channel, let subscribed, let revision):
            let result = try await setHomeSubscription(
                board: board, task: task, channel: channel, subscribed: subscribed, revision: revision
            )
            return .homeChannels(result.0, result.1)
        case .addComment(let board, let task, let body, let revision):
            let approved = HermesKanbanCommentReview(
                boardSlug: board, task: task, body: body, revision: revision
            )
            return .task(try await addComment(approved: approved))
        }
    }

    // MARK: Reviewed mutation implementations

    private func createBoard(_ draft: HermesKanbanBoardDraft, catalogRevision: Data) async throws
        -> [HermesKanbanBoard] {
        let before = try await verifiedCatalog(catalogRevision)
        guard !before.contains(where: { Self.exact($0.slug, draft.slug) }) else { throw HermesKanbanError.reviewChanged }
        var body: [String: LoopdyJSONValue] = [
            "slug": .string(draft.slug), "name": .string(draft.name),
            "description": .string(draft.summary), "icon": .string(draft.icon),
            "color": .string(draft.color), "default_workdir": .string(draft.defaultWorkdir),
            "project_id": .string(draft.projectID), "switch": .boolean(draft.switchAfterCreation),
        ]
        if draft.defaultWorkdir.isEmpty { body.removeValue(forKey: "default_workdir") }
        if draft.projectID.isEmpty { body.removeValue(forKey: "project_id") }
        guard let receipt = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/boards", method: .post,
            body: body, maximumResponseBytes: 128 * 1_024
        )) else {
            throw HermesKanbanError.mutationNotVerified
        }
        guard let receivedSlug = receipt.object?["board"]?.object?["slug"]?.string else {
            throw HermesKanbanError.mutationNotVerified
        }
        let after = try await boards(includeArchived: true)
        guard after.count == before.count + 1,
              let created = after.first(where: { Self.exact($0.slug, receivedSlug) }),
              Self.board(created, matches: draft),
              !draft.switchAfterCreation || created.isCurrent else {
            throw HermesKanbanError.mutationNotVerified
        }
        return after.filter { !$0.isArchived }
    }

    private func editBoard(
        _ board: HermesKanbanBoard, patch: HermesKanbanBoardPatch, catalogRevision: Data
    ) async throws -> [HermesKanbanBoard] {
        _ = try await verifiedBoard(board, catalogRevision: catalogRevision)
        let body = Self.boardPatchBody(patch)
        guard !body.isEmpty else { throw HermesKanbanError.invalidRequest }
        _ = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/boards/\(Self.component(board.slug))", method: .patch,
            body: body, maximumResponseBytes: 128 * 1_024
        ))
        let after = try await boards(includeArchived: true)
        guard let updated = after.first(where: { Self.exact($0.slug, board.slug) }),
              Self.verify(patch, in: updated) else { throw HermesKanbanError.mutationNotVerified }
        return after.filter { !$0.isArchived }
    }

    private func switchBoard(_ board: HermesKanbanBoard, catalogRevision: Data) async throws
        -> [HermesKanbanBoard] {
        _ = try await verifiedBoard(board, catalogRevision: catalogRevision)
        let receipt = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/boards/\(Self.component(board.slug))/switch", method: .post,
            maximumResponseBytes: 64 * 1_024
        ))
        if let receipt,
           receipt.object?["current"]?.string.map({ Self.exact($0, board.slug) }) != true {
            throw HermesKanbanError.mutationNotVerified
        }
        let after = try await boards(includeArchived: true)
        guard after.first(where: { Self.exact($0.slug, board.slug) })?.isCurrent == true,
              after.filter(\.isCurrent).count == 1 else { throw HermesKanbanError.mutationNotVerified }
        return after.filter { !$0.isArchived }
    }

    private func removeBoard(
        _ board: HermesKanbanBoard, mode: HermesKanbanBoardRemovalMode, catalogRevision: Data
    ) async throws -> [HermesKanbanBoard] {
        _ = try await verifiedBoard(board, catalogRevision: catalogRevision)
        let receipt = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/boards/\(Self.component(board.slug))", method: .delete,
            query: [.init(name: "delete", value: mode == .delete ? "true" : "false")],
            maximumResponseBytes: 128 * 1_024
        ))
        let expectedAction = mode == .archive ? "archived" : "deleted"
        if let receipt,
           !(receipt.object?["result"]?.object?["slug"]?.string.map({ Self.exact($0, board.slug) }) == true &&
             receipt.object?["result"]?.object?["action"]?.string == expectedAction) {
            throw HermesKanbanError.mutationNotVerified
        }
        let after = try await boards(includeArchived: true)
        guard !after.contains(where: { Self.exact($0.slug, board.slug) }) else {
            throw HermesKanbanError.mutationNotVerified
        }
        return after.filter { !$0.isArchived }
    }

    private func exportBoard(
        _ board: HermesKanbanBoard, options: HermesKanbanBoardExportOptions, catalogRevision: Data
    ) async throws -> HermesKanbanBoardExportReceipt {
        _ = try await verifiedBoard(board, catalogRevision: catalogRevision)
        let value = try await mutate(.init(
            path: "/api/plugins/kanban/boards/\(Self.component(board.slug))/export", method: .post,
            body: [
                "output": .string(""), "attachments": .boolean(options.includesAttachments),
                "logs": .boolean(options.includesLogs),
            ], maximumResponseBytes: 128 * 1_024
        ))
        guard let row = value.object,
              row["board"]?.string.map({ Self.exact($0, board.slug) }) == true,
              let path = row["archive"]?.string,
              let size = row["size"]?.integer, size > 0 else { throw HermesKanbanError.mutationNotVerified }
        return .init(
            boardSlug: board.slug, archiveFilename: (path as NSString).lastPathComponent,
            byteCount: size, counts: try Self.integerMap(row["counts"])
        )
    }

    private func importBoard(
        _ importRequest: HermesKanbanBoardImportRequest, catalogRevision: Data
    ) async throws -> (HermesKanbanBoardImportReceipt, [HermesKanbanBoard]) {
        let before = try await verifiedCatalog(catalogRevision)
        let value = try await mutate(.init(
            path: "/api/plugins/kanban/boards/import", method: .post,
            body: [
                "archive": .string(importRequest.hostArchivePath),
                "slug": importRequest.slugOverride.isEmpty ? .null : .string(importRequest.slugOverride),
                "switch": .boolean(importRequest.switchAfterImport),
            ], maximumResponseBytes: 256 * 1_024
        ))
        guard let row = value.object,
              let slug = row["board"]?.string,
              let requested = row["requested_board"]?.string,
              let renamed = row["renamed"]?.boolean,
              let name = row["name"]?.string,
              let attachments = row["attachments_restored"]?.integer, attachments >= 0,
              let parked = row["tasks_parked"]?.integer, parked >= 0,
              let activated = row["activated"]?.boolean else { throw HermesKanbanError.mutationNotVerified }
        let after = try await boards(includeArchived: true)
        guard after.count == before.count + 1,
              let imported = after.first(where: { Self.exact($0.slug, slug) }),
              !imported.isArchived,
              !importRequest.switchAfterImport || imported.isCurrent else {
            throw HermesKanbanError.mutationNotVerified
        }
        let warnings = (row["warnings"]?.array ?? []).compactMap(\.string).map { _ in
            "Hermes reported an import relocation warning."
        }
        return (.init(
            boardSlug: slug, requestedSlug: requested, wasRenamed: renamed, name: name,
            counts: try Self.integerMap(row["counts"]), restoredAttachmentCount: attachments,
            parkedTaskCount: parked, warnings: warnings, wasActivated: activated
        ), after.filter { !$0.isArchived })
    }

    private func editOrchestration(
        _ before: HermesKanbanOrchestration,
        patch: HermesKanbanOrchestrationPatch,
        revision: Data
    ) async throws -> HermesKanbanOrchestration {
        let current = try await orchestration()
        guard current == before, try Self.orchestrationRevision(current) == revision else {
            throw HermesKanbanError.reviewChanged
        }
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/orchestration", method: .put,
            body: Self.orchestrationBody(patch), maximumResponseBytes: 64 * 1_024
        ))
        let after = try await orchestration()
        if let value {
            let receipt = try Self.decodeOrchestration(value)
            guard receipt == after else { throw HermesKanbanError.mutationNotVerified }
        }
        guard Self.verify(patch, in: after) else { throw HermesKanbanError.mutationNotVerified }
        return after
    }

    private func editProfile(_ profile: HermesKanbanProfile, summary: String, revision: Data) async throws
        -> HermesKanbanProfile {
        let current = try await verifiedProfile(profile, revision: revision)
        _ = current
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/profiles/\(Self.component(profile.name))", method: .patch,
            body: ["description": .string(summary)], maximumResponseBytes: 64 * 1_024
        ))
        if let value,
           !(value.object?["ok"]?.boolean == true &&
             value.object?["profile"]?.string.map({ Self.exact($0, profile.name) }) == true) {
            throw HermesKanbanError.mutationNotVerified
        }
        guard let after = try await profiles().first(where: { Self.exact($0.name, profile.name) }),
              after.summary == summary, !after.summaryIsAutomatic else { throw HermesKanbanError.mutationNotVerified }
        return after
    }

    private func describeProfile(
        _ profile: HermesKanbanProfile, overwrite: Bool, revision: Data
    ) async throws -> (HermesKanbanProfile, HermesKanbanAuxiliaryOutcome) {
        _ = try await verifiedProfile(profile, revision: revision)
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/profiles/\(Self.component(profile.name))/describe-auto", method: .post,
            body: ["overwrite": .boolean(overwrite)], maximumResponseBytes: 128 * 1_024
        ))
        let after = try await profiles().first(where: { Self.exact($0.name, profile.name) })
        guard let after else { throw HermesKanbanError.mutationNotVerified }
        let ok: Bool
        if let row = value?.object {
            guard let receiptOK = row["ok"]?.boolean,
                  row["profile"]?.string.map({ Self.exact($0, profile.name) }) == true else {
                throw HermesKanbanError.mutationNotVerified
            }
            ok = receiptOK
            if receiptOK, row["description"]?.string != after.summary {
                throw HermesKanbanError.mutationNotVerified
            }
        } else {
            guard after.summaryIsAutomatic, !after.summary.isEmpty, after != profile else {
                throw HermesKanbanError.mutationNotVerified
            }
            ok = true
        }
        let outcome = HermesKanbanAuxiliaryOutcome(
            kind: .profileDescription, succeeded: ok, targetID: profile.name,
            reason: ok ? nil : "Hermes could not generate this profile description.",
            resultingTitle: nil, childIDs: []
        )
        guard ok else { throw HermesKanbanError.operationRefused }
        guard after.summaryIsAutomatic, !after.summary.isEmpty else {
            throw HermesKanbanError.mutationNotVerified
        }
        return (after, outcome)
    }

    private func bulkTasks(
        board: String, ids: [String], patch: HermesKanbanBulkPatch,
        revisions: [HermesKanbanReviewedTaskRevision]
    ) async throws -> HermesKanbanBulkResult {
        for id in ids {
            guard let reviewedRevision = Self.reviewedRevision(for: id, in: revisions),
                  try await task(id: id, board: board).revision == reviewedRevision else {
                throw HermesKanbanError.reviewChanged
            }
        }
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/bulk", method: .post,
            query: [.init(name: "board", value: board)],
            body: Self.bulkBody(ids: ids, patch: patch), maximumResponseBytes: 256 * 1_024
        ))
        let rows: [LoopdyJSONValue]
        if let value {
            guard let received = value.object?["results"]?.array, received.count == ids.count else {
                throw HermesKanbanError.mutationNotVerified
            }
            rows = received
        } else {
            rows = ids.map { .object(["id": .string($0), "ok": .boolean(true)]) }
        }
        var items: [HermesKanbanBulkResult.Item] = []
        var verified: [HermesKanbanTask] = []
        for value in rows {
            guard let row = value.object, let id = row["id"]?.string,
                  ids.contains(where: { Self.exact($0, id) }), let ok = row["ok"]?.boolean else {
                throw HermesKanbanError.invalidResponse
            }
            if ok {
                let detail = try await task(id: id, board: board)
                guard Self.verify(patch, in: detail.task) else { throw HermesKanbanError.mutationNotVerified }
                verified.append(detail.task)
            }
            items.append(.init(id: id, succeeded: ok, safeError: ok ? nil : "Hermes refused this task change."))
        }
        guard Set(items.map { Data($0.id.utf8) }).count == ids.count else { throw HermesKanbanError.invalidResponse }
        return .init(items: items, verifiedTasks: verified)
    }

    private func deleteTask(board: String, task original: HermesKanbanTask, revision: Data) async throws {
        guard try await task(id: original.id, board: board).revision == revision else {
            throw HermesKanbanError.reviewChanged
        }
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(original.id))", method: .delete,
            query: [.init(name: "board", value: board)], maximumResponseBytes: 64 * 1_024
        ))
        if let value,
           !(value.object?["deleted"]?.boolean == true &&
             value.object?["task_id"]?.string.map({ Self.exact($0, original.id) }) == true) {
            throw HermesKanbanError.mutationNotVerified
        }
        guard try await self.board(slug: board, includeArchived: true).tasks
            .allSatisfy({ !Self.exact($0.id, original.id) }) else { throw HermesKanbanError.mutationNotVerified }
    }

    private func setLink(
        board: String, parent: HermesKanbanTask, child: HermesKanbanTask,
        remove: Bool, revisions: [HermesKanbanReviewedTaskRevision]
    ) async throws -> HermesKanbanTaskDetail {
        guard let parentRevision = Self.reviewedRevision(for: parent.id, in: revisions),
              let childRevision = Self.reviewedRevision(for: child.id, in: revisions),
              try await task(id: parent.id, board: board).revision == parentRevision,
              try await task(id: child.id, board: board).revision == childRevision else {
            throw HermesKanbanError.reviewChanged
        }
        let path = "/api/plugins/kanban/links"
        let value: LoopdyJSONValue?
        if remove {
            value = try await mutationReceipt(.init(
                path: path, method: .delete,
                query: [
                    .init(name: "board", value: board), .init(name: "parent_id", value: parent.id),
                    .init(name: "child_id", value: child.id),
                ], maximumResponseBytes: 64 * 1_024
            ))
        } else {
            value = try await mutationReceipt(.init(
                path: path, method: .post, query: [.init(name: "board", value: board)],
                body: ["parent_id": .string(parent.id), "child_id": .string(child.id)],
                maximumResponseBytes: 64 * 1_024
            ))
        }
        if let value, value.object?["ok"]?.boolean != true {
            throw HermesKanbanError.mutationNotVerified
        }
        let childAfter = try await task(id: child.id, board: board)
        let parentAfter = try await task(id: parent.id, board: board)
        let linked = childAfter.parentIDs.contains(where: { Self.exact($0, parent.id) }) &&
            parentAfter.childIDs.contains(where: { Self.exact($0, child.id) })
        guard linked != remove else { throw HermesKanbanError.mutationNotVerified }
        return childAfter
    }

    private func reassignTask(
        board: String, task original: HermesKanbanTask, profile: String?, reclaimFirst: Bool,
        reason: String?, revision: Data
    ) async throws -> HermesKanbanTaskDetail {
        guard try await task(id: original.id, board: board).revision == revision else {
            throw HermesKanbanError.reviewChanged
        }
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(original.id))/reassign", method: .post,
            query: [.init(name: "board", value: board)],
            body: [
                "profile": profile.map(LoopdyJSONValue.string) ?? .null,
                "reclaim_first": .boolean(reclaimFirst),
                "reason": reason.map(LoopdyJSONValue.string) ?? .null,
            ], maximumResponseBytes: 64 * 1_024
        ))
        if let value,
           !(value.object?["ok"]?.boolean == true &&
             value.object?["task_id"]?.string.map({ Self.exact($0, original.id) }) == true) {
            throw HermesKanbanError.mutationNotVerified
        }
        let after = try await task(id: original.id, board: board)
        guard after.task.assignee == profile,
              !reclaimFirst || after.task.status != .running else { throw HermesKanbanError.mutationNotVerified }
        return after
    }

    private func reclaimTask(
        board: String, task original: HermesKanbanTask, reason: String?, revision: Data
    ) async throws -> HermesKanbanTaskDetail {
        let before = try await task(id: original.id, board: board)
        guard before.revision == revision, let runID = before.task.currentRunID else {
            throw HermesKanbanError.reviewChanged
        }
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(original.id))/reclaim", method: .post,
            query: [.init(name: "board", value: board)],
            body: ["reason": reason.map(LoopdyJSONValue.string) ?? .null], maximumResponseBytes: 64 * 1_024
        ))
        if let value, value.object?["ok"]?.boolean != true {
            throw HermesKanbanError.mutationNotVerified
        }
        let after = try await task(id: original.id, board: board)
        let runAfter = try await run(id: runID, board: board)
        guard after.task.status != .running, !runAfter.isActive else { throw HermesKanbanError.mutationNotVerified }
        return after
    }

    private func runAuxiliary(
        _ kind: HermesKanbanAuxiliaryOutcome.Kind, board: String,
        task original: HermesKanbanTask, revision: Data
    ) async throws -> (HermesKanbanAuxiliaryOutcome, HermesKanbanTaskDetail) {
        let before = try await task(id: original.id, board: board)
        guard before.revision == revision else { throw HermesKanbanError.reviewChanged }
        let suffix = kind == .specify ? "specify" : "decompose"
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(original.id))/\(suffix)", method: .post,
            query: [.init(name: "board", value: board)], body: ["author": .string("loopdy")],
            maximumResponseBytes: 128 * 1_024
        ))
        let after = try await task(id: original.id, board: board)
        let ok: Bool
        let childIDs: [String]
        let resultingTitle: String?
        if let row = value?.object {
            guard let receiptOK = row["ok"]?.boolean,
                  row["task_id"]?.string.map({ Self.exact($0, original.id) }) == true else {
                throw HermesKanbanError.mutationNotVerified
            }
            ok = receiptOK
            childIDs = try row["child_ids"].map { try Self.strings($0, maximum: 100) } ?? []
            resultingTitle = try Self.optionalResponseText(row["new_title"], maximum: 8_192)
        } else {
            guard after.revision != before.revision else { throw HermesKanbanError.mutationNotVerified }
            ok = true
            childIDs = kind == .decompose
                ? after.childIDs.filter { id in !before.childIDs.contains(where: { Self.exact($0, id) }) }
                : []
            resultingTitle = kind == .specify ? after.task.title : nil
        }
        let outcome = HermesKanbanAuxiliaryOutcome(
            kind: kind, succeeded: ok, targetID: original.id,
            reason: ok ? nil : "Hermes could not complete this auxiliary Kanban operation.",
            resultingTitle: resultingTitle, childIDs: childIDs
        )
        guard ok else { throw HermesKanbanError.operationRefused }
        if kind == .specify {
            guard after.revision != before.revision else { throw HermesKanbanError.mutationNotVerified }
        } else {
            guard !childIDs.isEmpty,
                  childIDs.allSatisfy({ id in after.childIDs.contains(where: { Self.exact($0, id) }) }) else {
                throw HermesKanbanError.mutationNotVerified
            }
        }
        return (outcome, after)
    }

    private func setHomeSubscription(
        board: String, task original: HermesKanbanTask, channel: HermesKanbanHomeChannel,
        subscribed: Bool, revision: Data
    ) async throws -> ([HermesKanbanHomeChannel], HermesKanbanTaskDetail) {
        guard try await task(id: original.id, board: board).revision == revision else {
            throw HermesKanbanError.reviewChanged
        }
        let method: DirectHermesHTTPRequest.Method = subscribed ? .post : .delete
        let value = try await mutationReceipt(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(original.id))/home-subscribe/\(Self.component(channel.platform))",
            method: method, query: [.init(name: "board", value: board)], maximumResponseBytes: 64 * 1_024
        ))
        if let value, value.object?["ok"]?.boolean != true {
            throw HermesKanbanError.mutationNotVerified
        }
        let channels = try await homeChannels(taskID: original.id, board: board)
        guard channels.first(where: { Self.exact($0.platform, channel.platform) })?.isSubscribed == subscribed else {
            throw HermesKanbanError.mutationNotVerified
        }
        return (channels, try await task(id: original.id, board: board))
    }

    // MARK: Decoding and revision helpers

    private func mutationReceipt(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue? {
        do {
            return try await mutate(request)
        } catch WorkspaceClientError.outcomeUnknown {
            return nil
        } catch HermesKanbanError.mutationNotVerified {
            return nil
        }
    }

    static func decodeDispatchReceipt(_ value: LoopdyJSONValue) throws -> HermesKanbanDispatchReceipt {
        guard let row = value.object else { throw HermesKanbanError.invalidResponse }
        return .init(
            reclaimed: try requiredAdminInteger(row["reclaimed"], minimum: 0, default: 0),
            promoted: try requiredAdminInteger(row["promoted"], minimum: 0, default: 0),
            spawnedTaskIDs: try firstStrings(row["spawned"], nestedIndex: 0, maximum: 2_000),
            skippedUnassignedTaskIDs: try stringsOrEmpty(row["skipped_unassigned"], maximum: 2_000),
            automaticallyAssignedTaskIDs: try stringsOrEmpty(row["auto_assigned_default"], maximum: 2_000),
            autoBlockedTaskIDs: try stringsOrEmpty(row["auto_blocked"], maximum: 2_000),
            timedOutTaskIDs: try stringsOrEmpty(row["timed_out"], maximum: 2_000),
            staleTaskIDs: try stringsOrEmpty(row["stale"], maximum: 2_000),
            wasLocked: row["skipped_locked"]?.boolean ?? false,
            memoryPressure: try optionalResponseText(row["memory_pressure"], maximum: 80)
        )
    }

    private static func decodeProfile(_ value: LoopdyJSONValue) throws -> HermesKanbanProfile {
        guard let row = value.object,
              let isDefault = row["is_default"]?.boolean,
              let automatic = row["description_auto"]?.boolean,
              let skills = row["skill_count"]?.integer, skills >= 0 else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(
            name: try responseText(row["name"], maximum: 160), isDefault: isDefault,
            model: try optionalResponseText(row["model"], maximum: 512) ?? "",
            provider: try optionalResponseText(row["provider"], maximum: 256) ?? "",
            summary: try optionalResponseText(row["description"], maximum: 16_384) ?? "",
            summaryIsAutomatic: automatic, skillCount: skills
        )
    }

    private static func decodeOrchestration(_ value: LoopdyJSONValue) throws -> HermesKanbanOrchestration {
        guard let row = value.object,
              let decompose = row["auto_decompose"]?.boolean,
              let promote = row["auto_promote_children"]?.boolean else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(
            orchestratorProfile: try optionalResponseText(row["orchestrator_profile"], maximum: 160) ?? "",
            defaultAssignee: try optionalResponseText(row["default_assignee"], maximum: 160) ?? "",
            automaticallyDecomposes: decompose, automaticallyPromotesChildren: promote,
            resolvedOrchestratorProfile: try responseText(row["resolved_orchestrator_profile"], maximum: 160),
            resolvedDefaultAssignee: try responseText(row["resolved_default_assignee"], maximum: 160),
            activeProfile: try responseText(row["active_profile"], maximum: 160)
        )
    }

    private static func decodeEstimate(_ value: LoopdyJSONValue) throws -> HermesKanbanEstimate {
        guard let row = value.object, let ok = row["ok"]?.boolean else { throw HermesKanbanError.invalidResponse }
        if !ok {
            return .init(
                succeeded: false, estimatedTokens: nil, complexity: nil, rationale: nil, model: nil,
                reason: "Hermes could not produce an estimate."
            )
        }
        guard let tokens = row["est_tokens"]?.integer, tokens >= 0 else { throw HermesKanbanError.invalidResponse }
        return .init(
            succeeded: true, estimatedTokens: tokens,
            complexity: row["complexity"]?.string.flatMap(HermesKanbanEstimateComplexity.init(rawValue:)),
            rationale: try optionalResponseText(row["rationale"], maximum: 2_048),
            model: try optionalResponseText(row["model"], maximum: 512), reason: nil
        )
    }

    private func verifiedCatalog(_ revision: Data) async throws -> [HermesKanbanBoard] {
        let catalog = try await boards(includeArchived: true)
        guard try Self.catalogRevision(catalog) == revision else { throw HermesKanbanError.reviewChanged }
        return catalog
    }

    private func verifiedBoard(_ board: HermesKanbanBoard, catalogRevision: Data) async throws
        -> HermesKanbanBoard {
        let catalog = try await verifiedCatalog(catalogRevision)
        guard let current = catalog.first(where: { Self.exact($0.slug, board.slug) }),
              Self.sameBoardMetadata(current, board) else {
            throw HermesKanbanError.reviewChanged
        }
        return current
    }

    private func verifiedProfile(_ profile: HermesKanbanProfile, revision: Data) async throws
        -> HermesKanbanProfile {
        guard let current = try await profiles().first(where: { Self.exact($0.name, profile.name) }),
              try Self.profileRevision(current) == revision, current == profile else {
            throw HermesKanbanError.reviewChanged
        }
        return current
    }

    private static func catalogRevision(_ boards: [HermesKanbanBoard]) throws -> Data {
        try revision(.array(boards.sorted { $0.slug < $1.slug }.map { board in
            .object([
                "slug": .string(board.slug), "name": .string(board.name),
                "description": .string(board.summary), "icon": board.icon.map(LoopdyJSONValue.string) ?? .null,
                "color": board.color.map(LoopdyJSONValue.string) ?? .null,
                "default_workdir": board.defaultWorkdir.map(LoopdyJSONValue.string) ?? .null,
                "project_id": board.projectID.map(LoopdyJSONValue.string) ?? .null,
                "current": .boolean(board.isCurrent), "archived": .boolean(board.isArchived),
            ])
        }))
    }

    private static func orchestrationRevision(_ value: HermesKanbanOrchestration) throws -> Data {
        try revision(.object([
            "orchestrator_profile": .string(value.orchestratorProfile),
            "default_assignee": .string(value.defaultAssignee),
            "auto_decompose": .boolean(value.automaticallyDecomposes),
            "auto_promote_children": .boolean(value.automaticallyPromotesChildren),
            "resolved_orchestrator_profile": .string(value.resolvedOrchestratorProfile),
            "resolved_default_assignee": .string(value.resolvedDefaultAssignee),
            "active_profile": .string(value.activeProfile),
        ]))
    }

    private static func profileRevision(_ value: HermesKanbanProfile) throws -> Data {
        try revision(.object([
            "name": .string(value.name), "description": .string(value.summary),
            "description_auto": .boolean(value.summaryIsAutomatic), "model": .string(value.model),
            "provider": .string(value.provider), "skill_count": .integer(value.skillCount),
        ]))
    }

    private static func revision(_ value: LoopdyJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }

    private static func validated(_ patch: HermesKanbanBoardPatch) throws -> HermesKanbanBoardPatch {
        var patch = patch
        func cleaned(_ update: HermesKanbanFieldUpdate<String>, maximum: Int) throws
            -> HermesKanbanFieldUpdate<String> {
            switch update {
            case .unchanged: return .unchanged
            case .set(let value): return .set(try text(value, maximum: maximum, empty: true))
            }
        }
        patch.name = try cleaned(patch.name, maximum: 240)
        patch.summary = try cleaned(patch.summary, maximum: 16_384)
        patch.icon = try cleaned(patch.icon, maximum: 120)
        patch.color = try cleaned(patch.color, maximum: 120)
        patch.defaultWorkdir = try cleaned(patch.defaultWorkdir, maximum: 4_096)
        patch.projectID = try cleaned(patch.projectID, maximum: 240)
        return patch
    }

    private static func boardPatchBody(_ patch: HermesKanbanBoardPatch) -> [String: LoopdyJSONValue] {
        var body: [String: LoopdyJSONValue] = [:]
        if case .set(let value) = patch.name { body["name"] = .string(value) }
        if case .set(let value) = patch.summary { body["description"] = .string(value) }
        if case .set(let value) = patch.icon { body["icon"] = .string(value) }
        if case .set(let value) = patch.color { body["color"] = .string(value) }
        if case .set(let value) = patch.defaultWorkdir { body["default_workdir"] = .string(value) }
        if case .set(let value) = patch.projectID { body["project_id"] = .string(value) }
        return body
    }

    private static func board(_ board: HermesKanbanBoard, matches draft: HermesKanbanBoardDraft) -> Bool {
        exact(board.slug, draft.slug) && board.name == (draft.name.isEmpty ? draft.slug : draft.name) &&
            board.summary == draft.summary && (board.icon ?? "") == draft.icon &&
            (board.color ?? "") == draft.color &&
            (draft.defaultWorkdir.isEmpty || board.defaultWorkdir == draft.defaultWorkdir) &&
            (draft.projectID.isEmpty || board.projectID == draft.projectID)
    }

    private static func sameBoardMetadata(_ lhs: HermesKanbanBoard, _ rhs: HermesKanbanBoard) -> Bool {
        exact(lhs.slug, rhs.slug) && lhs.name == rhs.name && lhs.summary == rhs.summary &&
            lhs.icon == rhs.icon && lhs.color == rhs.color && lhs.defaultWorkdir == rhs.defaultWorkdir &&
            lhs.projectID == rhs.projectID && lhs.isCurrent == rhs.isCurrent && lhs.isArchived == rhs.isArchived
    }

    private static func verify(_ patch: HermesKanbanBoardPatch, in board: HermesKanbanBoard) -> Bool {
        if case .set(let value) = patch.name, board.name != (value.isEmpty ? board.slug : value) { return false }
        if case .set(let value) = patch.summary, board.summary != value { return false }
        if case .set(let value) = patch.icon, (board.icon ?? "") != value { return false }
        if case .set(let value) = patch.color, (board.color ?? "") != value { return false }
        if case .set(let value) = patch.defaultWorkdir, (board.defaultWorkdir ?? "") != value { return false }
        if case .set(let value) = patch.projectID, (board.projectID ?? "") != value { return false }
        return true
    }

    private static func orchestrationBody(_ patch: HermesKanbanOrchestrationPatch) -> [String: LoopdyJSONValue] {
        var body: [String: LoopdyJSONValue] = [:]
        if case .set(let value) = patch.orchestratorProfile { body["orchestrator_profile"] = .string(value) }
        if case .set(let value) = patch.defaultAssignee { body["default_assignee"] = .string(value) }
        if case .set(let value) = patch.automaticallyDecomposes { body["auto_decompose"] = .boolean(value) }
        if case .set(let value) = patch.automaticallyPromotesChildren { body["auto_promote_children"] = .boolean(value) }
        return body
    }

    private static func verify(_ patch: HermesKanbanOrchestrationPatch, in value: HermesKanbanOrchestration) -> Bool {
        if case .set(let expected) = patch.orchestratorProfile, value.orchestratorProfile != expected { return false }
        if case .set(let expected) = patch.defaultAssignee, value.defaultAssignee != expected { return false }
        if case .set(let expected) = patch.automaticallyDecomposes, value.automaticallyDecomposes != expected { return false }
        if case .set(let expected) = patch.automaticallyPromotesChildren, value.automaticallyPromotesChildren != expected { return false }
        return true
    }

    private static func bulkBody(ids: [String], patch: HermesKanbanBulkPatch) -> [String: LoopdyJSONValue] {
        var body: [String: LoopdyJSONValue] = [
            "ids": .array(ids.map(LoopdyJSONValue.string)),
            "archive": .boolean(patch.archives), "reclaim_first": .boolean(patch.reclaimsFirst),
            "clear_model_override": .boolean(patch.clearsModelOverride),
            "clear_reasoning_effort": .boolean(patch.clearsReasoningEffort),
        ]
        if let status = patch.status { body["status"] = .string(status.rawValue) }
        if patch.changesAssignee { body["assignee"] = .string(patch.assignee ?? "") }
        if let priority = patch.priority { body["priority"] = .integer(priority) }
        if let model = patch.modelOverride { body["model_override"] = .string(model) }
        if let provider = patch.providerOverride { body["provider_override"] = .string(provider) }
        if let effort = patch.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        return body
    }

    private static func verify(_ patch: HermesKanbanBulkPatch, in task: HermesKanbanTask) -> Bool {
        if patch.archives, task.status != .archived { return false }
        if let status = patch.status, !patch.archives, task.status != status { return false }
        if patch.changesAssignee, task.assignee != patch.assignee { return false }
        if let priority = patch.priority, task.priority != priority { return false }
        if patch.clearsModelOverride, task.modelOverride != nil { return false }
        if let model = patch.modelOverride, task.modelOverride != model { return false }
        if let provider = patch.providerOverride, task.providerOverride != provider { return false }
        if patch.clearsReasoningEffort, task.reasoningEffort != nil { return false }
        if let effort = patch.reasoningEffort, task.reasoningEffort != effort { return false }
        return true
    }

    private static func reviewedRevision(
        for taskID: String, in revisions: [HermesKanbanReviewedTaskRevision]
    ) -> Data? {
        revisions.first(where: { exact($0.taskID, taskID) })?.revision
    }

    private static func boardSlug(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bytes = Array(value.utf8)
        let isAlphaNumeric: (UInt8) -> Bool = { byte in
            (48...57).contains(byte) || (97...122).contains(byte)
        }
        guard (1...64).contains(bytes.count), bytes.first.map(isAlphaNumeric) == true,
              bytes.allSatisfy({ isAlphaNumeric($0) || $0 == 45 || $0 == 95 }) else {
            throw HermesKanbanError.invalidRequest
        }
        return value
    }

    private static func integerMap(_ value: LoopdyJSONValue?) throws -> [String: Int] {
        guard let object = value?.object, object.count <= 128 else { throw HermesKanbanError.invalidResponse }
        var result: [String: Int] = [:]
        for (key, value) in object {
            guard key.utf8.count <= 120, let integer = value.integer, integer >= 0 else {
                throw HermesKanbanError.invalidResponse
            }
            result[key] = integer
        }
        return result
    }

    private static func optionalAdminInteger(_ value: LoopdyJSONValue?, minimum: Int) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let integer = value.integer, integer >= minimum else { throw HermesKanbanError.invalidResponse }
        return integer
    }

    private static func requiredAdminInteger(
        _ value: LoopdyJSONValue?, minimum: Int, default defaultValue: Int
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard let integer = value.integer, integer >= minimum else { throw HermesKanbanError.invalidResponse }
        return integer
    }

    private static func adminDate(_ value: LoopdyJSONValue?) throws -> Date {
        guard let seconds = value?.number, seconds.isFinite else { throw HermesKanbanError.invalidResponse }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func optionalAdminDate(_ value: LoopdyJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        return try adminDate(value)
    }

    private static func stringsOrEmpty(_ value: LoopdyJSONValue?, maximum: Int) throws -> [String] {
        guard value != nil else { return [] }
        return try strings(value, maximum: maximum)
    }

    private static func firstStrings(
        _ value: LoopdyJSONValue?, nestedIndex: Int, maximum: Int
    ) throws -> [String] {
        guard let rows = value?.array else { return [] }
        guard rows.count <= maximum else { throw HermesKanbanError.invalidResponse }
        return try rows.map { row in
            guard let values = row.array, values.indices.contains(nestedIndex) else {
                throw HermesKanbanError.invalidResponse
            }
            return try responseText(values[nestedIndex], maximum: 240)
        }
    }
}
