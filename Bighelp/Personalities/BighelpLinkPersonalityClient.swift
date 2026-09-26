import Foundation

private func bighelpLinkPersonalityRequestID() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = Data((0..<18).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    return "personality_" + BighelpLinkBase64URL.encode(bytes)
}

@MainActor
protocol BighelpLinkPersonalityMessaging: AnyObject {
    func requestPersonalityCatalog(
        _ request: BighelpLinkPersonalityRequest
    ) async throws -> BighelpLinkPersonalityCatalog
}

enum BighelpLinkPersonalityClientError: Error, Equatable {
    case mismatchedResponse
}

@MainActor
final class BighelpLinkPersonalityClient: PersonalityClient {
    private let messaging: any BighelpLinkPersonalityMessaging
    private let now: () -> Date
    private let requestID: () -> String

    init(
        messaging: any BighelpLinkPersonalityMessaging,
        now: @escaping () -> Date = Date.init,
        requestID: @escaping () -> String = bighelpLinkPersonalityRequestID
    ) {
        self.messaging = messaging
        self.now = now
        self.requestID = requestID
    }

    func load() async throws -> PersonalityCatalog {
        try await execute(
            action: .catalog,
            expectedRevision: nil,
            name: nil,
            draft: nil
        )
    }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        let action: BighelpLinkPersonalityRequest.Action = switch request.action {
        case .save: .save
        case .delete: .delete
        case .activate: .activate
        }
        return try await execute(
            action: action,
            expectedRevision: request.expectedRevision,
            name: request.name,
            draft: request.draft
        )
    }

    private func execute(
        action: BighelpLinkPersonalityRequest.Action,
        expectedRevision: Int?,
        name: String?,
        draft: PersonalityDraft?
    ) async throws -> PersonalityCatalog {
        let request = try BighelpLinkPersonalityRequest(
            requestID: requestID(),
            action: action,
            expectedRevision: expectedRevision,
            name: name,
            draft: draft,
            sentAt: Int(now().timeIntervalSince1970)
        )
        let response = try await messaging.requestPersonalityCatalog(request)
        guard response.requestID == request.requestID else {
            throw BighelpLinkPersonalityClientError.mismatchedResponse
        }
        return response.catalog
    }
}
