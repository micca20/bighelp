import SwiftUI

struct GenerativeUIFormSubmissionHandler: Sendable {
    let submit: @MainActor @Sendable (
        LoopdyLinkGenerativeUIFormSubmission
    ) async throws -> LoopdyLinkGenerativeUIFormResult
}

private struct GenerativeUIFormMessagingKey: EnvironmentKey {
    static let defaultValue: GenerativeUIFormSubmissionHandler? = nil
}

extension EnvironmentValues {
    var generativeUIFormMessaging: GenerativeUIFormSubmissionHandler? {
        get { self[GenerativeUIFormMessagingKey.self] }
        set { self[GenerativeUIFormMessagingKey.self] = newValue }
    }
}
