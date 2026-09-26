import Foundation

enum BotModeFixtureError: Error, LocalizedError {
    case failedMember

    var errorDescription: String? { "Member turn failed" }
}

/// Standalone, transport-free orchestration fixture.
///
/// This runner exercises local orchestration in fixtures. Production Hermes
/// Bot Mode uses its official hosted-room groups contract through
/// BighelpLinkHermesBotModeClient. This fixture is not the bighelp Native engine.
@MainActor
final class BotModeFixtureClient: BotModeMemberTurnClient {
    private var responses: [String: Result<BotModeMemberTurnResult, BotModeFixtureError>]
    private(set) var requests: [BotModeMemberTurnRequest] = []

    init(responses: [String: Result<BotModeMemberTurnResult, BotModeFixtureError>] = [:]) {
        self.responses = responses
    }

    func setResponse(_ response: Result<BotModeMemberTurnResult, BotModeFixtureError>, for memberID: String) {
        responses[memberID] = response
    }

    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        requests.append(request)
        return try responses[request.memberID]?.get() ?? .pass
    }
}
