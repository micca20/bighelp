import Foundation

// Shared session/picker and injected fixture contracts, not a chat transport.
enum LoopdyLinkLiveSocketError: Error, Equatable, LocalizedError {
    case signedOut
    case busy
    case timedOut
    case disconnected
    case binaryMessage
    case stopped
    case interrupted
    case invalidVoiceResponse
    case voiceUnavailable
    case invalidPickerResponse
    case pickerOpenFailed(message: String)
    case invalidCommandCatalogResponse
    case requestFailed(code: String, message: String)
    case hostUpdateRequired
    case directHostSetupRequired

    var errorDescription: String? {
        switch self {
        case .pickerOpenFailed(let message): return message
        case .requestFailed(_, let message): return message
        case .hostUpdateRequired:
            return "Update the Loopdy plugin on this Hermes host to use this feature, then reconnect."
        case .directHostSetupRequired:
            return "Direct connection is unavailable on this host. Check Direct settings and connection status in the host’s Loopdy plugin, then reconnect."
        default: return nil
        }
    }
}

enum LoopdyLinkLiveSocketState: Equatable, Sendable {
    case stopped
    case connecting
    case verified
    case retrying
    case superseded
}

struct LoopdyLinkVoiceAudio: Equatable, Sendable {
    let audio: Data
    let mimeType: String
    let provider: String
}

@MainActor
protocol LoopdyLinkVoiceMessaging: AnyObject {
    func synthesize(_ request: LoopdyLinkVoiceSpeakRequest) async throws -> LoopdyLinkVoiceAudio
}

@MainActor
protocol LoopdyLinkSessionControlMessaging: AnyObject {
    func openPicker(_ request: LoopdyLinkPickerOpenRequest) async throws -> LoopdyLinkPicker
    func selectPicker(_ selection: LoopdyLinkPickerSelection) async throws -> LoopdyLinkPickerResult
}

@MainActor
protocol LoopdyLinkSessionForkMessaging: AnyObject {
    func forkSession(
        _ request: LoopdyLinkSessionForkRequest
    ) async throws -> LoopdyLinkSessionForkResult
}

@MainActor
protocol LoopdyLinkSlashCommandCatalogMessaging: AnyObject {
    func loadSlashCommandCatalog(
        _ request: LoopdyLinkSlashCommandCatalogRequest
    ) async throws -> LoopdyLinkSlashCommandCatalog
}

@MainActor
protocol LoopdyLinkGenerativeUIFormMessaging: AnyObject {
    func submitGenerativeUIForm(
        _ request: LoopdyLinkGenerativeUIFormSubmission
    ) async throws -> LoopdyLinkGenerativeUIFormResult
}

@MainActor
protocol LoopdyLinkWorkspaceMessaging: AnyObject {
    var workspaceOwnerIdentity: String { get }
    func prepareSessionStateSupport() async throws -> Bool
    func performWorkspaceRequest(
        _ request: LoopdyLinkWorkspaceRequest
    ) async throws -> LoopdyLinkWorkspaceResult
    func performPreparedWorkspaceRequest(
        _ request: LoopdyLinkWorkspaceRequest
    ) async throws -> LoopdyLinkWorkspaceResult
}

extension LoopdyLinkWorkspaceMessaging {
    var workspaceOwnerIdentity: String { "legacy-provider" }
    func prepareSessionStateSupport() async throws -> Bool { false }
    /// Injected compatibility clients retain their explicitly supplied request path.
    func performPreparedWorkspaceRequest(
        _ request: LoopdyLinkWorkspaceRequest
    ) async throws -> LoopdyLinkWorkspaceResult {
        try await performWorkspaceRequest(request)
    }
}

enum LoopdyLinkConversationError: Error, Equatable {
    case invalidMessage
    case mismatchedSession
}

enum LoopdyLinkSessionForkError: Error, Equatable {
    case rejected
    case mismatchedResult
}

enum LoopdyLinkSlashCommandCatalogError: Error, Equatable {
    case mismatchedResult
}

@MainActor
protocol LoopdyLinkChatMessaging: AnyObject {
    func submit(_ message: LoopdyLinkUserMessage) async throws

    func send(
        _ message: LoopdyLinkUserMessage,
        onEvent: @escaping (LoopdyLinkAssistantMessage) -> Void
    ) async throws -> LoopdyLinkAssistantMessage
}

@MainActor
protocol LoopdyLinkInactiveSessionReconciliationMessaging: AnyObject {
    func reconcileInactiveSession(conversationID: String)
}

extension LoopdyLinkChatMessaging {
    func submit(_ message: LoopdyLinkUserMessage) async throws {
        _ = try await send(message, onEvent: { _ in })
    }
}

@MainActor
protocol LoopdyLinkAttachmentMessaging: AnyObject {
    func uploadAttachmentChunks(_ chunks: [LoopdyLinkAttachmentChunk]) async throws
}
