import Foundation
import Testing
@testable import Bighelp

struct WatchApprovalTransportTests {
    @Test func contextUpdatesDistinguishARequestFromAnExplicitClear() throws {
        let request = WatchApprovalRequest(
            requestID: "approval-42",
            action: "Pay invoice",
            requester: "Finance agent",
            vendor: "Acme",
            amount: "$42.00",
            dueDate: "Today",
            category: "Operations",
            consequence: "Sends payment",
            allowedDecisions: [.once, .deny]
        )

        #expect(
            try WatchApprovalCodec.decodeContextUpdate(
                WatchApprovalCodec.encodeRequestContext(request)
            ) == .request(request)
        )
        #expect(
            try WatchApprovalCodec.decodeContextUpdate(
                WatchApprovalCodec.encodeClearContext()
            ) == .clear
        )
        #expect(throws: WatchApprovalValidationError.self) {
            try WatchApprovalCodec.decodeContextUpdate(["unexpected": true])
        }
    }

    @Test func attemptIdentityRejectsLateRepliesFromAnOlderSubmission() {
        let current = WatchApprovalAttempt(
            requestID: "approval-42",
            decision: .once,
            attemptID: "attempt-new"
        )

        #expect(current.matches(requestID: "approval-42", decision: .once, attemptID: "attempt-new"))
        #expect(!current.matches(requestID: "approval-42", decision: .once, attemptID: "attempt-old"))
        #expect(!current.matches(requestID: "approval-other", decision: .once, attemptID: "attempt-new"))
    }

    @Test func requestRoundTripsThroughBoundedApplicationContext() throws {
        let request = WatchApprovalRequest(
            requestID: "approval-42",
            action: "Pay invoice",
            requester: "Finance agent",
            vendor: "Acme",
            amount: "$42.00",
            dueDate: "Today",
            category: "Operations",
            consequence: "Sends payment",
            allowedDecisions: [.once, .session, .always, .deny]
        )

        let context = try WatchApprovalCodec.encodeRequestContext(request)
        let decoded = try WatchApprovalCodec.decodeRequestContext(context)

        #expect(decoded == request)
        #expect(Set(context.keys) == [WatchApprovalCodec.payloadKey])
    }

    @Test func malformedAndOversizedRequestsAreRejected() throws {
        #expect(throws: WatchApprovalValidationError.self) {
            try WatchApprovalRequest(
                requestID: "",
                action: "Pay invoice",
                requester: "Agent",
                vendor: "Acme",
                amount: "$42",
                dueDate: "Today",
                category: "Operations",
                consequence: "Sends payment",
                allowedDecisions: [.once]
            ).validated()
        }

        #expect(throws: WatchApprovalValidationError.self) {
            try WatchApprovalRequest(
                requestID: "approval-42",
                action: String(repeating: "x", count: 241),
                requester: "Agent",
                vendor: "Acme",
                amount: "$42",
                dueDate: "Today",
                category: "Operations",
                consequence: "Sends payment",
                allowedDecisions: [.once]
            ).validated()
        }

        #expect(throws: (any Error).self) {
            try WatchApprovalCodec.decodeRequestContext(["unexpected": Data()])
        }
    }

    @Test func onlySessionAndAlwaysRequireASecondConfirmation() {
        #expect(!WatchApprovalConfirmationPolicy.requiresConfirmation(for: .once))
        #expect(WatchApprovalConfirmationPolicy.requiresConfirmation(for: .session))
        #expect(WatchApprovalConfirmationPolicy.requiresConfirmation(for: .always))
        #expect(!WatchApprovalConfirmationPolicy.requiresConfirmation(for: .deny))
    }

    @Test func decisionMessagesRoundTripWithoutExtraAuthority() throws {
        let message = WatchApprovalDecisionMessage(
            requestID: "approval-42",
            decision: .session,
            attemptID: "attempt-1"
        )
        let encoded = try WatchApprovalCodec.encodeDecisionMessage(message)

        #expect(try WatchApprovalCodec.decodeDecisionMessage(encoded) == message)
        #expect(Set(encoded.keys) == [WatchApprovalCodec.payloadKey])
    }
}

@MainActor
struct WatchApprovalCoordinatorTests {
    @Test func offeredDecisionReloadsExactRequestAndUsesExistingClient() async throws {
        let loader = WatchApprovalLoaderFixture(loaded: .init(
            request: .vendorFixture,
            allowedDecisions: [.once, .session, .deny]
        ))
        let client = WatchApprovalClientFixture()
        let coordinator = WatchApprovalDecisionCoordinator(loader: loader, client: client)
        let offered = WatchApprovalRequest(request: .vendorFixture, allowedDecisions: [.once, .session, .deny])
        coordinator.publish(offered)

        let result = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .session,
            attemptID: "attempt-1"
        ))

        #expect(loader.loadedIDs == [offered.requestID])
        #expect(client.submissions == [.session])
        #expect(result == .succeeded(requestID: offered.requestID, decision: .session))
    }

    @Test func unofferedMismatchedAndDuplicateMessagesNeverSubmit() async {
        let loader = WatchApprovalLoaderFixture(loaded: .init(
            request: .vendorFixture,
            allowedDecisions: [.once, .deny]
        ))
        let client = WatchApprovalClientFixture()
        let coordinator = WatchApprovalDecisionCoordinator(loader: loader, client: client)
        let offered = WatchApprovalRequest(request: .vendorFixture, allowedDecisions: [.once, .deny])
        coordinator.publish(offered)

        let unoffered = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .always,
            attemptID: "attempt-unoffered"
        ))
        let mismatch = await coordinator.handle(.init(
            requestID: "another-request",
            decision: .once,
            attemptID: "attempt-mismatch"
        ))
        let accepted = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .once,
            attemptID: "attempt-accepted"
        ))
        let duplicate = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .once,
            attemptID: "attempt-accepted"
        ))

        #expect(unoffered == nil)
        #expect(mismatch == nil)
        #expect(accepted != nil)
        #expect(duplicate == nil)
        #expect(client.submissions == [.once])
    }

    @Test func changedAuthorityFailsAndSubmissionFailureCanRetryWithNewAttempt() async {
        let loader = WatchApprovalLoaderFixture(loaded: .init(
            request: .vendorFixture,
            allowedDecisions: [.deny]
        ))
        let client = WatchApprovalClientFixture(results: [.failure(.offline), .success(())])
        let coordinator = WatchApprovalDecisionCoordinator(loader: loader, client: client)
        let offered = WatchApprovalRequest(request: .vendorFixture, allowedDecisions: [.once, .deny])
        coordinator.publish(offered)

        let staleAuthority = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .once,
            attemptID: "attempt-stale"
        ))
        #expect(staleAuthority == nil)
        #expect(client.submissions.isEmpty)

        loader.loaded = .init(request: .vendorFixture, allowedDecisions: [.once, .deny])
        let failed = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .once,
            attemptID: "attempt-failed"
        ))
        let retried = await coordinator.handle(.init(
            requestID: offered.requestID,
            decision: .once,
            attemptID: "attempt-retry"
        ))

        #expect(failed == .failed(requestID: offered.requestID, decision: .once, message: "Result not confirmed. Check this approval on iPhone before trying again."))
        #expect(retried == .succeeded(requestID: offered.requestID, decision: .once))
        #expect(client.submissions == [.once, .once])
    }
}

@MainActor
private final class WatchApprovalLoaderFixture: ApprovalRequestLoading {
    var loaded: LoadedApprovalRequest
    private(set) var loadedIDs: [String] = []

    init(loaded: LoadedApprovalRequest) {
        self.loaded = loaded
    }

    func loadApproval(id: String) async throws -> LoadedApprovalRequest {
        loadedIDs.append(id)
        return loaded
    }
}

@MainActor
private final class WatchApprovalClientFixture: ApprovalClient {
    enum Failure: Error { case offline }

    private(set) var submissions: [ApprovalDecision] = []
    private var results: [Result<Void, Failure>]

    init(results: [Result<Void, Failure>] = [.success(())]) {
        self.results = results
    }

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        submissions.append(decision)
        if !results.isEmpty {
            try results.removeFirst().get()
        }
        return ApprovalReceipt(requestID: request.id, decision: decision)
    }
}
