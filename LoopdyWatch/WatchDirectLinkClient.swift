import CryptoKit
import Foundation

struct WatchDirectTurnResult: Sendable {
    let sessionID: String
    let agentID: String
    let agentName: String
    let text: String
    let audio: Data?
    let mimeType: String?
    let audioError: String?
}

struct WatchDirectAgent: Sendable {
    let id: String
    let name: String
}

private struct WatchPendingTurnRecord: Codable {
    let fingerprint: String
    let sessionID: String
    let agentID: String
    let agentName: String
    let messageID: String
    let turnID: String
    let frameWire: String
    let isAccepted: Bool
}

actor WatchDirectLinkClient {
    enum ClientError: Error {
        case invalidConfiguration
        case invalidResponse
        case requestFailed(String)
        case disconnected
    }

    private let baseURL: URL
    private let credentials: LoopdyLinkRuntimeCredentials
    private let urlSession: URLSession
    private var agents: [WatchDirectAgent] = []
    private var sessionAgentIDs: [String: String] = [:]
    private var sessionStoredIDs: [String: String] = [:]
    private var approvalDigests: [String: String] = [:]
    private var clarificationRequestIDs: [String: String] = [:]
    private let pendingTurnKey: String
    private var operationLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        baseURL: URL,
        credentials: LoopdyLinkRuntimeCredentials,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.urlSession = urlSession
        pendingTurnKey = "loopdy.watch.pending-turn.v1.\(credentials.deviceID)"
    }

    func connectionProbe() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        let connection = try await Connection.open(
            baseURL: baseURL,
            credentials: credentials,
            session: urlSession
        )
        await connection.close()
    }

    func loadSnapshot() async throws -> WatchCompanionSnapshot {
        await acquireOperation()
        defer { releaseOperation() }
        let agentValues = try await workspace("agents.list")
        agents = Self.parseAgents(agentValues)
        let sessionValues = try await workspace("sessions.list")
        let sessions = Self.parseSessions(sessionValues, agents: agents)
        let coordinates = Self.parseSessionCoordinates(sessionValues)
        sessionAgentIDs = coordinates.mapValues(\.agentID)
        sessionStoredIDs = coordinates.mapValues(\.storedID)
        let events = try await workspace("dashboard.load")
        let projected = try await projectEvents(events)
        return WatchCompanionSnapshot(
            generatedAt: .now,
            weather: nil,
            inbox: projected.inbox,
            approvals: projected.approvals,
            sessions: sessions,
            selectedSessionID: nil,
            transcript: []
        )
    }

    func loadTranscript(session: WatchSessionSummary) async throws -> [WatchTranscriptItem] {
        await acquireOperation()
        defer { releaseOperation() }
        let agentID = try agentID(for: session)
        let storedID = sessionStoredIDs[session.id] ?? session.id
        let payload = try await workspace("sessions.history", payload: [
            "storedId": .string(storedID),
            "agentId": .string(agentID),
            "turnLimit": .integer(10),
        ])
        guard payload["storedId"]?.string == storedID,
              payload["agentId"]?.string == agentID,
              let rows = payload["messages"]?.array else {
            throw ClientError.invalidResponse
        }
        var seenIDs = Set<String>()
        return rows.suffix(80).compactMap { value in
            guard let row = value.object,
                  let id = row["id"]?.string,
                  seenIDs.insert(id).inserted,
                  let role = row["role"]?.string,
                  role == "user" || role == "assistant",
                  let rawText = row["content"]?.string else { return nil }
            let text = Self.displayText(rawText, maximumCharacters: 4_000)
            guard !text.isEmpty else { return nil }
            let isUser = role == "user"
            let timestamp = row["timestamp"]?.number.map(Date.init(timeIntervalSince1970:)) ?? .now
            return WatchTranscriptItem(
                id: id,
                speaker: isUser ? "You" : session.agentName,
                text: text,
                timestamp: timestamp,
                isUser: isUser
            )
        }
    }

    func sendText(
        sessionID: String?,
        agentID requestedAgentID: String?,
        text: String,
        requestSpeech: Bool
    ) async throws -> WatchDirectTurnResult {
        await acquireOperation()
        defer { releaseOperation() }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 10_000 else {
            throw ClientError.invalidConfiguration
        }
        let pending = try loadPendingTurn()
        let selectedAgent: WatchDirectAgent
        let selectedSessionID: String
        let turnID: String
        let messageID: String
        if let pending {
            guard sessionID == nil || sessionID == pending.sessionID,
                  requestedAgentID == nil || requestedAgentID == pending.agentID else {
                throw ClientError.requestFailed("Retry the pending Watch turn before starting another.")
            }
            selectedAgent = WatchDirectAgent(id: pending.agentID, name: pending.agentName)
            selectedSessionID = pending.sessionID
            turnID = pending.turnID
            messageID = pending.messageID
        } else {
            if agents.isEmpty {
                agents = Self.parseAgents(try await workspace("agents.list"))
            }
            let preferredAgentID = requestedAgentID ?? sessionID.flatMap { sessionAgentIDs[$0] }
            guard let resolvedAgent = preferredAgentID.flatMap({ id in agents.first { $0.id == id } })
                ?? agents.first else { throw ClientError.invalidResponse }
            selectedAgent = resolvedAgent
            selectedSessionID = sessionID ?? "link-" + UUID().uuidString.lowercased()
            turnID = "watch-turn-" + UUID().uuidString.lowercased()
            messageID = "watch-message-" + UUID().uuidString.lowercased()
        }
        let fingerprint = pendingFingerprint(
            sessionID: selectedSessionID,
            agentID: selectedAgent.id,
            text: normalized
        )
        guard pending == nil || pending?.fingerprint == fingerprint else {
            throw ClientError.requestFailed("Retry the pending Watch turn without changing its text.")
        }
        let connection = try await Connection.open(
            baseURL: baseURL,
            credentials: credentials,
            session: urlSession
        )
        defer { Task { await connection.close() } }
        let message = WatchLinkUserMessage(
            messageID: messageID,
            sessionID: selectedSessionID,
            agentID: selectedAgent.id,
            turnID: turnID,
            actorID: "watch-user",
            actorName: "You",
            deviceName: "Apple Watch",
            text: normalized,
            sentAt: Self.timestamp()
        )
        let frameWire: String
        if let pending {
            frameWire = pending.frameWire
        } else {
            frameWire = try await connection.prepare(message)
        }
        if pending == nil {
            try savePendingTurn(WatchPendingTurnRecord(
                fingerprint: fingerprint,
                sessionID: selectedSessionID,
                agentID: selectedAgent.id,
                agentName: selectedAgent.name,
                messageID: messageID,
                turnID: turnID,
                frameWire: frameWire,
                isAccepted: false
            ))
        }
        let final: WatchLinkAssistantMessage
        if let pending, pending.isAccepted {
            final = try await recoverAcceptedTurn(
                connection: connection,
                record: pending
            )
        } else {
            let disposition = try await connection.reconcileAndSendPending(frameWire)
            if disposition == .accepted {
                let accepted = WatchPendingTurnRecord(
                    fingerprint: fingerprint,
                    sessionID: selectedSessionID,
                    agentID: selectedAgent.id,
                    agentName: selectedAgent.name,
                    messageID: messageID,
                    turnID: turnID,
                    frameWire: frameWire,
                    isAccepted: true
                )
                try savePendingTurn(accepted)
                final = try await recoverAcceptedTurn(connection: connection, record: accepted)
            } else {
                final = try await connection.waitForAssistant(
                    requestID: messageID,
                    sessionID: selectedSessionID,
                    agentID: selectedAgent.id,
                    turnID: turnID
                )
            }
        }
        let responseText = Self.displayText(final.text, maximumCharacters: 4_000)
        guard !responseText.isEmpty else { throw ClientError.invalidResponse }
        clearPendingTurn()
        var audio: Data?
        var mimeType: String?
        var audioError: String?
        if requestSpeech {
            let voiceRequestID = "watch-voice-" + UUID().uuidString.lowercased()
            do {
                try await connection.send(WatchLinkVoiceRequest(
                    requestID: voiceRequestID,
                    sessionID: selectedSessionID,
                    agentID: selectedAgent.id,
                    text: responseText,
                    sentAt: Self.timestamp()
                ))
                let voice = try await connection.waitForVoice(
                    requestID: voiceRequestID,
                    sessionID: selectedSessionID,
                    agentID: selectedAgent.id
                )
                audio = voice.data
                mimeType = voice.mimeType
            } catch {
                audioError = "The reply arrived, but Hermes audio was unavailable."
            }
        }
        sessionAgentIDs[selectedSessionID] = selectedAgent.id
        return WatchDirectTurnResult(
            sessionID: selectedSessionID,
            agentID: selectedAgent.id,
            agentName: final.agentName,
            text: responseText,
            audio: audio,
            mimeType: mimeType,
            audioError: audioError
        )
    }

    func respondToApproval(id: String, decision: WatchApprovalDecision) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard let digest = approvalDigests[id] else { throw ClientError.invalidConfiguration }
        let payload = try await workspace("approvals.respond", payload: [
            "approvalId": .string(id),
            "requestDigest": .string(digest),
            "choice": .string(decision.rawValue),
        ])
        guard Set(payload.keys) == Set(["accepted", "approvalId", "choice"]),
              payload["accepted"]?.boolean == true,
              payload["approvalId"]?.string == id,
              payload["choice"]?.string == decision.rawValue else {
            throw ClientError.invalidResponse
        }
        approvalDigests[id] = nil
    }

    func dismissEvent(id: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        let payload = try await workspace("dashboard.dismiss_event", payload: ["eventId": .string(id)])
        guard Set(payload.keys) == Set(["eventId", "dismissed"]),
              payload["eventId"]?.string == id,
              payload["dismissed"]?.boolean == true else {
            throw ClientError.invalidResponse
        }
    }

    func respondToClarification(itemID: String, response: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard let requestID = clarificationRequestIDs[itemID] else {
            throw ClientError.invalidConfiguration
        }
        let payload = try await workspace("clarifications.respond", payload: [
            "eventId": .string(itemID),
            "clarifyId": .string(requestID),
            "response": .string(response),
        ])
        guard Set(payload.keys) == Set(["accepted", "eventId", "clarifyId"]),
              payload["accepted"]?.boolean == true,
              payload["eventId"]?.string == itemID,
              payload["clarifyId"]?.string == requestID else {
            throw ClientError.invalidResponse
        }
        clarificationRequestIDs[itemID] = nil
    }

    private func recoverAcceptedTurn(
        connection: Connection,
        record: WatchPendingTurnRecord
    ) async throws -> WatchLinkAssistantMessage {
        var storedID = sessionStoredIDs[record.sessionID] ?? record.sessionID
        for attempt in 0..<30 {
            var offset = 0
            var seenOffsets = Set([0])
            var newerBoundaryRows: [WatchLinkJSON] = []
            var exhaustedHistory = false
            for _ in 0..<500 {
                let requestID = "watch-recovery-" + UUID().uuidString.lowercased()
                var requestPayload: [String: WatchLinkJSON] = [
                    "storedId": .string(storedID),
                    "agentId": .string(record.agentID),
                    "turnLimit": .integer(10),
                ]
                if offset > 0 { requestPayload["offset"] = .integer(offset) }
                try await connection.send(WatchLinkWorkspaceRequest(
                    requestID: requestID,
                    operation: "sessions.history",
                    payload: requestPayload,
                    sentAt: Self.timestamp()
                ))
                let payload = try await connection.waitForWorkspace(
                    requestID: requestID,
                    operation: "sessions.history"
                )
                guard let returnedStoredID = payload["storedId"]?.string,
                      payload["agentId"]?.string == record.agentID,
                      let messages = payload["messages"]?.array else {
                    throw ClientError.invalidResponse
                }
                storedID = returnedStoredID
                sessionStoredIDs[record.sessionID] = returnedStoredID
                if let userIndex = messages.firstIndex(where: { value in
                    value.object?["id"]?.string == record.messageID
                        && value.object?["role"]?.string == "user"
                }) {
                    let following = Array(messages.dropFirst(userIndex + 1)) + newerBoundaryRows
                    if let recovered = Self.recoveredAssistant(
                        from: following,
                        record: record
                    ) {
                        return recovered
                    }
                    exhaustedHistory = true
                    break
                }
                newerBoundaryRows = Array(messages.prefix { value in
                    value.object?["role"]?.string != "user"
                })
                guard let nextOffset = payload["nextOffset"]?.integer else {
                    exhaustedHistory = true
                    break
                }
                guard nextOffset > offset, seenOffsets.insert(nextOffset).inserted else {
                    throw ClientError.invalidResponse
                }
                offset = nextOffset
            }
            guard exhaustedHistory else { throw ClientError.invalidResponse }
            if attempt < 29 {
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw ClientError.disconnected
    }

    private static func recoveredAssistant(
        from values: [WatchLinkJSON],
        record: WatchPendingTurnRecord
    ) -> WatchLinkAssistantMessage? {
        for value in values {
            guard let row = value.object, let role = row["role"]?.string else { continue }
            if role == "user" { return nil }
            guard role == "assistant",
                  let messageID = row["id"]?.string,
                  let text = row["content"]?.string,
                  !text.isEmpty else { continue }
            return WatchLinkAssistantMessage(
                version: 1,
                type: "assistant.message",
                messageID: messageID,
                requestID: record.messageID,
                sessionID: record.sessionID,
                turnID: record.turnID,
                agentID: record.agentID,
                agentName: record.agentName,
                text: text,
                sentAt: row["timestamp"]?.integer ?? timestamp(),
                delivery: "final"
            )
        }
        return nil
    }

    private func acquireOperation() async {
        if !operationLocked {
            operationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationLocked = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func workspace(
        _ operation: String,
        payload: [String: WatchLinkJSON] = [:]
    ) async throws -> [String: WatchLinkJSON] {
        let requestID = "watch-request-" + UUID().uuidString.lowercased()
        let connection = try await Connection.open(
            baseURL: baseURL,
            credentials: credentials,
            session: urlSession
        )
        defer { Task { await connection.close() } }
        try await connection.send(WatchLinkWorkspaceRequest(
            requestID: requestID,
            operation: operation,
            payload: payload,
            sentAt: Self.timestamp()
        ))
        return try await connection.waitForWorkspace(requestID: requestID, operation: operation)
    }

    private func projectEvents(_ payload: [String: WatchLinkJSON]) async throws -> (
        inbox: [WatchInboxItem], approvals: [WatchApprovalRequest]
    ) {
        guard let events = payload["events"]?.array else { return ([], []) }
        var inbox: [WatchInboxItem] = []
        var approvals: [WatchApprovalRequest] = []
        for value in events.suffix(40) {
            guard let event = value.object,
                  let id = event["eventId"]?.string,
                  let type = event["type"]?.string,
                  let profile = event["profile"]?.string,
                  let detail = event["detail"]?.object else { continue }
            let agentName = agents.first(where: { $0.id == profile })?.name ?? "Loopdy"
            let title = detail["title"]?.string ?? detail["action"]?.string ?? type
            let body = detail["message"]?.string ?? detail["detail"]?.string ?? "Needs your attention"
            let date = event["createdAt"]?.number.map(Date.init(timeIntervalSince1970:)) ?? .now
            if type == "approval.required" {
                guard let approvalID = event["approvalId"]?.string else {
                    throw ClientError.invalidResponse
                }
                let loaded = try await loadApproval(id: approvalID)
                approvals.append(loaded)
            } else if type == "attention.required" {
                let interaction = detail["interaction"]?.object
                guard interaction?["type"]?.string == "clarify",
                      let requestID = interaction?["requestId"]?.string else { continue }
                let question = interaction?["questions"]?.array?.first?.object
                let choices = question?["choices"]?.array?.compactMap(\.string) ?? []
                clarificationRequestIDs[id] = requestID
                inbox.append(WatchInboxItem(
                    id: id,
                    kind: .clarification,
                    title: String(title.prefix(160)),
                    detail: String(body.prefix(600)),
                    agentName: agentName,
                    agentRole: "Agent",
                    createdAt: date,
                    choices: Array(choices.prefix(4)),
                    allowsCustomResponse: true
                ))
            }
        }
        return (Array(inbox.suffix(12)), Array(approvals.suffix(8)))
    }

    private func loadApproval(id: String) async throws -> WatchApprovalRequest {
        let payload = try await workspace("approvals.load", payload: ["approvalId": .string(id)])
        guard let approval = payload["approval"]?.object,
              approval["id"]?.string == id,
              approval["status"]?.string == "pending",
              let expiresAt = approval["expiresAt"]?.number,
              expiresAt > Date().timeIntervalSince1970,
              let eventID = approval["eventId"]?.string,
              let digest = approval["requestDigest"]?.string,
              let choices = approval["allowedChoices"]?.array,
              (1...4).contains(choices.count),
              let event = payload["event"]?.object,
              event["eventId"]?.string == eventID,
              event["approvalId"]?.string == id,
              event["type"]?.string == "approval.required" else {
            throw ClientError.invalidResponse
        }
        let decisions = choices.compactMap { $0.string.flatMap(WatchApprovalDecision.init(rawValue:)) }
        guard decisions.count == choices.count, !decisions.isEmpty else {
            throw ClientError.invalidResponse
        }
        approvalDigests[id] = digest
        let detail = event["detail"]?.object
        return WatchApprovalRequest(
            requestID: id,
            action: String((detail?["title"]?.string ?? detail?["action"]?.string ?? "Approve request").prefix(60)),
            requester: "Loopdy",
            vendor: "Hermes",
            amount: "One action",
            dueDate: "",
            category: detail?["surface"]?.string ?? "Hermes",
            consequence: String((detail?["message"]?.string ?? "Allows this request once.").prefix(80)),
            allowedDecisions: decisions
        )
    }

    private func agentID(for session: WatchSessionSummary) throws -> String {
        if let value = sessionAgentIDs[session.id] { return value }
        if let value = agents.first(where: { $0.name == session.agentName })?.id { return value }
        throw ClientError.invalidResponse
    }

    private func pendingFingerprint(sessionID: String, agentID: String, text: String) -> String {
        let material = Data("\(sessionID)\u{0}\(agentID)\u{0}\(text)".utf8)
        let code = HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: credentials.accountKey)
        )
        return LoopdyLinkBase64URL.encode(Data(code))
    }

    private func loadPendingTurn() throws -> WatchPendingTurnRecord? {
        guard let envelope = UserDefaults.standard.string(forKey: pendingTurnKey) else { return nil }
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        return try cipher.open(envelope)
    }

    private func savePendingTurn(_ record: WatchPendingTurnRecord) throws {
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        UserDefaults.standard.set(try cipher.seal(record), forKey: pendingTurnKey)
    }

    private func clearPendingTurn() {
        UserDefaults.standard.removeObject(forKey: pendingTurnKey)
    }

    private static func parseAgents(_ payload: [String: WatchLinkJSON]) -> [WatchDirectAgent] {
        guard let values = payload["agents"]?.array else { return [] }
        return values.prefix(64).compactMap { value in
            guard let source = value.object,
                  let id = source["id"]?.string ?? source["profile"]?.string,
                  let name = source["name"]?.string else { return nil }
            return WatchDirectAgent(id: id, name: name)
        }
    }

    private static func parseSessions(
        _ payload: [String: WatchLinkJSON],
        agents: [WatchDirectAgent]
    ) -> [WatchSessionSummary] {
        guard let values = payload["sessions"]?.array else { return [] }
        return values.prefix(16).compactMap { value in
            guard let source = value.object,
                  let id = source["visibleId"]?.string,
                  let profile = source["profile"]?.string,
                  let title = source["title"]?.string,
                  let preview = source["preview"]?.string else { return nil }
            return WatchSessionSummary(
                id: id,
                title: title,
                agentName: agents.first(where: { $0.id == profile })?.name ?? profile,
                preview: preview,
                updatedAt: source["lastActive"]?.number.map(Date.init(timeIntervalSince1970:)) ?? .now,
                isActive: source["isActive"]?.boolean ?? false
            )
        }
    }

    private struct SessionCoordinate {
        let storedID: String
        let agentID: String
    }

    private static func parseSessionCoordinates(
        _ payload: [String: WatchLinkJSON]
    ) -> [String: SessionCoordinate] {
        guard let values = payload["sessions"]?.array else { return [:] }
        var result: [String: SessionCoordinate] = [:]
        for value in values.prefix(16) {
            guard let source = value.object,
                  let visibleID = source["visibleId"]?.string,
                  let storedID = source["storedId"]?.string,
                  let agentID = source["profile"]?.string,
                  result[visibleID] == nil else { continue }
            result[visibleID] = SessionCoordinate(storedID: storedID, agentID: agentID)
        }
        return result
    }

    private static func displayText(_ value: String, maximumCharacters: Int) -> String {
        let allowedControls = CharacterSet(charactersIn: "\n\r\t")
        let disallowedControls = CharacterSet.controlCharacters.subtracting(allowedControls)
        let scalars = value.unicodeScalars.map { scalar in
            disallowedControls.contains(scalar) ? UnicodeScalar(0xFFFD)! : scalar
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
        return String(sanitized.prefix(maximumCharacters))
    }

    private static func timestamp() -> Int { Int(Date().timeIntervalSince1970) }
}

private actor Connection {
    struct VoiceResult {
        let data: Data
        let mimeType: String
    }

    private let task: URLSessionWebSocketTask
    private let credentials: LoopdyLinkRuntimeCredentials
    private let cipher: LoopdyLinkAccountCipher
    private var outboundSequence: Int
    private let lastInboundFrameID: String?
    private var lastReceivedSequence: Int
    private var senderSequences: [String: Int] = [:]

    private init(
        task: URLSessionWebSocketTask,
        credentials: LoopdyLinkRuntimeCredentials,
        ready: WatchLinkSocketReady
    ) throws {
        self.task = task
        self.credentials = credentials
        cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        outboundSequence = ready.lastInboundSequence
        lastInboundFrameID = ready.lastInboundFrameID
        lastReceivedSequence = ready.lastAcknowledgedSequence
    }

    static func open(
        baseURL: URL,
        credentials: LoopdyLinkRuntimeCredentials,
        session: URLSession
    ) async throws -> Connection {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil else {
            throw WatchDirectLinkClient.ClientError.invalidConfiguration
        }
        components.scheme = "wss"
        components.path = "/v1/socket"
        guard let url = components.url else {
            throw WatchDirectLinkClient.ClientError.invalidConfiguration
        }
        let signed = try credentials.signer.headers(method: "GET", path: "/v1/socket", body: "")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        signed.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("socket-ready-v1", forHTTPHeaderField: "x-loopdy-capabilities")
        let task = session.webSocketTask(with: request)
        task.resume()
        let first = try await Self.receive(task, timeoutNanoseconds: 20_000_000_000)
        let text = try Self.text(first)
        guard text.utf8.count <= 65_536,
              Self.messageType(text) == "socket.ready",
              let data = text.data(using: .utf8) else {
            task.cancel(with: .protocolError, reason: nil)
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        let ready = try JSONDecoder().decode(WatchLinkSocketReady.self, from: data)
        guard ready.deviceID == credentials.deviceID,
              ready.authorizationEpoch == credentials.authorizationEpoch else {
            task.cancel(with: .policyViolation, reason: nil)
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        return try Connection(task: task, credentials: credentials, ready: ready)
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func send<Value: Encodable>(_ payload: Value) async throws {
        try await sendPrepared(prepare(payload))
    }

    func prepare<Value: Encodable>(_ payload: Value) throws -> String {
        let frame = WatchLinkEncryptedFrame(
            version: 1,
            type: "frame",
            id: "watch-frame-" + UUID().uuidString.lowercased(),
            senderDeviceID: credentials.deviceID,
            senderEpoch: credentials.authorizationEpoch,
            sequence: outboundSequence + 1,
            ack: lastReceivedSequence,
            ciphertext: try cipher.seal(payload)
        )
        let data = try JSONEncoder().encode(frame)
        return String(decoding: data, as: UTF8.self)
    }

    func reconcileAndSendPending(
        _ wire: String
    ) async throws -> WatchPendingFrameReconciliation.Disposition {
        guard wire.utf8.count <= 4_000_000,
              let data = wire.data(using: .utf8) else {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        let frame = try JSONDecoder().decode(WatchLinkEncryptedFrame.self, from: data)
        guard frame.senderDeviceID == credentials.deviceID,
              frame.senderEpoch == credentials.authorizationEpoch,
              frame.sequence > 0 else {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        let disposition: WatchPendingFrameReconciliation.Disposition
        do {
            disposition = try WatchPendingFrameReconciliation.disposition(
                pendingSequence: frame.sequence,
                pendingFrameID: frame.id,
                serverSequence: outboundSequence,
                serverFrameID: lastInboundFrameID
            )
        } catch {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        guard disposition == .send else { return disposition }
        try await task.send(.string(wire))
        outboundSequence = frame.sequence
        return .send
    }

    func sendPrepared(_ wire: String) async throws {
        guard wire.utf8.count <= 4_000_000,
              let data = wire.data(using: .utf8) else {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        let frame = try JSONDecoder().decode(WatchLinkEncryptedFrame.self, from: data)
        guard frame.senderDeviceID == credentials.deviceID,
              frame.senderEpoch == credentials.authorizationEpoch,
              frame.sequence == outboundSequence + 1 else {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        try await task.send(.string(wire))
        outboundSequence = frame.sequence
    }

    func waitForWorkspace(requestID: String, operation: String) async throws -> [String: WatchLinkJSON] {
        while true {
            guard let payload = try await nextPayload() else { continue }
            if case .workspace(let result) = payload,
               result.requestID == requestID,
               result.operation == operation {
                guard result.version == 1,
                      result.type == "workspace.result",
                      result.sentAt > 0,
                      (result.code == nil) == (result.message == nil),
                      let encodedPayload = try? JSONEncoder().encode(result.payload),
                      encodedPayload.count <= 196_608 else {
                    throw WatchDirectLinkClient.ClientError.invalidResponse
                }
                guard result.status == "completed" else {
                    throw WatchDirectLinkClient.ClientError.requestFailed(
                        result.message ?? result.code ?? "Request failed"
                    )
                }
                return result.payload
            }
        }
    }

    func waitForAssistant(
        requestID: String,
        sessionID: String,
        agentID: String,
        turnID: String
    ) async throws -> WatchLinkAssistantMessage {
        while true {
            guard let payload = try await nextPayload() else { continue }
            if case .assistant(let message) = payload,
               message.sessionID == sessionID,
               message.agentID == agentID,
               Self.matchesAssistant(message, requestID: requestID, turnID: turnID),
               message.delivery == "final" {
                guard message.version == 1,
                      message.type == "assistant.message",
                      !message.text.isEmpty,
                      message.text.utf8.count <= 1_000_000,
                      !message.agentName.isEmpty,
                      message.agentName.count <= 160,
                      message.sentAt > 0 else {
                    throw WatchDirectLinkClient.ClientError.invalidResponse
                }
                return message
            }
        }
    }

    private static func matchesAssistant(
        _ message: WatchLinkAssistantMessage,
        requestID: String,
        turnID: String
    ) -> Bool {
        if let responseRequestID = message.requestID {
            return responseRequestID == requestID
                && (message.turnID == nil || message.turnID == turnID)
        }
        if let responseTurnID = message.turnID {
            return responseTurnID == turnID
        }
        // A Connection owns one pending user turn. The caller has already
        // matched its session and agent, preserving the canonical legacy path.
        return true
    }

    func waitForVoice(
        requestID: String,
        sessionID: String,
        agentID: String
    ) async throws -> VoiceResult {
        var chunks: [Int: Data] = [:]
        var expectedCount: Int?
        var expectedBytes: Int?
        var expectedDigest: String?
        var mimeType: String?
        while true {
            guard let payload = try await nextPayload() else { continue }
            switch payload {
            case .voiceFailure(let failure)
                where failure.requestID == requestID
                    && failure.sessionID == sessionID
                    && failure.agentID == agentID:
                guard failure.version == 1,
                      failure.type == "voice.speak.error",
                      failure.sentAt > 0,
                      !failure.code.isEmpty,
                      !failure.message.isEmpty else {
                    throw WatchDirectLinkClient.ClientError.invalidResponse
                }
                throw WatchDirectLinkClient.ClientError.requestFailed(failure.message)
            case .voiceChunk(let chunk)
                where chunk.requestID == requestID
                    && chunk.sessionID == sessionID
                    && chunk.agentID == agentID:
                guard chunk.version == 1,
                      chunk.type == "voice.speak.chunk",
                      chunk.sentAt > 0,
                      chunk.count > 0, chunk.count <= 92,
                      chunk.index >= 0, chunk.index < chunk.count,
                      chunk.totalBytes > 0, chunk.totalBytes <= 8 * 1_024 * 1_024,
                      let data = try? LoopdyLinkBase64URL.decode(chunk.audio),
                      data.count <= 90 * 1_024 else {
                    throw WatchDirectLinkClient.ClientError.invalidResponse
                }
                expectedCount = expectedCount ?? chunk.count
                expectedBytes = expectedBytes ?? chunk.totalBytes
                expectedDigest = expectedDigest ?? chunk.sha256
                mimeType = mimeType ?? chunk.mimeType
                guard expectedCount == chunk.count,
                      expectedBytes == chunk.totalBytes,
                      expectedDigest == chunk.sha256,
                      mimeType == chunk.mimeType else {
                    throw WatchDirectLinkClient.ClientError.invalidResponse
                }
                chunks[chunk.index] = data
                if chunks.count == expectedCount {
                    let assembled = Data((0..<chunk.count).flatMap { chunks[$0] ?? Data() })
                    guard assembled.count == expectedBytes,
                          LoopdyLinkBase64URL.encode(Data(SHA256.hash(data: assembled))) == expectedDigest else {
                        throw WatchDirectLinkClient.ClientError.invalidResponse
                    }
                    return VoiceResult(data: assembled, mimeType: chunk.mimeType)
                }
            default:
                break
            }
        }
    }

    private func nextPayload() async throws -> WatchLinkInboundPayload? {
        let text = try Self.text(try await Self.receive(task, timeoutNanoseconds: 90_000_000_000))
        guard text.utf8.count <= 4_000_000 else {
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
        switch Self.messageType(text) {
        case "accepted":
            return nil
        case "frame":
            guard let data = text.data(using: .utf8) else {
                throw WatchDirectLinkClient.ClientError.invalidResponse
            }
            let frame = try JSONDecoder().decode(WatchLinkEncryptedFrame.self, from: data)
            guard (16...128).contains(frame.id.count),
                  (1...96).contains(frame.senderDeviceID.count),
                  (16...4_000_000).contains(frame.ciphertext.count),
                  frame.senderDeviceID != credentials.deviceID,
                  frame.senderEpoch > 0,
                  frame.sequence > 0,
                  frame.ack >= 0 else {
                throw WatchDirectLinkClient.ClientError.invalidResponse
            }
            let previous = senderSequences[frame.senderDeviceID] ?? 0
            if frame.sequence <= previous {
                try await sendReceipt(for: frame)
                return nil
            }
            guard previous == 0 || frame.sequence == previous + 1 else {
                throw WatchDirectLinkClient.ClientError.invalidResponse
            }
            let payload: WatchLinkInboundPayload = try cipher.open(frame.ciphertext)
            try await sendReceipt(for: frame)
            senderSequences[frame.senderDeviceID] = frame.sequence
            lastReceivedSequence = max(lastReceivedSequence, frame.sequence)
            return payload
        default:
            return nil
        }
    }

    private func sendReceipt(for frame: WatchLinkEncryptedFrame) async throws {
        let receipt = WatchLinkReceipt(
            deviceID: credentials.deviceID,
            frameID: frame.id,
            sourceDeviceID: frame.senderDeviceID,
            sequence: frame.sequence
        )
        let data = try JSONEncoder().encode(receipt)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func receive(
        _ task: URLSessionWebSocketTask,
        timeoutNanoseconds: UInt64
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw WatchDirectLinkClient.ClientError.disconnected
            }
            guard let message = try await group.next() else {
                throw WatchDirectLinkClient.ClientError.disconnected
            }
            group.cancelAll()
            return message
        }
    }

    private static func text(_ message: URLSessionWebSocketTask.Message) throws -> String {
        switch message {
        case .string(let value): return value
        case .data(let value):
            guard let text = String(data: value, encoding: .utf8) else {
                throw WatchDirectLinkClient.ClientError.invalidResponse
            }
            return text
        @unknown default:
            throw WatchDirectLinkClient.ClientError.invalidResponse
        }
    }

    private static func messageType(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["type"] as? String
    }
}
