import Foundation

enum ApprovalFixtureFailure: Error {
    case unavailable
}

@MainActor
struct ApprovalFixtureClient: ApprovalClient {
    enum Outcome {
        case confirmRequestedDecision
        case fail
    }

    let outcome: Outcome
    let confirmationDelay: Duration

    init(
        outcome: Outcome = .confirmRequestedDecision,
        confirmationDelay: Duration = .milliseconds(420)
    ) {
        self.outcome = outcome
        self.confirmationDelay = confirmationDelay
    }

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        try await Task.sleep(for: confirmationDelay)

        switch outcome {
        case .confirmRequestedDecision:
            return ApprovalReceipt(requestID: request.id, decision: decision)
        case .fail:
            throw ApprovalFixtureFailure.unavailable
        }
    }
}

extension ApprovalReceipt {
    static let approvedFixture = ApprovalReceipt(
        requestID: ApprovalRequest.vendorFixture.id,
        decision: .approve
    )

    static let declinedFixture = ApprovalReceipt(
        requestID: ApprovalRequest.vendorFixture.id,
        decision: .decline
    )
}
