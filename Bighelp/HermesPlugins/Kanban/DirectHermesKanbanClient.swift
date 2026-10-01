import CryptoKit
import Foundation

/// Fixed native client for the public bundled Kanban dashboard mount. It has no
/// dependency on Bot Mode and never accepts caller-selected methods or paths.
@MainActor
final class DirectHermesKanbanClient {
    nonisolated static let maximumResponseBytes = 4 * 1_024 * 1_024
    nonisolated static let maximumAttachmentBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumTextBytes = 256 * 1_024
    nonisolated static let defaultPollingIntervalNanoseconds: UInt64 = 2_000_000_000

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let eventTransport: (any DirectHermesKanbanEventTransport)?
    private let attachmentTransport: (any DirectHermesKanbanAttachmentTransport)?
    private(set) var mount: HermesKanbanMount = .unknown

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        eventTransport: (any DirectHermesKanbanEventTransport)? = nil,
        attachmentTransport: (any DirectHermesKanbanAttachmentTransport)? = nil
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
        self.eventTransport = eventTransport
        self.attachmentTransport = attachmentTransport ?? (http as? any DirectHermesKanbanAttachmentTransport)
    }

    var ownsScope: Bool { currentOwner() == owner }
    var supportsSeparateEventStream: Bool { eventTransport != nil }
    var supportsAttachmentTransfer: Bool { attachmentTransport != nil }

    /// Route discovery is an authenticated read against the actual mount. Plugin
    /// catalog/install state is intentionally not treated as mount proof.
    @discardableResult
    func discoverMount() async throws -> HermesKanbanMount {
        try requireOwner()
        let request = DirectHermesHTTPRequest(
            path: "/api/plugins/kanban/boards",
            method: .get,
            query: [.init(name: "include_archived", value: "false")],
            maximumResponseBytes: Self.maximumResponseBytes
        )
        do {
            let value: BighelpJSONValue
            if let native = http as? any DirectHermesNativeHTTP {
                let response = try await native.nativeResponse(request, requestGuard: nil)
                try requireOwner()
                switch response.http.statusCode {
                case 200...299:
                    value = try response.value()
                case 404, 405:
                    mount = .unavailable
                    return mount
                case 401, 403:
                    throw WorkspaceClientError.authenticationRequired
                case 413:
                    throw HermesKanbanError.capacityExceeded
                default:
                    try DirectHermesHTTP.requireSuccess(response)
                    value = try response.value()
                }
            } else {
                value = try await http.request(request)
            }
            _ = try Self.decodeBoards(value)
            try requireOwner()
            mount = .available
            return mount
        } catch DirectHermesError.unsupportedAuthentication {
            try requireOwner()
            mount = .unavailable
            return mount
        } catch WorkspaceClientError.unavailable(_) {
            try requireOwner()
            mount = .unavailable
            return mount
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: false)
        }
    }

    func boards(includeArchived: Bool = false) async throws -> [HermesKanbanBoard] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/kanban/boards", method: .get,
            query: [.init(name: "include_archived", value: includeArchived ? "true" : "false")],
            maximumResponseBytes: Self.maximumResponseBytes
        ))
        return try Self.decodeBoards(value).boards
    }

    func board(
        slug: String,
        includeArchived: Bool = false,
        workflowTemplateID: String? = nil,
        currentStepKey: String? = nil
    ) async throws -> HermesKanbanBoardSnapshot {
        try await requireMount()
        let slug = try Self.identifier(slug, maximum: 120)
        var boardQuery = [
            URLQueryItem(name: "board", value: slug),
            URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false"),
        ]
        if let workflowTemplateID {
            boardQuery.append(.init(
                name: "workflow_template_id",
                value: try Self.identifier(workflowTemplateID, maximum: 240)
            ))
        }
        if let currentStepKey {
            boardQuery.append(.init(
                name: "current_step_key",
                value: try Self.identifier(currentStepKey, maximum: 240)
            ))
        }
        async let boardValue = request(.init(
            path: "/api/plugins/kanban/board", method: .get,
            query: boardQuery, maximumResponseBytes: Self.maximumResponseBytes
        ))
        async let boardsValue = request(.init(
            path: "/api/plugins/kanban/boards", method: .get,
            query: [.init(name: "include_archived", value: includeArchived ? "true" : "false")],
            maximumResponseBytes: Self.maximumResponseBytes
        ))
        let payload = try await boardValue
        let boardCatalog = try Self.decodeBoards(await boardsValue).boards
        guard let metadata = boardCatalog.first(where: { Self.exact($0.slug, slug) }) else {
            throw HermesKanbanError.invalidResponse
        }
        return try Self.decodeBoard(payload, metadata: metadata)
    }

    func task(id: String, board slug: String) async throws -> HermesKanbanTaskDetail {
        try await requireMount()
        let id = try Self.identifier(id, maximum: 240)
        let slug = try Self.identifier(slug, maximum: 120)
        let value = try await request(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(id))", method: .get,
            query: [.init(name: "board", value: slug)], maximumResponseBytes: Self.maximumResponseBytes
        ))
        return try Self.decodeDetail(value, expectedTaskID: id)
    }

    func prepareCreation(_ draft: HermesKanbanTaskDraft, board slug: String) async throws
        -> HermesKanbanTaskCreationReview {
        var prepared = draft
        if prepared.idempotencyKey == nil { prepared.idempotencyKey = UUID().uuidString }
        let validated = try Self.validated(prepared)
        let current = try await board(slug: slug)
        return .init(
            boardSlug: current.board.slug,
            boardRevision: try Self.boardRevision(current),
            draft: validated
        )
    }

    func create(approved review: HermesKanbanTaskCreationReview) async throws -> HermesKanbanTaskDetail {
        let before = try await board(slug: review.boardSlug)
        guard try Self.boardRevision(before) == review.boardRevision else {
            throw HermesKanbanError.reviewChanged
        }
        let draft = try Self.validated(review.draft)
        var body: [String: BighelpJSONValue] = [
            "title": .string(draft.title),
            "body": .string(draft.body),
            "priority": .integer(draft.priority),
            "parents": .array(draft.parentIDs.map(BighelpJSONValue.string)),
            "triage": .boolean(draft.startsInTriage),
            "goal_mode": .boolean(draft.goalMode),
        ]
        Self.put(draft.assignee, key: "assignee", into: &body)
        Self.put(draft.tenant, key: "tenant", into: &body)
        Self.put(draft.workspaceKind, key: "workspace_kind", into: &body)
        Self.put(draft.workspacePath, key: "workspace_path", into: &body)
        Self.put(draft.idempotencyKey, key: "idempotency_key", into: &body)
        Self.put(draft.maximumRuntimeSeconds, key: "max_runtime_seconds", into: &body)
        if let skills = draft.skills { body["skills"] = .array(skills.map(BighelpJSONValue.string)) }
        Self.put(draft.goalMaximumTurns, key: "goal_max_turns", into: &body)
        Self.put(draft.modelOverride, key: "model_override", into: &body)
        Self.put(draft.providerOverride, key: "provider_override", into: &body)
        Self.put(draft.reasoningEffort, key: "reasoning_effort", into: &body)
        Self.put(draft.projectID, key: "project_id", into: &body)

        let created: HermesKanbanTask
        do {
            let receipt = try await mutate(.init(
                path: "/api/plugins/kanban/tasks", method: .post,
                query: [.init(name: "board", value: review.boardSlug)], body: body,
                maximumResponseBytes: 512 * 1_024
            ))
            guard let row = receipt.object, let taskValue = row["task"],
                  let decoded = try? Self.decodeTask(taskValue) else {
                throw HermesKanbanError.mutationNotVerified
            }
            created = decoded
        } catch WorkspaceClientError.outcomeUnknown, HermesKanbanError.mutationNotVerified {
            guard let key = draft.idempotencyKey else { throw HermesKanbanError.mutationNotVerified }
            let readback = try await board(slug: review.boardSlug)
            let matches = readback.tasks.filter { $0.idempotencyKey.map({ Self.exact($0, key) }) == true }
            guard matches.count == 1, let only = matches.first else {
                throw HermesKanbanError.mutationNotVerified
            }
            created = only
        }
        let readback = try await task(id: created.id, board: review.boardSlug)
        guard Self.exact(readback.task.title, draft.title),
              readback.task.body == draft.body,
              readback.task.assignee == draft.assignee,
              readback.task.priority == draft.priority,
              readback.task.idempotencyKey == draft.idempotencyKey else {
            throw HermesKanbanError.mutationNotVerified
        }
        return readback
    }

    func prepareEdit(
        taskID: String,
        board slug: String,
        patch: HermesKanbanTaskPatch
    ) async throws -> HermesKanbanTaskEditReview {
        let patch = try Self.validated(patch)
        guard !patch.isEmpty else { throw HermesKanbanError.invalidRequest }
        let detail = try await task(id: taskID, board: slug)
        return .init(
            boardSlug: try Self.identifier(slug, maximum: 120), task: detail.task,
            patch: patch, revision: detail.revision, preparedAt: Date()
        )
    }

    func edit(approved review: HermesKanbanTaskEditReview) async throws -> HermesKanbanTaskDetail {
        let current = try await task(id: review.task.id, board: review.boardSlug)
        guard current.revision == review.revision else { throw HermesKanbanError.reviewChanged }
        let patch = try Self.validated(review.patch)
        let body = try Self.patchBody(patch)
        do {
            _ = try await mutate(.init(
                path: "/api/plugins/kanban/tasks/\(Self.component(review.task.id))", method: .patch,
                query: [.init(name: "board", value: review.boardSlug)], body: body,
                maximumResponseBytes: 512 * 1_024
            ))
        } catch WorkspaceClientError.outcomeUnknown, HermesKanbanError.mutationNotVerified {
            // Do not replay. The same verified readback below resolves a write that
            // reached Hermes before transport failed.
        }
        let readback = try await task(id: review.task.id, board: review.boardSlug)
        try Self.verify(patch, in: readback.task)
        guard readback.revision != current.revision else { throw HermesKanbanError.mutationNotVerified }
        return readback
    }

    func prepareComment(_ body: String, taskID: String, board slug: String) async throws
        -> HermesKanbanCommentReview {
        let before = try await task(id: taskID, board: slug)
        let body = try Self.text(body, maximum: Self.maximumTextBytes)
        return .init(boardSlug: slug, task: before.task, body: body, revision: before.revision)
    }

    func addComment(approved review: HermesKanbanCommentReview, author: String = "loopdy") async throws
        -> HermesKanbanTaskDetail {
        let before = try await task(id: review.task.id, board: review.boardSlug)
        guard before.revision == review.revision else { throw HermesKanbanError.reviewChanged }
        let body = try Self.text(review.body, maximum: Self.maximumTextBytes)
        let author = try Self.text(author, maximum: 160)
        do {
            let value = try await mutate(.init(
                path: "/api/plugins/kanban/tasks/\(Self.component(before.task.id))/comments", method: .post,
                query: [.init(name: "board", value: review.boardSlug)],
                body: ["body": .string(body), "author": .string(author)], maximumResponseBytes: 64 * 1_024
            ))
            guard value.object?["ok"]?.boolean == true else { throw HermesKanbanError.mutationNotVerified }
        } catch WorkspaceClientError.outcomeUnknown, HermesKanbanError.mutationNotVerified {
            // Reconcile below without replaying the comment.
        }
        let after = try await task(id: review.task.id, board: review.boardSlug)
        guard after.comments.count == before.comments.count + 1,
              after.comments.last.map({ Self.exact($0.body, body) && Self.exact($0.author, author) }) == true else {
            throw HermesKanbanError.mutationNotVerified
        }
        return after
    }

    func attachments(taskID: String, board slug: String) async throws -> [HermesKanbanAttachment] {
        try await requireMount()
        let taskID = try Self.identifier(taskID, maximum: 240)
        let slug = try Self.identifier(slug, maximum: 120)
        let value = try await request(.init(
            path: "/api/plugins/kanban/tasks/\(Self.component(taskID))/attachments", method: .get,
            query: [.init(name: "board", value: slug)], maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        guard let rows = value.object?["attachments"]?.array, rows.count <= 256 else {
            throw HermesKanbanError.invalidResponse
        }
        let decoded = try rows.map(Self.decodeAttachment)
        guard Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ Self.exact($0.taskID, taskID) }) else {
            throw HermesKanbanError.invalidResponse
        }
        return decoded
    }

    func prepareAttachmentRemoval(
        attachmentID: Int,
        taskID: String,
        board slug: String
    ) async throws -> HermesKanbanAttachmentRemovalReview {
        guard attachmentID > 0 else { throw HermesKanbanError.invalidRequest }
        let detail = try await task(id: taskID, board: slug)
        guard let attachment = detail.attachments.first(where: { $0.id == attachmentID }) else {
            throw HermesKanbanError.invalidRequest
        }
        return .init(
            boardSlug: slug, taskID: detail.task.id, attachment: attachment,
            taskRevision: detail.revision
        )
    }

    func removeAttachment(approved review: HermesKanbanAttachmentRemovalReview) async throws {
        let current = try await task(id: review.taskID, board: review.boardSlug)
        guard current.revision == review.taskRevision,
              current.attachments.contains(review.attachment) else {
            throw HermesKanbanError.reviewChanged
        }
        do {
            let value = try await mutate(.init(
                path: "/api/plugins/kanban/attachments/\(review.attachment.id)", method: .delete,
                query: [.init(name: "board", value: review.boardSlug)], maximumResponseBytes: 64 * 1_024
            ))
            guard value.object?["ok"]?.boolean == true,
                  value.object?["id"]?.integer == review.attachment.id else {
                throw HermesKanbanError.mutationNotVerified
            }
        } catch WorkspaceClientError.outcomeUnknown, HermesKanbanError.mutationNotVerified {
            // Absence in the authoritative list below can resolve the outcome.
        }
        guard try await attachments(taskID: review.taskID, board: review.boardSlug)
            .allSatisfy({ $0.id != review.attachment.id }) else {
            throw HermesKanbanError.mutationNotVerified
        }
    }

    func uploadAttachment(
        bytes: Data,
        filename: String,
        contentType: String,
        taskID: String,
        board slug: String
    ) async throws -> HermesKanbanAttachment {
        try await requireMount()
        guard let attachmentTransport else { throw HermesKanbanError.attachmentTransportRequired }
        guard !bytes.isEmpty, bytes.count <= Self.maximumAttachmentBytes else {
            throw HermesKanbanError.capacityExceeded
        }
        let filename = try Self.filename(filename)
        let contentType = try Self.contentType(contentType)
        let taskID = try Self.identifier(taskID, maximum: 240)
        let slug = try Self.identifier(slug, maximum: 120)
        _ = try await task(id: taskID, board: slug)
        let receipt = try await attachmentTransport.uploadKanbanAttachment(
            board: slug, taskID: taskID, filename: filename, contentType: contentType,
            bytes: bytes, uploadedBy: "loopdy", maximumResponseBytes: 128 * 1_024
        )
        try requireOwner()
        guard let value = receipt.object?["attachment"],
              let decoded = try? Self.decodeAttachment(value), decoded.byteCount == bytes.count,
              Self.exact(decoded.taskID, taskID) else {
            throw HermesKanbanError.mutationNotVerified
        }
        let readback = try await attachments(taskID: taskID, board: slug)
        guard let confirmed = readback.first(where: { $0.id == decoded.id }), confirmed == decoded else {
            throw HermesKanbanError.mutationNotVerified
        }
        return confirmed
    }

    func downloadAttachment(_ attachment: HermesKanbanAttachment, board slug: String) async throws
        -> HermesKanbanAttachmentDownload {
        try await requireMount()
        guard let attachmentTransport else { throw HermesKanbanError.attachmentTransportRequired }
        guard attachment.byteCount <= Self.maximumAttachmentBytes else { throw HermesKanbanError.capacityExceeded }
        let slug = try Self.identifier(slug, maximum: 120)
        let response = try await attachmentTransport.downloadKanbanAttachment(
            board: slug, attachmentID: attachment.id, maximumBytes: Self.maximumAttachmentBytes
        )
        try requireOwner()
        guard response.statusCode == 200, response.bytes.count == attachment.byteCount,
              response.bytes.count <= Self.maximumAttachmentBytes else {
            throw HermesKanbanError.invalidResponse
        }
        let type = response.contentType ?? attachment.contentType ?? "application/octet-stream"
        guard attachment.contentType == nil || response.contentType == nil || attachment.contentType == response.contentType else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(attachment: attachment, bytes: response.bytes, contentType: type)
    }

    func run(id: Int, board slug: String) async throws -> HermesKanbanRun {
        try await requireMount()
        guard id > 0 else { throw HermesKanbanError.invalidRequest }
        let slug = try Self.identifier(slug, maximum: 120)
        let value = try await request(.init(
            path: "/api/plugins/kanban/runs/\(id)", method: .get,
            query: [.init(name: "board", value: slug)], maximumResponseBytes: 256 * 1_024
        ))
        guard let row = value.object?["run"] else { throw HermesKanbanError.invalidResponse }
        let run = try Self.decodeRun(row)
        guard run.id == id else { throw HermesKanbanError.invalidResponse }
        return run
    }

    func inspectRun(id: Int, board slug: String) async throws -> HermesKanbanRunInspection {
        try await requireMount()
        guard id > 0 else { throw HermesKanbanError.invalidRequest }
        let value = try await request(.init(
            path: "/api/plugins/kanban/runs/\(id)/inspect", method: .get,
            query: [.init(name: "board", value: try Self.identifier(slug, maximum: 120))],
            maximumResponseBytes: 128 * 1_024
        ))
        return try Self.decodeInspection(value, expectedRunID: id)
    }

    func prepareRunTermination(id: Int, board slug: String, reason: String?) async throws
        -> HermesKanbanRunTerminationReview {
        let current = try await run(id: id, board: slug)
        guard current.isActive else { throw HermesKanbanError.invalidRequest }
        let taskDetail = try await task(id: current.taskID, board: slug)
        guard taskDetail.runs.contains(current) else { throw HermesKanbanError.reviewChanged }
        let reason = try reason.map { try Self.text($0, maximum: 2_048, empty: true) }
        return .init(
            boardSlug: try Self.identifier(slug, maximum: 120), run: current,
            revision: try Self.runRevision(current), taskRevision: taskDetail.revision,
            reason: reason
        )
    }

    func terminateRun(approved review: HermesKanbanRunTerminationReview) async throws -> HermesKanbanRun {
        let current = try await run(id: review.run.id, board: review.boardSlug)
        let currentTask = try await task(id: review.run.taskID, board: review.boardSlug)
        guard current.isActive, try Self.runRevision(current) == review.revision,
              currentTask.revision == review.taskRevision else {
            throw HermesKanbanError.reviewChanged
        }
        do {
            let value = try await mutate(.init(
                path: "/api/plugins/kanban/runs/\(review.run.id)/terminate", method: .post,
                query: [.init(name: "board", value: review.boardSlug)],
                body: ["reason": review.reason.map(BighelpJSONValue.string) ?? .null],
                maximumResponseBytes: 64 * 1_024
            ))
            guard value.object?["ok"]?.boolean == true,
                  value.object?["run_id"]?.integer == review.run.id,
                  value.object?["task_id"]?.string.map({ Self.exact($0, review.run.taskID) }) == true else {
                throw HermesKanbanError.mutationNotVerified
            }
        } catch WorkspaceClientError.outcomeUnknown, HermesKanbanError.mutationNotVerified {
            // Do not send another termination. Reconcile run + task below.
        }
        let readback = try await run(id: review.run.id, board: review.boardSlug)
        let taskReadback = try await task(id: review.run.taskID, board: review.boardSlug)
        guard !readback.isActive, taskReadback.task.status != .running else {
            throw HermesKanbanError.mutationNotVerified
        }
        return readback
    }

    func prepareDispatcherNudge(board slug: String, maximum: Int = 8) async throws -> HermesKanbanDispatchReview {
        guard (1...32).contains(maximum) else { throw HermesKanbanError.invalidRequest }
        let before = try await board(slug: slug)
        return .init(
            boardSlug: before.board.slug,
            maximum: maximum,
            boardRevision: try Self.boardRevision(before),
            readyCount: before.columns.first(where: { $0.status == .ready })?.tasks.count ?? 0
        )
    }

    func nudgeDispatcher(approved review: HermesKanbanDispatchReview) async throws -> HermesKanbanDispatchResult {
        try await requireMount()
        guard (1...32).contains(review.maximum) else { throw HermesKanbanError.invalidRequest }
        let slug = try Self.identifier(review.boardSlug, maximum: 120)
        let before = try await board(slug: slug)
        guard try Self.boardRevision(before) == review.boardRevision else {
            throw HermesKanbanError.reviewChanged
        }
        let receiptValue = try await mutate(.init(
            path: "/api/plugins/kanban/dispatch", method: .post,
            query: [
                .init(name: "board", value: slug),
                .init(name: "dry_run", value: "false"),
                .init(name: "max", value: String(review.maximum)),
            ], maximumResponseBytes: 256 * 1_024
        ))
        let receipt = try Self.decodeDispatchReceipt(receiptValue)
        let after = try await board(slug: slug)
        guard after.latestEventID >= before.latestEventID else { throw HermesKanbanError.mutationNotVerified }
        return .init(receipt: receipt, board: after)
    }

    /// Uses the public plugin WebSocket only when a parent supplies its fixed
    /// authenticated transport. Otherwise it polls the board's monotonic event ID
    /// for a bounded number of iterations and then finishes with an explicit limit.
    func liveUpdates(
        board slug: String,
        since cursor: Int,
        maximumPolls: Int = 90,
        pollingIntervalNanoseconds: UInt64 = defaultPollingIntervalNanoseconds
    ) throws -> AsyncThrowingStream<HermesKanbanLiveUpdate, any Error> {
        guard ownsScope, cursor >= 0, (1...300).contains(maximumPolls),
              pollingIntervalNanoseconds >= 500_000_000 else {
            throw HermesKanbanError.invalidRequest
        }
        let slug = try Self.identifier(slug, maximum: 120)
        if let eventTransport {
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task { @MainActor [weak self] in
                    do {
                        var accepted = cursor
                        for try await batch in eventTransport.eventBatches(board: slug, since: cursor) {
                            guard let self else { throw CancellationError() }
                            try self.requireOwner()
                            guard batch.cursor >= accepted,
                                  batch.events.allSatisfy({ $0.id > accepted && $0.id <= batch.cursor }) else {
                                throw HermesKanbanError.invalidResponse
                            }
                            accepted = batch.cursor
                            continuation.yield(.events(batch))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    guard let self else { throw CancellationError() }
                    var accepted = cursor
                    for _ in 0..<maximumPolls {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
                        let snapshot = try await self.board(slug: slug)
                        if snapshot.latestEventID > accepted {
                            accepted = snapshot.latestEventID
                            continuation.yield(.snapshot(snapshot))
                        }
                    }
                    continuation.finish(throwing: HermesKanbanError.pollingLimitReached)
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request boundary

    func requireMount() async throws {
        try requireOwner()
        if mount == .unknown { _ = try await discoverMount() }
        guard mount == .available else { throw HermesKanbanError.unavailable }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw HermesKanbanError.staleOwner }
        _ = rpc // Retain the same production RPC/HTTP lifetime as sibling Direct clients.
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try requireOwner()
        do {
            let value = try await http.request(request)
            try requireOwner()
            guard try JSONEncoder().encode(value).count <= request.maximumResponseBytes else {
                throw HermesKanbanError.capacityExceeded
            }
            return value
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: false)
        }
    }

    func mutate(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        if let body = request.body,
           try JSONEncoder().encode(BighelpJSONValue.object(body)).count > 512 * 1_024 {
            throw HermesKanbanError.capacityExceeded
        }
        try requireOwner()
        do {
            let value = try await http.request(request)
            try requireOwner()
            return value
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: true)
        }
    }

    private static func safe(_ error: any Error, mutation: Bool) -> any Error {
        if error is CancellationError || error is HermesKanbanError || error is WorkspaceClientError { return error }
        guard let direct = error as? DirectHermesError else {
            return mutation ? HermesKanbanError.mutationNotVerified : WorkspaceClientError.transportUnavailable
        }
        if direct.outcomeIsUnknown { return HermesKanbanError.mutationNotVerified }
        switch direct {
        case .invalidCredentials, .authenticationRequired: return WorkspaceClientError.authenticationRequired
        case .unsupportedAuthentication: return HermesKanbanError.unavailable
        case .invalidResponse: return HermesKanbanError.invalidResponse
        case .messageTooLarge, .tooManyRequests: return HermesKanbanError.capacityExceeded
        default: return WorkspaceClientError.transportUnavailable
        }
    }

    // MARK: - Decoding and revision projection

    private typealias Object = [String: BighelpJSONValue]

    private static func decodeBoards(_ value: BighelpJSONValue) throws
        -> (boards: [HermesKanbanBoard], current: String) {
        guard let object = value.object, let rows = object["boards"]?.array,
              rows.count <= 256, let current = object["current"]?.string else {
            throw HermesKanbanError.invalidResponse
        }
        let boards = try rows.map { value -> HermesKanbanBoard in
            guard let row = value.object else { throw HermesKanbanError.invalidResponse }
            let slug = try responseText(row["slug"], maximum: 120)
            let countsObject = row["counts"]?.object ?? [:]
            var counts: [String: Int] = [:]
            for (key, value) in countsObject {
                guard HermesKanbanTaskStatus(rawValue: key) != nil,
                      let count = value.integer, count >= 0 else { throw HermesKanbanError.invalidResponse }
                counts[key] = count
            }
            let total = row["total"]?.integer ?? counts.filter { $0.key != "archived" }.map(\.value).reduce(0, +)
            guard total >= 0 else { throw HermesKanbanError.invalidResponse }
            return .init(
                slug: slug,
                name: try optionalResponseText(row["name"], maximum: 240) ?? slug,
                summary: try optionalResponseText(row["description"], maximum: 16_384) ?? "",
                icon: try optionalResponseText(row["icon"], maximum: 120),
                color: try optionalResponseText(row["color"], maximum: 120),
                defaultWorkdir: try optionalResponseText(row["default_workdir"], maximum: 4_096),
                projectID: try optionalResponseText(row["project_id"], maximum: 240),
                projectName: try optionalResponseText(row["project_name"], maximum: 240),
                isCurrent: row["is_current"]?.boolean ?? Self.exact(slug, current),
                isArchived: row["archived"]?.boolean ?? false,
                total: total, counts: counts
            )
        }
        guard Set(boards.map { Data($0.slug.utf8) }).count == boards.count else { throw HermesKanbanError.invalidResponse }
        return (boards, current)
    }

    private static func decodeBoard(_ value: BighelpJSONValue, metadata: HermesKanbanBoard) throws
        -> HermesKanbanBoardSnapshot {
        guard let object = value.object, let columnRows = object["columns"]?.array,
              columnRows.count <= HermesKanbanTaskStatus.allCases.count,
              let latest = object["latest_event_id"]?.integer, latest >= 0,
              let now = object["now"]?.integer else { throw HermesKanbanError.invalidResponse }
        let columns = try columnRows.map { value -> HermesKanbanColumn in
            guard let row = value.object,
                  let raw = row["name"]?.string,
                  let status = HermesKanbanTaskStatus(rawValue: raw),
                  let taskRows = row["tasks"]?.array, taskRows.count <= 2_000 else {
                throw HermesKanbanError.invalidResponse
            }
            let tasks = try taskRows.map(Self.decodeTask)
            guard Set(tasks.map { Data($0.id.utf8) }).count == tasks.count,
                  tasks.allSatisfy({ $0.status == status }) else {
                throw HermesKanbanError.invalidResponse
            }
            return .init(status: status, tasks: tasks)
        }
        guard Set(columns.map(\.status)).count == columns.count else { throw HermesKanbanError.invalidResponse }
        let allIDs = columns.flatMap(\.tasks).map(\.id)
        guard Set(allIDs.map { Data($0.utf8) }).count == allIDs.count else { throw HermesKanbanError.invalidResponse }
        return .init(
            board: metadata, columns: columns,
            tenants: try strings(object["tenants"], maximum: 512),
            assignees: try strings(object["assignees"], maximum: 512),
            latestEventID: latest, fetchedAt: Date(timeIntervalSince1970: TimeInterval(now))
        )
    }

    private static func decodeDetail(_ value: BighelpJSONValue, expectedTaskID: String) throws
        -> HermesKanbanTaskDetail {
        guard let object = value.object, let taskValue = object["task"],
              let commentRows = object["comments"]?.array, commentRows.count <= 5_000,
              let eventRows = object["events"]?.array, eventRows.count <= 20_000,
              let attachmentRows = object["attachments"]?.array, attachmentRows.count <= 256,
              let links = object["links"]?.object,
              let runRows = object["runs"]?.array, runRows.count <= 2_000 else {
            throw HermesKanbanError.invalidResponse
        }
        let task = try decodeTask(taskValue)
        guard exact(task.id, expectedTaskID) else { throw HermesKanbanError.invalidResponse }
        let comments = try commentRows.map { value -> HermesKanbanComment in
            guard let row = value.object, let id = row["id"]?.integer, id > 0 else {
                throw HermesKanbanError.invalidResponse
            }
            return .init(
                id: id, author: try responseText(row["author"], maximum: 160),
                body: try responseText(row["body"], maximum: maximumTextBytes, empty: true),
                createdAt: try date(row["created_at"])
            )
        }
        let events = try eventRows.map(decodeEvent)
        let attachments = try attachmentRows.map(decodeAttachment)
        let runs = try runRows.map(decodeRun)
        guard Set(comments.map(\.id)).count == comments.count,
              Set(events.map(\.id)).count == events.count,
              Set(attachments.map(\.id)).count == attachments.count,
              Set(runs.map(\.id)).count == runs.count,
              events.allSatisfy({ exact($0.taskID, task.id) }),
              attachments.allSatisfy({ exact($0.taskID, task.id) }),
              runs.allSatisfy({ exact($0.taskID, task.id) }) else {
            throw HermesKanbanError.invalidResponse
        }
        let parents = try strings(links["parents"], maximum: 2_000)
        let children = try strings(links["children"], maximum: 2_000)
        let revision = try canonicalRevision(task: task, comments: comments, events: events, attachments: attachments, runs: runs)
        return .init(
            task: task, comments: comments, events: events, attachments: attachments,
            parentIDs: parents, childIDs: children, runs: runs, revision: revision
        )
    }

    static func decodeTask(_ value: BighelpJSONValue) throws -> HermesKanbanTask {
        guard let row = value.object,
              let statusRaw = row["status"]?.string,
              let status = HermesKanbanTaskStatus(rawValue: statusRaw),
              let priority = row["priority"]?.integer else { throw HermesKanbanError.invalidResponse }
        let links = row["link_counts"]?.object
        return .init(
            id: try responseText(row["id"], maximum: 240),
            title: try responseText(row["title"], maximum: 8_192),
            body: try optionalResponseText(row["body"], maximum: maximumTextBytes),
            assignee: try optionalResponseText(row["assignee"], maximum: 160),
            status: status, priority: priority,
            createdBy: try optionalResponseText(row["created_by"], maximum: 160),
            createdAt: try date(row["created_at"]),
            startedAt: try optionalDate(row["started_at"]),
            completedAt: try optionalDate(row["completed_at"]),
            tenant: try optionalResponseText(row["tenant"], maximum: 240),
            workspaceKind: try optionalResponseText(row["workspace_kind"], maximum: 80) ?? "scratch",
            workspacePath: try optionalResponseText(row["workspace_path"], maximum: 4_096),
            branchName: try optionalResponseText(row["branch_name"], maximum: 1_024),
            projectID: try optionalResponseText(row["project_id"], maximum: 240),
            result: try optionalResponseText(row["result"], maximum: maximumTextBytes),
            idempotencyKey: try optionalResponseText(row["idempotency_key"], maximum: 240),
            latestSummary: try optionalResponseText(row["latest_summary"], maximum: maximumTextBytes),
            currentRunID: try optionalInteger(row["current_run_id"], minimum: 1),
            workerPID: try optionalInteger(row["worker_pid"], minimum: 1),
            lastHeartbeatAt: try optionalDate(row["last_heartbeat_at"]),
            maxRuntimeSeconds: try optionalInteger(row["max_runtime_seconds"], minimum: 1),
            modelOverride: try optionalResponseText(row["model_override"], maximum: 512),
            providerOverride: try optionalResponseText(row["provider_override"], maximum: 256),
            reasoningEffort: try optionalResponseText(row["reasoning_effort"], maximum: 80),
            workflowTemplateID: try optionalResponseText(row["workflow_template_id"], maximum: 240),
            currentStepKey: try optionalResponseText(row["current_step_key"], maximum: 240),
            skills: row["skills"] == nil || row["skills"] == .null ? nil : try strings(row["skills"], maximum: 256),
            maximumRetries: try optionalInteger(row["max_retries"], minimum: 0),
            consecutiveFailures: try requiredInteger(row["consecutive_failures"], minimum: 0, default: 0),
            goalMode: row["goal_mode"]?.boolean ?? false,
            goalMaximumTurns: try optionalInteger(row["goal_max_turns"], minimum: 1),
            completionContract: try optionalResponseText(row["completion_contract"], maximum: maximumTextBytes),
            blockKind: try optionalResponseText(row["block_kind"], maximum: 120),
            blockRecurrences: try requiredInteger(row["block_recurrences"], minimum: 0, default: 0),
            childCount: links?["children"]?.integer ?? 0,
            parentCount: links?["parents"]?.integer ?? 0,
            commentCount: row["comment_count"]?.integer ?? 0
        )
    }

    private static func decodeEvent(_ value: BighelpJSONValue) throws -> HermesKanbanEvent {
        guard let row = value.object, let id = row["id"]?.integer, id > 0 else {
            throw HermesKanbanError.invalidResponse
        }
        // Only the parts the activity list shows; anything malformed is left out.
        let payload = row["payload"]?.object
        return .init(
            id: id, taskID: try responseText(row["task_id"], maximum: 240),
            runID: try optionalInteger(row["run_id"], minimum: 1),
            kind: try responseText(row["kind"], maximum: 120),
            createdAt: try date(row["created_at"]),
            reason: (try? optionalResponseText(payload?["reason"], maximum: 4_000)) ?? nil,
            failures: payload?["failures"]?.integer.flatMap { (1...1_000).contains($0) ? $0 : nil }
        )
    }

    private static func decodeAttachment(_ value: BighelpJSONValue) throws -> HermesKanbanAttachment {
        guard let row = value.object, let id = row["id"]?.integer, id > 0,
              let size = row["size"]?.integer, (0...25 * 1_024 * 1_024).contains(size) else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(
            id: id, taskID: try responseText(row["task_id"], maximum: 240),
            filename: try responseText(row["filename"], maximum: 255),
            contentType: try optionalResponseText(row["content_type"], maximum: 160),
            byteCount: size,
            uploadedBy: try optionalResponseText(row["uploaded_by"], maximum: 160),
            createdAt: try date(row["created_at"])
        )
    }

    private static func decodeRun(_ value: BighelpJSONValue) throws -> HermesKanbanRun {
        guard let row = value.object, let id = row["id"]?.integer, id > 0 else {
            throw HermesKanbanError.invalidResponse
        }
        return .init(
            id: id, taskID: try responseText(row["task_id"], maximum: 240),
            profile: try optionalResponseText(row["profile"], maximum: 160),
            status: try responseText(row["status"], maximum: 120),
            workerPID: try optionalInteger(row["worker_pid"], minimum: 1),
            startedAt: try date(row["started_at"]),
            endedAt: try optionalDate(row["ended_at"]),
            outcome: try optionalResponseText(row["outcome"], maximum: 120),
            summary: try optionalResponseText(row["summary"], maximum: maximumTextBytes),
            // The real error: it says why the task stopped (`KanbanFailure` puts it in plain words).
            error: row["error"] == nil || row["error"] == .null ? nil
                : (try? optionalResponseText(row["error"], maximum: maximumTextBytes)) ?? "Hermes reported that this run failed.",
            lastHeartbeatAt: try optionalDate(row["last_heartbeat_at"]),
            maxRuntimeSeconds: try optionalInteger(row["max_runtime_seconds"], minimum: 1)
        )
    }

    private static func decodeInspection(_ value: BighelpJSONValue, expectedRunID: Int) throws
        -> HermesKanbanRunInspection {
        guard let row = value.object, row["run_id"]?.integer == expectedRunID,
              let alive = row["alive"]?.boolean else { throw HermesKanbanError.invalidResponse }
        return .init(
            runID: expectedRunID, isAlive: alive,
            processID: try optionalInteger(row["pid"], minimum: 1),
            status: try optionalResponseText(row["status"], maximum: 120),
            CPUPercent: try optionalNumber(row["cpu_percent"], minimum: 0),
            residentBytes: try optionalInteger(row["memory_rss_bytes"], minimum: 0),
            virtualBytes: try optionalInteger(row["memory_vms_bytes"], minimum: 0),
            threadCount: try optionalInteger(row["num_threads"], minimum: 0),
            reason: try optionalResponseText(row["reason"] ?? row["error"], maximum: 2_048)
        )
    }

    private static func validated(_ draft: HermesKanbanTaskDraft) throws -> HermesKanbanTaskDraft {
        var draft = draft
        draft.title = try text(draft.title.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 8_192)
        draft.body = try text(draft.body, maximum: maximumTextBytes, empty: true)
        draft.assignee = try draft.assignee.map { try text($0, maximum: 160) }
        draft.tenant = try draft.tenant.map { try text($0, maximum: 240) }
        draft.workspaceKind = try draft.workspaceKind.map { try text($0, maximum: 80) }
        draft.workspacePath = try draft.workspacePath.map { try text($0, maximum: 4_096) }
        draft.parentIDs = try draft.parentIDs.map { try identifier($0, maximum: 240) }
        draft.idempotencyKey = try draft.idempotencyKey.map { try identifier($0, maximum: 240) }
        guard Set(draft.parentIDs.map { Data($0.utf8) }).count == draft.parentIDs.count,
              (-1_000...1_000).contains(draft.priority),
              draft.maximumRuntimeSeconds.map({ (1...604_800).contains($0) }) ?? true,
              draft.goalMaximumTurns.map({ (1...10_000).contains($0) }) ?? true else {
            throw HermesKanbanError.invalidRequest
        }
        draft.skills = try draft.skills.map { try $0.map { try text($0, maximum: 240) } }
        draft.modelOverride = try draft.modelOverride.map { try text($0, maximum: 512) }
        draft.providerOverride = try draft.providerOverride.map { try text($0, maximum: 256) }
        draft.reasoningEffort = try draft.reasoningEffort.map { try text($0, maximum: 80) }
        draft.projectID = try draft.projectID.map { try text($0, maximum: 240) }
        return draft
    }

    private static func validated(_ patch: HermesKanbanTaskPatch) throws -> HermesKanbanTaskPatch {
        var patch = patch
        if case .set(let value) = patch.title {
            patch.title = .set(try text(value.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 8_192))
        }
        if case .set(let value) = patch.body { patch.body = .set(try text(value, maximum: maximumTextBytes, empty: true)) }
        if case .set(let value) = patch.assignee {
            patch.assignee = .set(try value.map { try text($0, maximum: 160) })
        }
        if case .set(let value) = patch.status, !value.canBeSetDirectly { throw HermesKanbanError.invalidRequest }
        if case .set(let value) = patch.priority, !(-1_000...1_000).contains(value) { throw HermesKanbanError.invalidRequest }
        if case .set(let value) = patch.blockReason { patch.blockReason = .set(try text(value, maximum: 8_192, empty: true)) }
        if case .set(let value) = patch.result { patch.result = .set(try text(value, maximum: maximumTextBytes, empty: true)) }
        if case .set(let value) = patch.summary { patch.summary = .set(try text(value, maximum: maximumTextBytes, empty: true)) }
        return patch
    }

    private static func patchBody(_ patch: HermesKanbanTaskPatch) throws -> Object {
        var body: Object = [:]
        if case .set(let value) = patch.title { body["title"] = .string(value) }
        if case .set(let value) = patch.body { body["body"] = .string(value) }
        if case .set(let value) = patch.assignee { body["assignee"] = .string(value ?? "") }
        if case .set(let value) = patch.status { body["status"] = .string(value.rawValue) }
        if case .set(let value) = patch.priority { body["priority"] = .integer(value) }
        if case .set(let value) = patch.blockReason { body["block_reason"] = .string(value) }
        if case .set(let value) = patch.result { body["result"] = .string(value) }
        if case .set(let value) = patch.summary { body["summary"] = .string(value) }
        guard !body.isEmpty else { throw HermesKanbanError.invalidRequest }
        return body
    }

    private static func verify(_ patch: HermesKanbanTaskPatch, in task: HermesKanbanTask) throws {
        if case .set(let value) = patch.title, !exact(task.title, value) { throw HermesKanbanError.mutationNotVerified }
        if case .set(let value) = patch.body, task.body != value { throw HermesKanbanError.mutationNotVerified }
        if case .set(let value) = patch.assignee, task.assignee != value { throw HermesKanbanError.mutationNotVerified }
        if case .set(let value) = patch.status, task.status != value { throw HermesKanbanError.mutationNotVerified }
        if case .set(let value) = patch.priority, task.priority != value { throw HermesKanbanError.mutationNotVerified }
        if case .set(let value) = patch.result, task.result != value { throw HermesKanbanError.mutationNotVerified }
        // `summary` is run-handoff state and may not project back onto a task that
        // has no current run. The revision/event readback still proves the write.
    }

    private static func canonicalRevision(
        task: HermesKanbanTask,
        comments: [HermesKanbanComment],
        events: [HermesKanbanEvent],
        attachments: [HermesKanbanAttachment],
        runs: [HermesKanbanRun]
    ) throws -> Data {
        try canonical(.object([
            "task": taskRevisionValue(task),
            "comments": .array(comments.map { .object(["id": .integer($0.id), "created_at": .number($0.createdAt.timeIntervalSince1970)]) }),
            "events": .array(events.map { .object(["id": .integer($0.id), "kind": .string($0.kind)]) }),
            "attachments": .array(attachments.map { .object(["id": .integer($0.id), "size": .integer($0.byteCount), "filename": .string($0.filename)]) }),
            "runs": .array(runs.map(runRevisionValue)),
        ]))
    }

    private static func taskRevisionValue(_ task: HermesKanbanTask) -> BighelpJSONValue {
        .object([
            "id": .string(task.id), "title": .string(task.title), "body": task.body.map(BighelpJSONValue.string) ?? .null,
            "assignee": task.assignee.map(BighelpJSONValue.string) ?? .null, "status": .string(task.status.rawValue),
            "priority": .integer(task.priority), "result": task.result.map(BighelpJSONValue.string) ?? .null,
            "idempotency_key": task.idempotencyKey.map(BighelpJSONValue.string) ?? .null,
            "current_run_id": task.currentRunID.map(BighelpJSONValue.integer) ?? .null,
            "workflow_template_id": task.workflowTemplateID.map(BighelpJSONValue.string) ?? .null,
            "current_step_key": task.currentStepKey.map(BighelpJSONValue.string) ?? .null,
            "model_override": task.modelOverride.map(BighelpJSONValue.string) ?? .null,
            "provider_override": task.providerOverride.map(BighelpJSONValue.string) ?? .null,
            "reasoning_effort": task.reasoningEffort.map(BighelpJSONValue.string) ?? .null,
            "skills": task.skills.map { .array($0.map(BighelpJSONValue.string)) } ?? .null,
            "max_retries": task.maximumRetries.map(BighelpJSONValue.integer) ?? .null,
            "consecutive_failures": .integer(task.consecutiveFailures),
            "goal_mode": .boolean(task.goalMode),
            "goal_max_turns": task.goalMaximumTurns.map(BighelpJSONValue.integer) ?? .null,
            "completion_contract": task.completionContract.map(BighelpJSONValue.string) ?? .null,
            "block_kind": task.blockKind.map(BighelpJSONValue.string) ?? .null,
            "block_recurrences": .integer(task.blockRecurrences),
        ])
    }

    private static func runRevisionValue(_ run: HermesKanbanRun) -> BighelpJSONValue {
        .object([
            "id": .integer(run.id), "task_id": .string(run.taskID), "status": .string(run.status),
            "worker_pid": run.workerPID.map(BighelpJSONValue.integer) ?? .null,
            "ended_at": run.endedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "outcome": run.outcome.map(BighelpJSONValue.string) ?? .null,
        ])
    }

    static func boardRevision(_ board: HermesKanbanBoardSnapshot) throws -> Data {
        try canonical(.object([
            "slug": .string(board.board.slug), "name": .string(board.board.name),
            "summary": .string(board.board.summary), "total": .integer(board.board.total),
            "latest_event_id": .integer(board.latestEventID),
            "task_ids": .array(board.tasks.map { .string($0.id) }),
        ]))
    }

    private static func runRevision(_ run: HermesKanbanRun) throws -> Data { try canonical(runRevisionValue(run)) }

    private static func canonical(_ value: BighelpJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumResponseBytes else { throw HermesKanbanError.capacityExceeded }
        return Data(SHA256.hash(data: data))
    }

    static func responseText(_ value: BighelpJSONValue?, maximum: Int, empty: Bool = false) throws -> String {
        guard let string = value?.string, string.utf8.count <= maximum,
              empty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !string.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) }) else {
            throw HermesKanbanError.invalidResponse
        }
        return string
    }

    static func optionalResponseText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        return try responseText(value, maximum: maximum, empty: true)
    }

    static func text(_ value: String, maximum: Int, empty: Bool = false) throws -> String {
        guard value.utf8.count <= maximum,
              empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) }) else {
            throw HermesKanbanError.invalidRequest
        }
        return value
    }

    static func strings(_ value: BighelpJSONValue?, maximum: Int) throws -> [String] {
        guard let rows = value?.array, rows.count <= maximum else { throw HermesKanbanError.invalidResponse }
        let strings = try rows.map { try responseText($0, maximum: 4_096) }
        guard Set(strings.map { Data($0.utf8) }).count == strings.count else { throw HermesKanbanError.invalidResponse }
        return strings
    }

    private static func optionalInteger(_ value: BighelpJSONValue?, minimum: Int) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let integer = value.integer, integer >= minimum else { throw HermesKanbanError.invalidResponse }
        return integer
    }

    private static func requiredInteger(
        _ value: BighelpJSONValue?, minimum: Int, default defaultValue: Int
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard let integer = value.integer, integer >= minimum else { throw HermesKanbanError.invalidResponse }
        return integer
    }

    private static func optionalNumber(_ value: BighelpJSONValue?, minimum: Double) throws -> Double? {
        guard let value, value != .null else { return nil }
        guard let number = value.number, number.isFinite, number >= minimum else { throw HermesKanbanError.invalidResponse }
        return number
    }

    private static func date(_ value: BighelpJSONValue?) throws -> Date {
        guard let seconds = value?.number, seconds.isFinite,
              (-62_135_596_800...253_402_300_799).contains(seconds) else {
            throw HermesKanbanError.invalidResponse
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func optionalDate(_ value: BighelpJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        return try date(value)
    }

    static func identifier(_ value: String, maximum: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesKanbanError.invalidRequest
        }
        return value
    }

    private static func filename(_ value: String) throws -> String {
        guard value == (value as NSString).lastPathComponent,
              !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesKanbanError.invalidRequest
        }
        return value
    }

    private static func contentType(_ value: String) throws -> String {
        let value = value.lowercased()
        guard value.utf8.count <= 160, value.contains("/"),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0)) }) else {
            throw HermesKanbanError.invalidRequest
        }
        return value
    }

    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? ""
    }

    static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    private static func put(_ value: String?, key: String, into body: inout Object) {
        if let value { body[key] = .string(value) }
    }

    private static func put(_ value: Int?, key: String, into body: inout Object) {
        if let value { body[key] = .integer(value) }
    }
}
