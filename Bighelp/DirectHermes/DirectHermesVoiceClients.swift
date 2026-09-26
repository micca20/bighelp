import CryptoKit
import Foundation

/// A single-use close prepared from the active Direct connection before its
/// owner is retired. It deliberately owns only the immutable authority needed
/// for the allocated voice call and uses a fresh ephemeral HTTP session for
/// this fixed native route.
@MainActor
final class DirectHermesVoiceCloseCleanup {
    private enum Credential {
        case bearer(String)
        case session(String)
    }

    private let endpoint: DirectHermesEndpoint
    private let credential: Credential
    private let requestGuard: DirectHermesNativeRequestGuard
    private let owner: WorkspaceOwner
    private let body: [String: BighelpJSONValue]
    private var consumed = false

    init?(
        endpoint: DirectHermesEndpoint,
        authentication: DirectHermesStoredAuthentication,
        owner: WorkspaceOwner,
        nativeContextETag: String,
        agentID: String,
        sessionID: String,
        voiceID: String
    ) {
        guard owner.authority.kind == .direct,
              Self.validIdentifier(agentID), Self.validIdentifier(sessionID), Self.validIdentifier(voiceID),
              let requestGuard = try? DirectHermesNativeRequestGuard(etag: nativeContextETag) else {
            return nil
        }
        switch authentication {
        case .bearer(let accessToken, _, _):
            guard (try? DirectHermesSecretValidation.validate(accessToken)) != nil else { return nil }
            credential = .bearer(accessToken)
        case .legacyLoopbackToken(let token), .dashboardSession(let token, _):
            guard (try? DirectHermesSecretValidation.validate(token)) != nil else { return nil }
            credential = .session(token)
        }
        self.endpoint = endpoint
        self.owner = owner
        self.requestGuard = requestGuard
        body = [
            "agentId": .string(agentID),
            "sessionId": .string(sessionID),
            "voiceId": .string(voiceID),
        ]
    }

    /// Best effort by design: the allocated call may already be closed. The
    /// handle cannot refresh, persist, or retarget credentials and can run once.
    func close() async {
        guard !consumed else { return }
        consumed = true
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        do {
            let response: DirectHermesHTTP.Response
            switch credential {
            case .bearer(let token):
                response = try await http.send(
                    route: "/api/plugins/loopdy/native/voice/close", method: "POST", body: body,
                    bearer: token, maximumResponseBytes: 16_384, nativeGuard: requestGuard
                )
            case .session(let token):
                response = try await http.send(
                    route: "/api/plugins/loopdy/native/voice/close", method: "POST", body: body,
                    legacyToken: token, maximumResponseBytes: 16_384, nativeGuard: requestGuard
                )
            }
            guard (200...299).contains(response.http.statusCode),
                  response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID") == requestGuard.requestIDHeader,
                  response.http.value(forHTTPHeaderField: "ETag") == requestGuard.etag else { return }
        } catch {
            // Retirement must not re-open or retarget an owner to report a
            // best-effort cleanup failure.
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Native voice settings and synthesis use the authenticated workspace
/// transport. The transport owns the Hermes route mapping; this layer only
/// validates the bounded voice models and the returned audio envelope.
@MainActor
final class DirectHermesVoiceSettingsClient: VoiceSettingsClient {
    private let scope: DirectHermesCoreRequestScope

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
    }

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        let profile = try Self.profile(agentID)
        let state = try await read(profile: profile)
        return state.configuration
    }

    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        let profile = try Self.profile(agentID)
        guard ["openai", "elevenlabs"].contains(settings.providerID),
              Self.validText(settings.voiceID, maximum: 160),
              Self.validText(settings.expectedRevision, maximum: 256) else {
            throw VoiceSettingsError.invalidResponse
        }
        if let key = settings.apiKey {
            guard Self.validText(key, maximum: 4_096) else {
                throw VoiceSettingsError.invalidResponse
            }
        }
        let current = try await read(profile: profile)
        guard current.configuration.revision == settings.expectedRevision else {
            throw VoiceSettingsError.conflict
        }
        guard let selected = current.configuration.providers.first(where: { $0.id == settings.providerID }) else {
            throw VoiceSettingsError.invalidResponse
        }
        if current.configuration.providerID == settings.providerID,
           selected.voiceID == settings.voiceID, settings.apiKey == nil {
            return current.configuration
        }

        if let key = settings.apiKey {
            let keyName = settings.providerID == "openai" ? "VOICE_TOOLS_OPENAI_KEY" : "ELEVENLABS_API_KEY"
            let result = try await perform(.keysSet, profile: profile, payload: [
                "profile": .string(profile), "key": .string(keyName), "value": .string(key)
            ])
            guard result["ok"]?.boolean == true else { throw VoiceSettingsError.invalidResponse }
        }

        var tts: [String: BighelpJSONValue] = ["provider": .string(settings.providerID)]
        if settings.providerID == "openai" {
            var openAI: [String: BighelpJSONValue] = ["voice": .string(settings.voiceID)]
            // Clearing an inline key is the canonical writer's required step
            // before saving VOICE_TOOLS_OPENAI_KEY, otherwise config precedence
            // can continue to select the stale value.
            if settings.apiKey != nil { openAI["api_key"] = .string("") }
            tts["openai"] = .object(openAI)
        } else {
            tts["elevenlabs"] = .object(["voice_id": .string(settings.voiceID)])
        }
        let result = try await perform(.workspaceConfigSet, profile: profile, payload: [
            "profile": .string(profile), "config": .object(["tts": .object(tts)])
        ])
        guard result["ok"]?.boolean == true else { throw VoiceSettingsError.invalidResponse }

        let verified = try await read(profile: profile)
        guard verified.configuration.providerID == settings.providerID,
              let saved = verified.configuration.providers.first(where: { $0.id == settings.providerID }),
              saved.voiceID == settings.voiceID,
              settings.apiKey == nil || saved.apiKeyConfigured else {
            throw VoiceSettingsError.invalidResponse
        }
        return verified.configuration
    }

    private func perform(
        _ operation: WorkspaceOperation,
        profile: String,
        payload: [String: BighelpJSONValue]
    ) async throws -> [String: BighelpJSONValue] {
        do {
            try scope.require(.voiceOutput, profile: profile)
            return try await scope.perform(operation, payload)
        } catch let error as WorkspaceClientError {
            switch error {
            case .conflict:
                throw VoiceSettingsError.conflict
            case .unavailable(.unsupportedOperation), .unavailable(.pluginRequired),
                 .unavailable(.unsupportedHost), .unavailable(.hostRestartRequired):
                throw VoiceSettingsError.unsupported
            default:
                throw error
            }
        }
    }

    private struct ReadState {
        let configuration: VoiceSettingsConfiguration
    }

    private func read(profile: String) async throws -> ReadState {
        let config = try await perform(.workspaceConfigGet, profile: profile, payload: [
            "profile": .string(profile)
        ])
        let keys = try await perform(.keysList, profile: profile, payload: [
            "profile": .string(profile)
        ])
        return ReadState(configuration: try Self.configuration(
            config: config, keys: keys, agentID: profile
        ))
    }

    private static func profile(_ value: String) throws -> String {
        guard validText(value, maximum: 128) else { throw VoiceSettingsError.invalidResponse }
        do {
            return try DirectHermesCoreRequestScope.profile(value)
        } catch {
            throw VoiceSettingsError.invalidResponse
        }
    }

    private static func configuration(
        config: [String: BighelpJSONValue],
        keys: [String: BighelpJSONValue],
        agentID: String
    ) throws -> VoiceSettingsConfiguration {
        let tts = config["tts"]?.object ?? [:]
        let selected = normalizedProvider(tts["provider"]?.string)
        let providers = try providerIDs(selected).map { id in
            VoiceProviderConfiguration(
                id: id,
                title: title(for: id),
                voiceID: try voiceID(id, tts: tts),
                apiKeyConfigured: keyConfigured(id, tts: tts, keys: keys)
            )
        }
        let revisionInput: [String: BighelpJSONValue] = [
            "agentId": .string(agentID),
            "providerId": .string(selected),
            "providers": .array(providers.map { provider in
                .object([
                    "providerId": .string(provider.id),
                    "voiceId": .string(provider.voiceID),
                    "apiKeyConfigured": .boolean(provider.apiKeyConfigured),
                ])
            }),
        ]
        let bytes = try JSONEncoder.sorted.encode(BighelpJSONValue.object(revisionInput))
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return VoiceSettingsConfiguration(revision: revision, providerID: selected, providers: providers)
    }

    private static func providerIDs(_ selected: String) -> [String] {
        var result: [String] = []
        for id in [selected, "openai", "elevenlabs"] where !result.contains(id) { result.append(id) }
        return result
    }

    private static func normalizedProvider(_ value: String?) -> String {
        guard let value, validText(value, maximum: 64) else { return "edge" }
        let normalized = value.lowercased()
        guard normalized.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }) else {
            return "edge"
        }
        return normalized
    }

    private static func title(for provider: String) -> String {
        switch provider {
        case "openai": "OpenAI TTS"
        case "elevenlabs": "ElevenLabs"
        case "edge": "Microsoft Edge TTS"
        case "nous": "Nous Subscription"
        default: provider
        }
    }

    private static func voiceID(_ provider: String, tts: [String: BighelpJSONValue]) throws -> String {
        let sectionName: String
        let field: String
        switch provider {
        case "openai", "nous": sectionName = "openai"; field = "voice"
        case "elevenlabs": sectionName = "elevenlabs"; field = "voice_id"
        case "edge": sectionName = "edge"; field = "voice"
        default: sectionName = provider; field = "voice_id"
        }
        let value = tts[sectionName]?.object?[field]?.string
        let fallback: String
        switch provider {
        case "openai", "nous": fallback = "alloy"
        case "elevenlabs": fallback = "pNInz6obpgDQGcFmaJgB"
        case "edge": fallback = "en-US-AriaNeural"
        default: fallback = ""
        }
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        guard validText(result, maximum: 160, allowEmpty: true) else { throw VoiceSettingsError.invalidResponse }
        return result
    }

    private static func keyConfigured(
        _ provider: String,
        tts: [String: BighelpJSONValue],
        keys: [String: BighelpJSONValue]
    ) -> Bool {
        if provider == "openai", let inline = tts["openai"]?.object?["api_key"]?.string,
           !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let names: [String]
        switch provider {
        case "openai": names = ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"]
        case "elevenlabs": names = ["ELEVENLABS_API_KEY"]
        default: names = []
        }
        return names.contains { keys[$0]?.object?["is_set"]?.boolean == true }
    }

    private static func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum DirectHermesVoiceError: Error, Equatable, Sendable {
    case invalidAudioResponse
}

@MainActor
final class DirectHermesVoiceSpeechOutput: VoiceSpeechOutput {
    private let scope: DirectHermesCoreRequestScope
    private let profileID: String
    private let playback: any VoiceAudioPlayback
    private var generation: UInt64 = 0

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        profileID: String,
        playback: any VoiceAudioPlayback = AVAudioPlayerVoicePlayback(),
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.profileID = profileID
        self.playback = playback
    }

    func speak(_ text: String, rate: Float) async throws {
        try await speak(text, rate: rate) { _ in }
    }

    func speak(
        _ text: String,
        rate: Float,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        // Hermes' public /api/audio/speak contract accepts text only; speed is
        // part of the host's resolved TTS configuration.
        _ = rate
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let profile = try DirectHermesCoreRequestScope.profile(profileID)
        try scope.require(.voiceOutput, profile: profile)
        generation &+= 1
        let ownedGeneration = generation
        playback.stop()

        let value = try await scope.perform(.voiceSpeak, [
            "profile": .string(profile),
            "text": .string(String(normalized.prefix(20_000))),
        ])
        try Task.checkCancellation()
        guard generation == ownedGeneration else { throw CancellationError() }
        let audio = try Self.audio(value)
        try await playback.play(audio.data, mimeType: audio.mimeType, onPlayback: onPlayback)
    }

    func stop() {
        generation &+= 1
        playback.stop()
    }

    private static func audio(_ value: [String: BighelpJSONValue]) throws -> (data: Data, mimeType: String) {
        guard value["ok"]?.boolean == true,
              let dataURL = value["data_url"]?.string,
              let comma = dataURL.firstIndex(of: ",") else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        let metadata = String(dataURL[..<comma])
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard metadata.hasPrefix("data:"), metadata.contains(";base64") else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        let rawMIME = String(metadata.dropFirst(5).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        let mimeType = rawMIME.lowercased()
        guard validMIME(mimeType),
              value["mime_type"]?.string?.lowercased() == mimeType,
              payload.utf8.count <= ((BighelpLinkVoiceAudioChunk.maximumAudioBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: payload),
              !data.isEmpty,
              data.count <= BighelpLinkVoiceAudioChunk.maximumAudioBytes else {
            throw DirectHermesVoiceError.invalidAudioResponse
        }
        return (data, mimeType)
    }

    private static func validMIME(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              value.hasPrefix("audio/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return String(value.dropFirst(6)).unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+-".contains(Character($0)))
        }
    }
}

@MainActor
final class DirectHermesVoiceSessionClient: VoiceSessionClient {
    private let conversation: DirectHermesConversationClient
    private let output: any VoiceSpeechOutput
    private let speechRate: () -> Float

    init(
        conversation: DirectHermesConversationClient,
        output: any VoiceSpeechOutput,
        speechRate: @escaping () -> Float
    ) {
        self.conversation = conversation
        self.output = output
        self.speechRate = speechRate
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        guard conversationID == conversation.conversationID else {
            throw WorkspaceClientError.ownerChanged
        }
        let response = try await conversation.sendForVoice(message: transcript)
        guard let item = response.items.last(where: { item in
            guard item.role == .assistant, case .message(let text) = item.content else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), case .message(let text) = item.content else {
            throw VoiceSessionError.emptyResponse
        }
        onDraft(text)
        return VoiceAgentReply(speaker: item.sender.snapshot.name, text: text, timelineItems: response.items)
    }

    func steer(_ transcript: String, conversationID: String) async throws {
        _ = try await conversation.sendMidSession(
            message: transcript,
            attachments: [],
            conversationID: conversationID,
            behavior: .steer,
            onDraft: { _ in }
        )
    }

    func speak(_ text: String) async throws {
        try await output.speak(text, rate: speechRate())
    }

    func speak(
        _ text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws {
        try await output.speak(text, rate: speechRate(), onPlayback: onPlayback)
    }

    func stopSpeaking() {
        output.stop()
    }

    func endSession(conversationID: String) async throws {
        output.stop()
    }
}
