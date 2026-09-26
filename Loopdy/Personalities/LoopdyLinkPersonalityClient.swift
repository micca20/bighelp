import Foundation

private func loopdyLinkPersonalityRequestID() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = Data((0..<18).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    return "personality_" + LoopdyLinkBase64URL.encode(bytes)
}

@MainActor
protocol LoopdyLinkPersonalityMessaging: AnyObject {
    func requestPersonalityCatalog(
        _ request: LoopdyLinkPersonalityRequest
    ) async throws -> LoopdyLinkPersonalityCatalog
}

enum LoopdyLinkPersonalityClientError: Error, Equatable {
    case mismatchedResponse
}

@MainActor
final class LoopdyLinkPersonalityClient: PersonalityClient {
    private let messaging: any LoopdyLinkPersonalityMessaging
    private let now: () -> Date
    private let requestID: () -> String

    init(
        messaging: any LoopdyLinkPersonalityMessaging,
        now: @escaping () -> Date = Date.init,
        requestID: @escaping () -> String = loopdyLinkPersonalityRequestID
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
        let action: LoopdyLinkPersonalityRequest.Action = switch request.action {
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
        action: LoopdyLinkPersonalityRequest.Action,
        expectedRevision: Int?,
        name: String?,
        draft: PersonalityDraft?
    ) async throws -> PersonalityCatalog {
        let request = try LoopdyLinkPersonalityRequest(
            requestID: requestID(),
            action: action,
            expectedRevision: expectedRevision,
            name: name,
            draft: draft,
            sentAt: Int(now().timeIntervalSince1970)
        )
        let response = try await messaging.requestPersonalityCatalog(request)
        guard response.requestID == request.requestID else {
            throw LoopdyLinkPersonalityClientError.mismatchedResponse
        }
        return response.catalog
    }
}
