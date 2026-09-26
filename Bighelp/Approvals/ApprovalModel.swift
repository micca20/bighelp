import Observation

@MainActor
@Observable
final class ApprovalModel {
    let request: ApprovalRequest
    let availableDecisions: [ApprovalDecision]
    private(set) var status: ApprovalStatus = .idle

    private let client: any ApprovalClient

    init(
        request: ApprovalRequest,
        allowedDecisions: Set<ApprovalDecision> = [.once, .deny],
        client: any ApprovalClient
    ) {
        self.request = request
        availableDecisions = ApprovalDecision.allCases.filter(allowedDecisions.contains)
        self.client = client
    }

    func submit(_ decision: ApprovalDecision) async {
        guard availableDecisions.contains(decision) else { return }
        switch status {
        case .idle, .failed:
            break
        case .pending, .resolved:
            return
        }

        status = .pending

        do {
            let receipt = try await client.submit(request: request, decision: decision)
            guard receipt.requestID == request.id else {
                status = .failed(Self.failureMessage)
                return
            }

            status = .resolved(receipt.decision)
        } catch {
            status = .failed(Self.failureMessage)
        }
    }

    private static let failureMessage = "Approval could not be confirmed. Try again."
}
