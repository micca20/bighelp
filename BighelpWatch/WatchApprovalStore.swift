import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class WatchApprovalStore: NSObject {
    enum State: Equatable {
        case waiting
        case request(WatchApprovalRequest)
        case review(WatchApprovalRequest, WatchApprovalDecision)
        case submitting(WatchApprovalRequest, WatchApprovalDecision)
        case succeeded(WatchApprovalDecision)
        case failed(WatchApprovalRequest, WatchApprovalDecision, String)
    }

    private(set) var state: State = .waiting
    private let session: WCSession
    private let usesFixture: Bool
    private var activeAttempt: WatchApprovalAttempt?

    init(session: WCSession = .default, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.session = session
        #if DEBUG
        usesFixture = arguments.contains("-watch-approval-fixture")
            || arguments.contains("-watch-approval-fixture-state")
        #else
        usesFixture = false
        #endif
        super.init()

        #if DEBUG
        if let fixtureState = Self.fixtureState(arguments) {
            state = fixtureState
            return
        }
        if usesFixture {
            state = .request(Self.fixture)
            return
        }
        #endif

        session.delegate = self
        session.activate()
        receive(update: try? WatchApprovalCodec.decodeContextUpdate(session.receivedApplicationContext))
    }

    func choose(_ decision: WatchApprovalDecision) {
        guard case .request(let request) = state,
              request.allowedDecisions.contains(decision)
        else { return }
        if WatchApprovalConfirmationPolicy.requiresConfirmation(for: decision) {
            state = .review(request, decision)
        } else {
            submit(request: request, decision: decision)
        }
    }

    func cancelReview() {
        guard case .review(let request, _) = state else { return }
        state = .request(request)
    }

    func confirm() {
        guard case .review(let request, let decision) = state else { return }
        submit(request: request, decision: decision)
    }

    func retry() {
        guard case .failed(let request, let decision, _) = state else { return }
        submit(request: request, decision: decision)
    }

    private func submit(request: WatchApprovalRequest, decision: WatchApprovalDecision) {
        state = .submitting(request, decision)

        #if DEBUG
        if usesFixture {
            state = .succeeded(decision)
            return
        }
        #endif

        guard session.isReachable else {
            state = .failed(request, decision, "Open bighelp on your iPhone and try again.")
            return
        }
        let decisionMessage = WatchApprovalDecisionMessage(
            requestID: request.requestID,
            decision: decision,
            attemptID: UUID().uuidString
        )
        let attempt = WatchApprovalAttempt(
            requestID: decisionMessage.requestID,
            decision: decisionMessage.decision,
            attemptID: decisionMessage.attemptID
        )
        activeAttempt = attempt
        guard let payload = try? WatchApprovalCodec.encodeDecisionMessage(decisionMessage) else {
            activeAttempt = nil
            state = .failed(request, decision, "Approval could not be sent. Try again.")
            return
        }
        session.sendMessage(payload) { [weak self] reply in
            Task { @MainActor in
                self?.receive(
                    reply: reply,
                    request: request,
                    decision: decision,
                    attempt: attempt
                )
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard self?.activeAttempt == attempt else { return }
                self?.activeAttempt = nil
                self?.state = .failed(
                    request,
                    decision,
                    "Approval could not be confirmed. Try again."
                )
            }
        }
    }

    private func receive(
        reply: [String: Any],
        request: WatchApprovalRequest,
        decision: WatchApprovalDecision,
        attempt: WatchApprovalAttempt
    ) {
        guard activeAttempt == attempt else { return }
        activeAttempt = nil
        guard let result = try? WatchApprovalCodec.decodeDecisionResult(reply) else {
            state = .failed(request, decision, "Approval could not be confirmed. Try again.")
            return
        }
        switch result {
        case .succeeded(let requestID, let resolvedDecision)
            where requestID == request.requestID && resolvedDecision == decision:
            state = .succeeded(decision)
        case .failed(let requestID, let failedDecision, let message)
            where requestID == request.requestID && failedDecision == decision:
            state = .failed(request, decision, message)
        default:
            state = .failed(request, decision, "Approval could not be confirmed. Try again.")
        }
    }

    private func receive(update: WatchApprovalContextUpdate?) {
        guard let update else { return }
        activeAttempt = nil
        switch update {
        case .request(let request):
            state = .request(request)
        case .clear:
            state = .waiting
        }
    }

    #if DEBUG
    private static func fixtureState(_ arguments: [String]) -> State? {
        guard let flagIndex = arguments.firstIndex(of: "-watch-approval-fixture-state"),
              arguments.indices.contains(flagIndex + 1)
        else { return nil }
        return switch arguments[flagIndex + 1] {
        case "waiting": .waiting
        case "long-request": .request(longFixture)
        case "review-session": .review(fixture, .session)
        case "review-always": .review(fixture, .always)
        case "submitting-once": .submitting(fixture, .once)
        case "submitting-deny": .submitting(fixture, .deny)
        case "success-once": .succeeded(.once)
        case "success-deny": .succeeded(.deny)
        case "failure": .failed(
            fixture,
            .session,
            "Approval could not be confirmed. Try again."
        )
        default: .request(fixture)
        }
    }

    static let fixture = WatchApprovalRequest(
        requestID: "watch-design-b-fixture",
        action: "Pay vendor invoice",
        requester: "Finance agent",
        vendor: "Northstar Office Supply",
        amount: "$2,480.00",
        dueDate: "Today",
        category: "Operations",
        consequence: "Sends payment from the connected business account.",
        allowedDecisions: [.once, .session, .always, .deny]
    )

    static let longFixture = WatchApprovalRequest(
        requestID: "watch-long-content-fixture",
        action: "Pay the quarterly facilities and equipment invoice for the downtown office renovation",
        requester: "Facilities procurement and finance automation agent",
        vendor: "Northstar Office Supply and Commercial Furnishings Incorporated",
        amount: "$248,000.00 from the connected operating account",
        dueDate: "Before 5:00 PM Central Time tomorrow",
        category: "Facilities, equipment, and capital improvements",
        consequence: "Sends a nonrefundable payment from the connected business account and authorizes the vendor to begin fulfilling the complete renovation order.",
        allowedDecisions: [.once, .session, .always, .deny]
    )
    #endif
}

extension WatchApprovalStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let update = try? WatchApprovalCodec.decodeContextUpdate(
            session.receivedApplicationContext
        )
        Task { @MainActor [weak self] in self?.receive(update: update) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let update = try? WatchApprovalCodec.decodeContextUpdate(applicationContext)
        Task { @MainActor [weak self] in self?.receive(update: update) }
    }
}
