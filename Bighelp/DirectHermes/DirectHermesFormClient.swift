import Foundation

/// Submits one validated rich-form response through the selected host's
/// authenticated dashboard connection. Only the plugin's fixed form routes are
/// reachable; native clarification and approval requests stay on JSON-RPC.
@MainActor
final class DirectHermesFormClient {
    private struct ActionResponse {
        enum State: String, Equatable {
            case pending
            case success
            case error
        }

        let requestID: String
        let idempotencyKey: String
        let state: State
        let code: String
        let message: String
    }

    private let workspace: DirectHermesWorkspaceClient
    private let owner: WorkspaceOwner

    init(workspace: DirectHermesWorkspaceClient, owner: WorkspaceOwner) {
        self.workspace = workspace
        self.owner = owner
    }

    func submit(
        _ request: BighelpLinkGenerativeUIFormSubmission
    ) async throws -> BighelpLinkGenerativeUIFormResult {
        try checkOwner()
        guard request.submittedAt > 0,
              BighelpLinkGenerativeUIFormSubmission.accepts(
                requestID: request.requestID,
                sessionID: request.sessionID,
                profile: request.profile,
                values: request.values
              ) else {
            throw WorkspaceClientError.invalidRequest
        }

        let value: BighelpJSONValue
        do {
            value = try await workspace.submitGenerativeUIFormAction(
                request,
                owner: owner
            )
        } catch let error as WorkspaceClientError where error == .outcomeUnknown {
            return try await reconcileUnknown(request)
        }
        try checkOwner()
        do {
            let response = try Self.actionResponse(value)
            return try Self.submissionResult(response, request: request)
        } catch {
            // A malformed or uncorrelated 2xx response cannot prove that the
            // mutation failed. Read the fixed status route; never resubmit.
            return try await reconcileUnknown(request)
        }
    }

    private func reconcileUnknown(
        _ request: BighelpLinkGenerativeUIFormSubmission
    ) async throws -> BighelpLinkGenerativeUIFormResult {
        try checkOwner()
        let value: BighelpJSONValue
        do {
            value = try await workspace.generativeUIFormActionStatus(
                requestID: request.requestID,
                profile: request.profile,
                sessionID: request.sessionID,
                owner: owner
            )
        } catch {
            try checkOwner()
            if error is CancellationError { throw error }
            if let workspaceError = error as? WorkspaceClientError,
               workspaceError == .ownerChanged || workspaceError == .authenticationRequired {
                throw workspaceError
            }
            throw WorkspaceClientError.outcomeUnknown
        }
        try checkOwner()

        let response: ActionResponse
        do {
            response = try Self.actionResponse(value)
        } catch {
            throw WorkspaceClientError.outcomeUnknown
        }
        guard Self.sameBytes(response.requestID, request.requestID) else {
            throw WorkspaceClientError.outcomeUnknown
        }

        let expectedKey = request.idempotencyKey.uuidString.lowercased()
        switch (response.state, response.code) {
        case (.success, "accepted"):
            guard Self.sameBytes(response.idempotencyKey, expectedKey) else {
                throw WorkspaceClientError.outcomeUnknown
            }
            return try Self.result(response, request: request, idempotencyKey: expectedKey)
        case (.error, "already_consumed"):
            guard Self.sameBytes(response.idempotencyKey, expectedKey) else {
                throw WorkspaceClientError.outcomeUnknown
            }
            return try Self.result(response, request: request, idempotencyKey: expectedKey)
        case (.error, "request_not_found"),
             (.error, "request_expired"),
             (.error, "owner_mismatch"):
            guard response.idempotencyKey.isEmpty else {
                throw WorkspaceClientError.outcomeUnknown
            }
            return try Self.result(response, request: request, idempotencyKey: expectedKey)
        case (.pending, "accepted"):
            // Status observed no committed response. It cannot prove that the
            // original POST will not commit after this read, so keep it unknown.
            throw WorkspaceClientError.outcomeUnknown
        default:
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard owner.authority.kind == .direct, workspace.owner == owner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private static func submissionResult(
        _ response: ActionResponse,
        request: BighelpLinkGenerativeUIFormSubmission
    ) throws -> BighelpLinkGenerativeUIFormResult {
        let expectedKey = request.idempotencyKey.uuidString.lowercased()
        guard sameBytes(response.requestID, request.requestID),
              sameBytes(response.idempotencyKey, expectedKey),
              response.state != .pending else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return try result(response, request: request, idempotencyKey: expectedKey)
    }

    private static func actionResponse(_ value: BighelpJSONValue) throws -> ActionResponse {
        guard let object = value.object,
              Set(object.keys) == Set([
                "schema", "version", "request_id", "idempotency_key",
                "state", "code", "message",
              ]),
              object["schema"] == .string("loopdy.generative_ui.action_response"),
              object["version"] == .integer(2),
              let requestID = object["request_id"]?.string,
              requestID.count == 32,
              requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let idempotencyKey = object["idempotency_key"]?.string,
              let rawState = object["state"]?.string,
              let state = ActionResponse.State(rawValue: rawState),
              let code = object["code"]?.string,
              let message = object["message"]?.string,
              !message.isEmpty,
              message.count <= 160,
              !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.codes.contains(code) else {
            throw WorkspaceClientError.invalidResponse
        }
        if !idempotencyKey.isEmpty {
            guard let parsed = UUID(uuidString: idempotencyKey),
                  parsed.uuidString.lowercased() == idempotencyKey else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        guard (state == .success && code == "accepted")
                || (state == .pending && code == "accepted")
                || (state == .error && code != "accepted") else {
            throw WorkspaceClientError.invalidResponse
        }
        return ActionResponse(
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            state: state,
            code: code,
            message: message
        )
    }

    private static func result(
        _ response: ActionResponse,
        request: BighelpLinkGenerativeUIFormSubmission,
        idempotencyKey: String
    ) throws -> BighelpLinkGenerativeUIFormResult {
        let state = response.state == .success ? "success" : "error"
        let value = BighelpJSONValue.object([
            "version": .integer(1),
            "type": .string("generative.ui.form.result"),
            "requestId": .string(response.requestID),
            "sessionId": .string(request.sessionID),
            "idempotencyKey": .string(idempotencyKey),
            "state": .string(state),
            "code": .string(response.code),
            "message": .string(response.message),
            // The fixed HTTP response has no server timestamp. Retain the exact
            // submission timestamp instead of inventing a new correlation time.
            "sentAt": .integer(request.submittedAt),
        ])
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(BighelpLinkGenerativeUIFormResult.self, from: data)
        } catch {
            throw WorkspaceClientError.invalidResponse
        }
    }

    private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static let codes = Set([
        "accepted", "request_not_found", "request_expired", "owner_mismatch",
        "invalid_value", "already_submitted", "already_consumed",
        "idempotency_conflict", "payload_too_large", "internal_error",
    ])
}
