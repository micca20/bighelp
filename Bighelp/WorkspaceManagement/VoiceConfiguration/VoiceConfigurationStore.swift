import Foundation
import Observation

/// Injected recording presentations remain supported. Implementations must honor
/// task cancellation and clear any UI continuation they own when their surface retires.
typealias VoiceConfigurationRecordingSource = @MainActor () async throws -> DirectHermesVoiceRecording

@MainActor
@Observable
final class VoiceConfigurationStore {
    enum PlaybackState: Equatable {
        case idle
        case preparing
        case playing
    }

    let hostName: String
    let profileID: String

    private(set) var configuration: DirectHermesVoiceConfigurationSnapshot?
    private(set) var voiceCatalog = DirectHermesVoiceCatalog(
        isAvailable: false,
        voices: [],
        unavailableReason: nil
    )
    private(set) var stockLiveStatus: DirectHermesStockLiveVoiceStatus?
    private(set) var selectedProvider: DirectHermesSelectableVoiceProvider = .openAI
    var selectedVoiceID = ""
    var transcriptDraft = ""
    var playbackText = ""

    private(set) var isLoading = false
    private(set) var isSavingSelection = false
    private(set) var isTranscribing = false
    private(set) var playbackState: PlaybackState = .idle
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var isRetired = false

    @ObservationIgnored private let client: DirectHermesVoiceConfigurationClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        profileID: String,
        client: DirectHermesVoiceConfigurationClient,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool {
        !isRetired && isCurrent() && client.ownsScope
    }

    var canAct: Bool {
        ownsScope && !isLoading && !isSavingSelection && !isTranscribing
            && playbackState == .idle
    }

    var canSaveSelection: Bool {
        canAct && !normalizedVoiceID.isEmpty && normalizedVoiceID.utf8.count <= 160
            && !normalizedVoiceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var canTranscribe: Bool {
        canAct && configuration != nil
    }

    var canPlay: Bool {
        ownsScope && !isLoading && !isSavingSelection && !isTranscribing
            && playbackState == .idle && configuration != nil
            && !normalizedPlaybackText.isEmpty && normalizedPlaybackText.utf8.count <= 20_000
    }

    var supportsStreamingPlayback: Bool { client.supportsStreamingPlayback }
    var supportsFullRelayTranscription: Bool { client.supportsFullRelayTranscription }

    func refresh() async {
        guard ownsScope, !isLoading, !isSavingSelection, !isTranscribing,
              playbackState == .idle else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        noticeMessage = nil
        defer { if generation == token { isLoading = false } }

        do {
            let next = try await client.loadConfiguration(profileID: profileID)
            guard accepts(token) else {
                next.invalidate()
                return
            }
            replaceConfiguration(with: next)
        } catch {
            publish(error, token: token, fallback: "Hermes could not load its voice transport configuration.")
            return
        }

        do {
            if let selection = try await client.loadVoiceSelection(profileID: profileID), accepts(token) {
                selectedProvider = selection.provider
                selectedVoiceID = selection.voiceID
            } else if accepts(token) {
                seedSelectionFromResolvedConfiguration()
            }
        } catch {
            if accepts(token) {
                noticeMessage = "Voice transport loaded, but the saved voice selection could not be read."
            }
        }

        do {
            let catalog = try await client.listElevenLabsVoices(profileID: profileID)
            guard accepts(token) else { return }
            voiceCatalog = catalog
        } catch {
            guard accepts(token) else { return }
            voiceCatalog = .init(
                isAvailable: false,
                voices: [],
                unavailableReason: "Voice discovery is unavailable. The saved voice ID is unchanged."
            )
        }

        do {
            let status = try await client.loadStockLiveVoiceStatus(profileID: profileID)
            guard accepts(token) else { return }
            stockLiveStatus = status
        } catch {
            guard accepts(token) else { return }
            stockLiveStatus = nil
        }
    }

    func chooseProvider(_ provider: DirectHermesSelectableVoiceProvider) {
        guard ownsScope, !isSavingSelection, provider != selectedProvider else { return }
        selectedProvider = provider
        if provider == .elevenLabs,
           !voiceCatalog.voices.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = voiceCatalog.voices.first?.id ?? ""
        } else if provider == .openAI && selectedVoiceID.isEmpty {
            selectedVoiceID = "alloy"
        }
        noticeMessage = nil
        errorMessage = nil
    }

    func chooseVoice(_ voiceID: String) {
        guard ownsScope, !isSavingSelection else { return }
        selectedVoiceID = voiceID
        noticeMessage = nil
        errorMessage = nil
    }

    func saveSelection() async {
        guard canSaveSelection else { return }
        let token = generation
        isSavingSelection = true
        errorMessage = nil
        noticeMessage = nil
        defer { if generation == token { isSavingSelection = false } }
        do {
            let saved = try await client.selectVoice(
                profileID: profileID,
                selection: .init(provider: selectedProvider, voiceID: normalizedVoiceID)
            )
            guard accepts(token) else { return }
            selectedProvider = saved.provider
            selectedVoiceID = saved.voiceID
            let next = try await client.loadConfiguration(profileID: profileID)
            guard accepts(token) else {
                next.invalidate()
                return
            }
            replaceConfiguration(with: next)
            noticeMessage = "Saved and verified the host voice selection."
        } catch {
            publish(error, token: token, fallback: "Hermes did not confirm the voice selection. Refresh before trying again.")
        }
    }

    func transcribe(_ recording: DirectHermesVoiceRecording) async {
        await transcribeFrom { recording }
    }

    func transcribeFrom(_ source: VoiceConfigurationRecordingSource) async {
        guard canTranscribe else { return }
        let token = generation
        isTranscribing = true
        errorMessage = nil
        noticeMessage = nil
        defer { if generation == token { isTranscribing = false } }
        do {
            let recording = try await source()
            try Task.checkCancellation()
            guard accepts(token), let configuration, !configuration.isInvalidated else { return }
            let result = try await client.transcribe(
                profileID: profileID,
                recording: recording,
                configuration: configuration
            )
            guard accepts(token) else { return }
            transcriptDraft = result.text
            if result.text.isEmpty {
                noticeMessage = "No speech was detected. Nothing was inserted or sent."
            } else {
                noticeMessage = result.usedClientDirectTransport
                    ? "Transcribed directly with the host-selected provider. Review the text before using it."
                    : "Transcribed through the authenticated Hermes host. Review the text before using it."
            }
        } catch {
            publish(error, token: token, fallback: "The recording could not be transcribed. Nothing was sent.")
        }
    }

    func playPreview() async {
        guard canPlay, let configuration else { return }
        let token = generation
        let lease = DirectHermesTTSLease(purpose: .preview)
        playbackState = .preparing
        errorMessage = nil
        noticeMessage = nil

        let warmReceipt = try? await client.setTTSLease(
            profileID: profileID,
            lease: lease,
            active: true
        )
        guard accepts(token), !configuration.isInvalidated else {
            _ = try? await client.setTTSLease(profileID: profileID, lease: lease, active: false)
            if generation == token { playbackState = .idle }
            return
        }
        if warmReceipt?.failedToWarm == true {
            noticeMessage = "Hermes could not warm the speech engine; playback will still try the selected provider."
        }

        do {
            try await client.play(
                profileID: profileID,
                text: normalizedPlaybackText,
                configuration: configuration,
                onPlayback: { [weak self] event in
                    guard let self, self.accepts(token) else { return }
                    switch event {
                    case .started, .level:
                        self.playbackState = .playing
                    case .finished, .failed:
                        self.playbackState = .idle
                    }
                }
            )
            _ = try? await client.setTTSLease(profileID: profileID, lease: lease, active: false)
            guard accepts(token) else { return }
            playbackState = .idle
            noticeMessage = client.supportsStreamingPlayback
                ? "Playback finished."
                : "Buffered playback finished. Streaming needs the parent-owned audio WebSocket seam."
        } catch {
            _ = try? await client.setTTSLease(profileID: profileID, lease: lease, active: false)
            guard accepts(token) else { return }
            playbackState = .idle
            publish(error, token: token, fallback: "Hermes could not play this preview.")
        }
    }

    func stopPlayback() {
        guard ownsScope else { return }
        client.stopPlayback()
        playbackState = .idle
        noticeMessage = "Playback stopped."
    }

    func clearMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    /// Called when the scene leaves active state. Non-secret discovery may stay
    /// visible, but the credential-bearing client-direct snapshot is destroyed.
    func clearSensitiveConfiguration() {
        generation = UUID()
        configuration?.invalidate()
        configuration = nil
        client.stopPlayback()
        playbackState = .idle
        isLoading = false
        isSavingSelection = false
        isTranscribing = false
    }

    func retire() {
        isRetired = true
        generation = UUID()
        clearSensitiveConfiguration()
        transcriptDraft = ""
        playbackText = ""
        selectedVoiceID = ""
        isLoading = false
        isSavingSelection = false
        isTranscribing = false
        errorMessage = nil
        noticeMessage = nil
    }

    private var normalizedVoiceID: String {
        selectedVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPlaybackText: String {
        playbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func seedSelectionFromResolvedConfiguration() {
        guard let configuration,
              case .direct(let resolved) = configuration.textToSpeech,
              let provider = DirectHermesSelectableVoiceProvider(rawValue: resolved.providerID),
              let voiceID = resolved.voiceID, !voiceID.isEmpty else { return }
        selectedProvider = provider
        selectedVoiceID = voiceID
    }

    private func replaceConfiguration(with next: DirectHermesVoiceConfigurationSnapshot) {
        if configuration !== next { configuration?.invalidate() }
        configuration = next
    }

    private func accepts(_ token: UUID) -> Bool {
        generation == token && ownsScope && !Task.isCancelled
    }

    private func publish(_ error: any Error, token: UUID, fallback: String) {
        guard accepts(token), !(error is CancellationError) else { return }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription, !description.isEmpty {
            errorMessage = description
        } else {
            errorMessage = fallback
        }
    }
}
