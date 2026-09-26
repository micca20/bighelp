import Foundation

/// Fixed, app-authored Kanban attachment operations. Callers cannot supply a
/// URL, HTTP method, header, or credential through this seam.
enum DirectHermesKanbanAttachmentRequest: Sendable {
    case upload(
        board: String,
        taskID: String,
        filename: String,
        contentType: String,
        bytes: Data,
        uploadedBy: String,
        maximumResponseBytes: Int
    )
    case download(board: String, attachmentID: Int, maximumBytes: Int)
}

enum DirectHermesKanbanTransportBoundary {
    static let maximumTransferBytes = 16 * 1_024 * 1_024
    static let maximumMultipartOverheadBytes = 16 * 1_024
    static let maximumMutationResponseBytes = 256 * 1_024
    static let maximumEventFrameBytes = 16 * 1_024 * 1_024
    static let maximumEventsPerFrame = 200

    struct PreparedRequest: Sendable {
        let route: String
        let method: String
        let query: [URLQueryItem]
        let accept: String
        let contentType: String?
        let body: Data?
        let maximumResponseBytes: Int
    }

    static func prepare(_ request: DirectHermesKanbanAttachmentRequest) throws -> PreparedRequest {
        switch request {
        case .upload(
            let board, let taskID, let filename, let contentType, let bytes,
            let uploadedBy, let maximumResponseBytes
        ):
            try validateUpload(
                board: board,
                taskID: taskID,
                filename: filename,
                contentType: contentType,
                bytes: bytes,
                uploadedBy: uploadedBy,
                maximumResponseBytes: maximumResponseBytes
            )
            let multipart = try multipartBody(
                filename: filename,
                contentType: contentType,
                bytes: bytes,
                uploadedBy: uploadedBy
            )
            return .init(
                route: "/api/plugins/kanban/tasks/\(taskID)/attachments",
                method: "POST",
                query: [.init(name: "board", value: board)],
                accept: "application/json",
                contentType: "multipart/form-data; boundary=\(multipart.boundary)",
                body: multipart.body,
                maximumResponseBytes: maximumResponseBytes
            )

        case .download(let board, let attachmentID, let maximumBytes):
            try validateBoard(board)
            guard attachmentID > 0 else { throw HermesKanbanError.invalidRequest }
            try validateTransferLimit(maximumBytes)
            return .init(
                route: "/api/plugins/kanban/attachments/\(attachmentID)",
                method: "GET",
                query: [.init(name: "board", value: board)],
                accept: "application/octet-stream",
                contentType: nil,
                body: nil,
                maximumResponseBytes: maximumBytes
            )
        }
    }

    static func eventQuery(board: String, since cursor: Int) throws -> [URLQueryItem] {
        try validateBoard(board)
        guard cursor >= 0 else { throw HermesKanbanError.invalidRequest }
        return [
            .init(name: "board", value: board),
            .init(name: "since", value: String(cursor)),
        ]
    }

    static func validateUpload(
        board: String,
        taskID: String,
        filename: String,
        contentType: String,
        bytes: Data,
        uploadedBy: String,
        maximumResponseBytes: Int
    ) throws {
        try validateBoard(board)
        try validateTaskID(taskID)
        try validateFilename(filename)
        try validateContentType(contentType)
        try validateUploadedBy(uploadedBy)
        guard !bytes.isEmpty, bytes.count <= maximumTransferBytes,
              (1...maximumMutationResponseBytes).contains(maximumResponseBytes) else {
            throw HermesKanbanError.capacityExceeded
        }
    }

    static func decodeEventBatch(
        _ message: URLSessionWebSocketTask.Message,
        after acceptedCursor: Int
    ) throws -> HermesKanbanEventBatch {
        let data: Data
        switch message {
        case .string(let text):
            guard text.utf8.count <= maximumEventFrameBytes else {
                throw HermesKanbanError.capacityExceeded
            }
            data = Data(text.utf8)
        case .data:
            // The mounted API uses send_json. Binary event frames are not part of
            // its contract and must not be reinterpreted as another protocol.
            throw HermesKanbanError.invalidResponse
        @unknown default:
            throw HermesKanbanError.invalidResponse
        }

        try DirectHermesWire.validateNesting(data)
        guard data.count <= maximumEventFrameBytes,
              let value = try? JSONDecoder().decode(LoopdyJSONValue.self, from: data),
              let object = value.object,
              Set(object.keys) == Set(["events", "cursor"]),
              let cursor = object["cursor"]?.integer,
              cursor > acceptedCursor,
              let rows = object["events"]?.array,
              !rows.isEmpty,
              rows.count <= maximumEventsPerFrame else {
            throw HermesKanbanError.invalidResponse
        }

        var previousID = acceptedCursor
        var events: [HermesKanbanEvent] = []
        events.reserveCapacity(rows.count)
        for value in rows {
            guard let row = value.object,
                  Set(row.keys) == Set(["id", "task_id", "run_id", "kind", "payload", "created_at"]),
                  let id = row["id"]?.integer,
                  id > previousID,
                  id <= cursor else {
                throw HermesKanbanError.invalidResponse
            }
            let taskID = try responseTaskID(row["task_id"])
            let kind = try responseText(row["kind"], maximumBytes: 120)
            let runID: Int?
            if row["run_id"] == .null {
                runID = nil
            } else {
                guard let value = row["run_id"]?.integer, value > 0 else {
                    throw HermesKanbanError.invalidResponse
                }
                runID = value
            }
            guard row["payload"] == .null || row["payload"]?.object != nil,
                  let seconds = row["created_at"]?.number,
                  seconds.isFinite,
                  seconds.rounded() == seconds,
                  (-62_135_596_800...253_402_300_799).contains(seconds) else {
                throw HermesKanbanError.invalidResponse
            }
            events.append(.init(
                id: id,
                taskID: taskID,
                runID: runID,
                kind: kind,
                createdAt: Date(timeIntervalSince1970: seconds)
            ))
            previousID = id
        }
        guard previousID == cursor else { throw HermesKanbanError.invalidResponse }
        return .init(events: events, cursor: cursor)
    }

    static func responseContentType(_ response: HTTPURLResponse) throws -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        guard raw.utf8.count <= 256,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesKanbanError.invalidResponse
        }
        let base = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let base, !base.isEmpty else { throw HermesKanbanError.invalidResponse }
        do {
            try validateContentType(base)
        } catch {
            throw HermesKanbanError.invalidResponse
        }
        return base
    }

    static func requireJSON(_ response: HTTPURLResponse) throws {
        guard try responseContentType(response) == "application/json" else {
            throw HermesKanbanError.invalidResponse
        }
    }

    static func validateBoard(_ board: String) throws {
        let bytes = Array(board.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first,
              (48...57).contains(first) || (97...122).contains(first),
              bytes.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else {
            throw HermesKanbanError.invalidRequest
        }
    }

    static func validateTaskID(_ taskID: String) throws {
        let bytes = Array(taskID.utf8)
        guard bytes.count >= 10, bytes.count <= 240,
              bytes[0] == 116, bytes[1] == 95,
              bytes.dropFirst(2).allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw HermesKanbanError.invalidRequest
        }
    }

    private static func responseTaskID(_ value: LoopdyJSONValue?) throws -> String {
        guard let taskID = value?.string else { throw HermesKanbanError.invalidResponse }
        do {
            try validateTaskID(taskID)
            return taskID
        } catch {
            throw HermesKanbanError.invalidResponse
        }
    }

    private static func responseText(_ value: LoopdyJSONValue?, maximumBytes: Int) throws -> String {
        guard let text = value?.string,
              !text.isEmpty,
              text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !text.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw HermesKanbanError.invalidResponse
        }
        return text
    }

    private static func validateTransferLimit(_ maximumBytes: Int) throws {
        guard (1...maximumTransferBytes).contains(maximumBytes) else {
            throw HermesKanbanError.capacityExceeded
        }
    }

    private static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename.utf8.count <= 255,
              filename.unicodeScalars.count <= 200,
              filename.utf8.elementsEqual(
                  filename.trimmingCharacters(in: .whitespacesAndNewlines).utf8
              ),
              filename != ".", filename != "..",
              filename == (filename as NSString).lastPathComponent,
              !filename.hasPrefix("."),
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !filename.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw HermesKanbanError.invalidRequest
        }
    }

    private static func validateContentType(_ contentType: String) throws {
        guard !contentType.isEmpty, contentType.utf8.count <= 160,
              contentType.contains("/"),
              contentType.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
              }) else {
            throw HermesKanbanError.invalidRequest
        }
    }

    private static func validateUploadedBy(_ uploadedBy: String) throws {
        guard !uploadedBy.isEmpty, uploadedBy.utf8.count <= 160,
              !uploadedBy.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !uploadedBy.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw HermesKanbanError.invalidRequest
        }
    }

    private static func multipartBody(
        filename: String,
        contentType: String,
        bytes: Data,
        uploadedBy: String
    ) throws -> (boundary: String, body: Data) {
        let boundary = try multipartBoundary(excluding: [
            bytes, Data(filename.utf8), Data(uploadedBy.utf8), Data(contentType.utf8),
        ])
        let encodedFilename = percentEncodedHeaderValue(filename)

        var body = Data()
        body.reserveCapacity(bytes.count + maximumMultipartOverheadBytes)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(encodedFilename)\"; "
                .appending("filename*=UTF-8''\(encodedFilename)\r\n").utf8
        ))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"uploaded_by\"\r\n\r\n".utf8))
        body.append(Data(uploadedBy.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard body.count <= maximumTransferBytes + maximumMultipartOverheadBytes else {
            throw HermesKanbanError.capacityExceeded
        }
        return (boundary, body)
    }

    private static func percentEncodedHeaderValue(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(decoding: [byte], as: UTF8.self)
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func multipartBoundary(excluding values: [Data]) throws -> String {
        for _ in 0..<8 {
            let candidate = "Loopdy-Kanban-\(UUID().uuidString)"
            let bytes = Data(candidate.utf8)
            if values.allSatisfy({ $0.range(of: bytes) == nil }) { return candidate }
        }
        throw HermesKanbanError.invalidRequest
    }
}

extension DirectHermesHTTP {
    /// Uses the retained ephemeral URLSession and redirect/TLS delegate. The only
    /// widened bodies and responses are the two fixed Kanban attachment routes.
    func sendKanbanAttachment(
        _ operation: DirectHermesKanbanAttachmentRequest,
        bearer: String?,
        legacyToken: String?
    ) async throws -> Response {
        try Task.checkCancellation()
        let prepared = try DirectHermesKanbanTransportBoundary.prepare(operation)
        guard (bearer != nil) != (legacyToken != nil) else {
            throw DirectHermesError.unsupportedAuthentication
        }
        var components = URLComponents(
            url: try endpoint.url(for: prepared.route),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = prepared.query
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = prepared.method
        request.httpShouldHandleCookies = false
        request.setValue(prepared.accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearer {
            try DirectHermesSecretValidation.validate(bearer)
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let legacyToken {
            try DirectHermesSecretValidation.validate(legacyToken)
            request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        if let contentType = prepared.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = prepared.body

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            if (300...399).contains(http.statusCode) {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            guard http.expectedContentLength <= Int64(prepared.maximumResponseBytes) else {
                bytes.task.cancel()
                throw DirectHermesError.messageTooLarge
            }
            let body = try await Self.collectBody(bytes, maximumBytes: prepared.maximumResponseBytes)
            try Task.checkCancellation()
            return .init(http: http, body: body)
        } catch {
            throw Self.safeError(error)
        }
    }
}

/// Fixed-route multipart/binary and event-WebSocket transport for the mounted
/// stock Kanban dashboard. It shares the retained authenticator and URLSession;
/// it never creates a second login or reuses the main gateway socket ticket.
@MainActor
final class DirectHermesKanbanTransport: DirectHermesKanbanAttachmentTransport,
    DirectHermesKanbanEventTransport {
    private static let maximumReconnectAttempts = 6

    private let authenticator: DirectHermesAuthenticator
    private let isCurrent: @MainActor () -> Bool
    private var eventOperationID: UUID?
    private var eventSocket: URLSessionWebSocketTask?
    private var eventTask: Task<Void, Never>?

    init(
        authenticator: DirectHermesAuthenticator,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.authenticator = authenticator
        self.isCurrent = isCurrent
    }

    func uploadKanbanAttachment(
        board: String,
        taskID: String,
        filename: String,
        contentType: String,
        bytes: Data,
        uploadedBy: String,
        maximumResponseBytes: Int
    ) async throws -> LoopdyJSONValue {
        let operation = DirectHermesKanbanAttachmentRequest.upload(
            board: board,
            taskID: taskID,
            filename: filename,
            contentType: contentType,
            bytes: bytes,
            uploadedBy: uploadedBy,
            maximumResponseBytes: maximumResponseBytes
        )
        try DirectHermesKanbanTransportBoundary.validateUpload(
            board: board,
            taskID: taskID,
            filename: filename,
            contentType: contentType,
            bytes: bytes,
            uploadedBy: uploadedBy,
            maximumResponseBytes: maximumResponseBytes
        )
        try checkTransportOwner()

        var receivedStatus: Int?
        do {
            let response = try await authenticator.authenticatedKanbanAttachmentResponse(operation)
            receivedStatus = response.http.statusCode
            guard isCurrent(), !Task.isCancelled else {
                throw WorkspaceClientError.outcomeUnknown
            }
            switch response.http.statusCode {
            case 200...299:
                break
            case 413:
                throw HermesKanbanError.capacityExceeded
            default:
                try DirectHermesHTTP.requireSuccess(response)
            }
            do {
                try DirectHermesKanbanTransportBoundary.requireJSON(response.http)
                return try response.value()
            } catch {
                // The host may already have committed a successful multipart write.
                // A malformed or oversized receipt is not permission to replay it.
                throw WorkspaceClientError.outcomeUnknown
            }
        } catch {
            if [400, 401, 403, 404, 405, 409, 413, 415, 422, 429]
                .contains(receivedStatus ?? -1) {
                throw error
            }
            // Validation finished before dispatch. A response-size error or
            // redirect refusal can happen after the host committed the upload;
            // neither establishes that retrying the mutation is safe.
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func downloadKanbanAttachment(
        board: String,
        attachmentID: Int,
        maximumBytes: Int
    ) async throws -> (statusCode: Int, contentType: String?, bytes: Data) {
        let operation = DirectHermesKanbanAttachmentRequest.download(
            board: board,
            attachmentID: attachmentID,
            maximumBytes: maximumBytes
        )
        _ = try DirectHermesKanbanTransportBoundary.prepare(operation)
        try checkTransportOwner()
        let response = try await authenticator.authenticatedKanbanAttachmentResponse(operation)
        try checkTransportOwner()
        switch response.http.statusCode {
        case 401, 403:
            try DirectHermesHTTP.requireSuccess(response)
        case 413:
            throw HermesKanbanError.capacityExceeded
        default:
            break
        }
        let contentType = try DirectHermesKanbanTransportBoundary.responseContentType(response.http)
        guard response.body.count <= maximumBytes else { throw HermesKanbanError.capacityExceeded }
        return (response.http.statusCode, contentType, response.body)
    }

    func eventBatches(
        board: String,
        since cursor: Int
    ) -> AsyncThrowingStream<HermesKanbanEventBatch, any Error> {
        cancelEventOperation()
        let id = UUID()
        eventOperationID = id

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                defer { self.finishEventOperation(id: id) }
                do {
                    try DirectHermesKanbanTransportBoundary.validateBoard(board)
                    guard cursor >= 0 else { throw HermesKanbanError.invalidRequest }
                    try await self.consumeEventBatches(
                        id: id,
                        board: board,
                        initialCursor: cursor,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.eventTask = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    self?.cancelEventOperation(id: id)
                }
            }
        }
    }

    private func consumeEventBatches(
        id: UUID,
        board: String,
        initialCursor: Int,
        continuation: AsyncThrowingStream<HermesKanbanEventBatch, any Error>.Continuation
    ) async throws {
        var acceptedCursor = initialCursor
        var reconnectAttempts = 0

        while true {
            try checkEventOperation(id)
            let request = try await authenticator.kanbanEventRequest(
                board: board,
                since: acceptedCursor
            )
            try checkEventOperation(id)
            let expectedURL = request.url
            let socket = authenticator.http.session.webSocketTask(with: request)
            socket.maximumMessageSize = DirectHermesKanbanTransportBoundary.maximumEventFrameBytes
            eventSocket = socket
            let attemptStartedAt = Date()
            socket.resume()

            let ownerMonitor = Task { @MainActor [weak self, socket] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) }
                    catch { return }
                    guard let self, self.eventOperationID == id,
                          self.eventSocket === socket else { return }
                    guard self.isCurrent() else {
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }

            do {
                while true {
                    let message = try await socket.receive()
                    try checkEventOperation(id)
                    try Self.validateUpgrade(socket, expectedURL: expectedURL)
                    let batch = try DirectHermesKanbanTransportBoundary.decodeEventBatch(
                        message,
                        after: acceptedCursor
                    )
                    // Adopt before yielding. If the consumer cancels after yield,
                    // a retry can only resume after the last accepted read cursor.
                    acceptedCursor = batch.cursor
                    reconnectAttempts = 0
                    continuation.yield(batch)
                }
            } catch {
                ownerMonitor.cancel()
                closeEventSocket(id: id, socket: socket)
                try checkEventOperation(id)
                let safe = Self.eventSocketError(
                    error,
                    socket: socket,
                    expectedURL: expectedURL
                )
                if Date().timeIntervalSince(attemptStartedAt) >= 5 {
                    reconnectAttempts = 0
                }
                guard Self.shouldReconnect(after: safe),
                      reconnectAttempts < Self.maximumReconnectAttempts else {
                    throw safe
                }
                reconnectAttempts += 1
                let delay = min(8_000_000_000, 250_000_000 << (reconnectAttempts - 1))
                try await Task.sleep(nanoseconds: UInt64(delay))
            }
        }
    }

    private func checkTransportOwner() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw WorkspaceClientError.ownerChanged }
    }

    private func checkEventOperation(_ id: UUID) throws {
        try checkTransportOwner()
        guard eventOperationID == id else { throw CancellationError() }
    }

    private func cancelEventOperation() {
        guard let id = eventOperationID else { return }
        cancelEventOperation(id: id)
    }

    private func cancelEventOperation(id: UUID) {
        guard eventOperationID == id else { return }
        eventOperationID = nil
        eventTask?.cancel()
        eventTask = nil
        eventSocket?.cancel(with: .goingAway, reason: nil)
        eventSocket = nil
    }

    private func finishEventOperation(id: UUID) {
        guard eventOperationID == id else { return }
        eventOperationID = nil
        eventTask = nil
        eventSocket?.cancel(with: .goingAway, reason: nil)
        eventSocket = nil
    }

    private func closeEventSocket(id: UUID, socket: URLSessionWebSocketTask) {
        socket.cancel(with: .goingAway, reason: nil)
        if eventOperationID == id, eventSocket === socket { eventSocket = nil }
    }

    private static func validateUpgrade(
        _ socket: URLSessionWebSocketTask,
        expectedURL: URL?
    ) throws {
        guard let response = socket.response as? HTTPURLResponse else { return }
        guard response.url == expectedURL else { throw DirectHermesError.redirectRefused }
        if (300...399).contains(response.statusCode) {
            throw DirectHermesError.redirectRefused
        }
        guard response.statusCode == 101 else {
            switch response.statusCode {
            case 401, 403: throw DirectHermesError.invalidCredentials
            case 404, 405: throw HermesKanbanError.eventTransportUnavailable
            case 429: throw DirectHermesError.rateLimited
            case 500...599: throw DirectHermesError.serverUnavailable
            default: throw DirectHermesError.invalidResponse
            }
        }
    }

    private static func eventSocketError(
        _ error: any Error,
        socket: URLSessionWebSocketTask,
        expectedURL: URL?
    ) -> any Error {
        if error is CancellationError || error is HermesKanbanError || error is WorkspaceClientError {
            return error
        }
        if socket.closeCode == .policyViolation { return DirectHermesError.invalidCredentials }
        if let response = socket.response as? HTTPURLResponse {
            guard response.url == expectedURL else { return DirectHermesError.redirectRefused }
            if (300...399).contains(response.statusCode) { return DirectHermesError.redirectRefused }
            switch response.statusCode {
            case 101:
                break
            case 401, 403:
                return DirectHermesError.invalidCredentials
            case 404, 405:
                return HermesKanbanError.eventTransportUnavailable
            case 429:
                return DirectHermesError.rateLimited
            case 500...599:
                return DirectHermesError.serverUnavailable
            default:
                return DirectHermesError.invalidResponse
            }
        }
        return DirectHermesHTTP.safeError(error)
    }

    private static func shouldReconnect(after error: any Error) -> Bool {
        guard let direct = error as? DirectHermesError else { return false }
        switch direct {
        case .connectionFailed, .serverUnavailable, .disconnected, .timedOut:
            return true
        default:
            return false
        }
    }
}
