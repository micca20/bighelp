import Foundation

extension WatchApprovalDecision {
    init(_ decision: ApprovalDecision) {
        self = switch decision {
        case .once: .once
        case .session: .session
        case .always: .always
        case .deny: .deny
        }
    }
    var approvalDecision: ApprovalDecision {
        switch self {
        case .once: .once
        case .session: .session
        case .always: .always
        case .deny: .deny
        }
    }
}

extension WatchApprovalRequest {
    init(request: ApprovalRequest, allowedDecisions: Set<ApprovalDecision>) {
        self.init(
            requestID: request.id, action: request.action, requester: request.requester,
            vendor: request.vendor, amount: request.amount, dueDate: request.dueDate,
            category: request.category, consequence: request.consequence,
            allowedDecisions: ApprovalDecision.allCases.filter(allowedDecisions.contains)
                .map(WatchApprovalDecision.init),
            policy: request.sourceInvoice
        )
    }

    /// Presentation must be EXACT, not a truncated or stale permission prompt.
    func matches(_ loaded: LoadedApprovalRequest) -> Bool {
        var current = WatchApprovalRequest(request: loaded.request, allowedDecisions: loaded.allowedDecisions)
        current.expiresAt = expiresAt
        current.eventID = eventID
        current.sessionID = sessionID
        current.agentID = agentID
        return current == self
    }
}

@MainActor
final class WatchApprovalDecisionCoordinator {
    private let loader: any ApprovalRequestLoading
    private let client: any ApprovalClient
    private var offered: [String: WatchApprovalRequest] = [:]
    private var processed: Set<String> = []
    private var generation: UInt64 = 0

    init(loader: any ApprovalRequestLoading, client: any ApprovalClient) {
        self.loader = loader
        self.client = client
    }

    func publish(_ request: WatchApprovalRequest) {
        guard let request = try? request.validated() else { return }
        // Republishing is NOT permission to replay a previously consumed attempt.
        offered[request.requestID] = request
        if offered.count > 32 { offered = [request.requestID: request] }
    }

    func clear() {
        generation &+= 1
        offered.removeAll()
        processed.removeAll()
    }

    func handle(
        _ message: WatchApprovalDecisionMessage,
        revalidate: () -> Bool = { true }
    ) async -> WatchApprovalDecisionResult? {
        let currentGeneration = generation
        guard let message = try? message.validated(),
              let request = offered[message.requestID],
              request.allowedDecisions.contains(message.decision),
              request.expiresAt.map({ $0 > .now }) ?? true,
              processed.count < 256,
              processed.insert(message.attemptID).inserted,
              revalidate() else { return nil }
        do {
            // Production loader re-fetches pending status, event, sender, scopes and expiry;
            // production submit revalidates again and includes the server request digest.
            let loaded = try await loader.loadApproval(id: message.requestID)
            guard currentGeneration == generation, !Task.isCancelled, revalidate(),
                  request.expiresAt.map({ $0 > .now }) ?? true,
                  request.matches(loaded) else { return nil }
            let receipt = try await client.submit(request: loaded.request, decision: message.decision.approvalDecision)
            guard receipt.requestID == message.requestID,
                  receipt.decision == message.decision.approvalDecision else {
                throw WatchCompanionValidationError.invalidPayload
            }
            offered.removeValue(forKey: message.requestID)
            return .succeeded(requestID: message.requestID, decision: message.decision)
        } catch {
            return .failed(
                requestID: message.requestID, decision: message.decision,
                message: "Result not confirmed. Check this approval on iPhone before trying again."
            )
        }
    }
}
