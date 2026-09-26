import Foundation
import Observation

struct VoiceProviderConfiguration: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let voiceID: String
    let apiKeyConfigured: Bool
}

struct VoiceSettingsConfiguration: Equatable, Sendable {
    let revision: String
    let providerID: String
    let providers: [VoiceProviderConfiguration]
}

struct VoiceSettingsUpdate: Equatable, Sendable {
    let expectedRevision: String
    let providerID: String
    let voiceID: String
    let apiKey: String?
}

@MainActor
protocol VoiceSettingsClient: AnyObject {
    func load(agentID: String) async throws -> VoiceSettingsConfiguration
    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration
}

enum VoiceSettingsError: Error {
    case unavailable, unsupported, conflict, invalidResponse
}

@MainActor @Observable
final class VoiceSettingsStore {
    let agentID: String
    private(set) var providerID = ""
    var voiceID = "" { didSet { if voiceID != oldValue { edited() } } }
    var apiKey = "" { didSet { if apiKey != oldValue { edited() } } }
    private(set) var configuration: VoiceSettingsConfiguration?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var confirmation: String?
    @ObservationIgnored private let client: any VoiceSettingsClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool

    init(agentID: String, client: any VoiceSettingsClient,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.agentID = agentID
        self.client = client
        self.isCurrent = isCurrent
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var editRevision = 0

    var selectedProvider: VoiceProviderConfiguration? {
        configuration?.providers.first { $0.id == providerID }
    }

    var supportsEditing: Bool { ["openai", "elevenlabs"].contains(providerID) }

    var canSave: Bool {
        guard isCurrent(), !isLoading, !isSaving, let configuration,
              supportsEditing, let selectedProvider,
              !normalizedVoice.isEmpty, normalizedVoice.utf8.count <= 160,
              !normalizedVoice.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              normalizedKey.utf8.count <= 4096,
              !normalizedKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              selectedProvider.apiKeyConfigured || !normalizedKey.isEmpty else { return false }
        return providerID != configuration.providerID || normalizedVoice != selectedProvider.voiceID
            || !normalizedKey.isEmpty
    }

    func load() async {
        guard isCurrent(), !isSaving, !isLoading else { return }
        generation += 1
        let request = generation
        let edits = editRevision
        isLoading = true
        errorMessage = nil
        confirmation = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.load(agentID: agentID)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            configuration = value
            if editRevision == edits {
                providerID = value.providerID
                voiceID = selectedProvider?.voiceID ?? ""
                apiKey = ""
            }
        } catch {
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            errorMessage = message(for: error, saving: false)
        }
    }

    func selectProvider(_ id: String) {
        guard id != providerID, !isSaving, configuration?.providers.contains(where: { $0.id == id }) == true else { return }
        providerID = id
        voiceID = selectedProvider?.voiceID ?? ""
        apiKey = ""
        edited()
    }

    func save() async {
        guard canSave, let configuration else { return }
        let update = VoiceSettingsUpdate(expectedRevision: configuration.revision,
            providerID: providerID, voiceID: normalizedVoice,
            apiKey: normalizedKey.isEmpty ? nil : normalizedKey)
        let request = generation
        let edits = editRevision
        isSaving = true
        errorMessage = nil
        confirmation = nil
        defer { if generation == request { isSaving = false } }
        do {
            let value = try await client.update(agentID: agentID, settings: update)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            guard value.providerID == update.providerID,
                  let saved = value.providers.first(where: { $0.id == update.providerID }),
                  saved.voiceID == update.voiceID, saved.apiKeyConfigured else {
                throw VoiceSettingsError.invalidResponse
            }
            self.configuration = value
            if editRevision == edits {
                providerID = value.providerID
                voiceID = saved.voiceID
                apiKey = ""
                confirmation = "Voice settings saved."
            }
        } catch {
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            errorMessage = message(for: error, saving: true)
        }
    }

    func invalidate() {
        generation += 1
        configuration = nil
        providerID = ""
        voiceID = ""
        apiKey = ""
        isLoading = false
        isSaving = false
        errorMessage = nil
        confirmation = nil
    }

    func clearAPIKey() {
        // Privacy cleanup is not a new user edit. A save already in flight may
        // still confirm its accepted provider/voice after the secret is erased.
        let revision = editRevision
        apiKey = ""
        editRevision = revision
    }
    private var normalizedVoice: String { voiceID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func edited() {
        editRevision += 1
        confirmation = nil
    }
    private func message(for error: any Error, saving: Bool) -> String {
        switch error {
        case VoiceSettingsError.unsupported:
            "Update the Loopdy plugin on this host to edit voice settings."
        case VoiceSettingsError.conflict:
            "Voice settings changed on the host. Reload them before saving again."
        default:
            saving ? "Voice settings could not be saved. Your edits are still here."
                : "Voice settings could not be loaded. Try again when the host is connected."
        }
    }
}
