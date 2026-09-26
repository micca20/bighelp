import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class VoiceConfigurationRecordingController {
    enum Source: Equatable {
        case microphone
        case importedFile

        var title: String {
            switch self {
            case .microphone: "Recorded audio"
            case .importedFile: "Imported audio"
            }
        }
    }

    enum State: Equatable {
        case idle
        case requestingPermission
        case recording(startedAt: Date)
        case importing
        case finalized(source: Source, duration: TimeInterval, byteCount: Int)
    }

    static let maximumDuration: TimeInterval = 120
    static let maximumBytes = DirectHermesVoiceRecording.maximumHostBytes

    private(set) var state: State = .idle
    private(set) var errorMessage: String?

    let permissionCenter: PermissionCenter

    @ObservationIgnored private let sessionCoordinator: VoiceAudioSessionCoordinator
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var sessionClaim: VoiceAudioSessionClaim?
    @ObservationIgnored private var activeURL: URL?
    @ObservationIgnored private var sizeMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var finalizedRecordingValue: DirectHermesVoiceRecording?
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var recorderDelegate: VoiceConfigurationAudioRecorderDelegate?

    init(
        permissionCenter: PermissionCenter,
        sessionCoordinator: VoiceAudioSessionCoordinator = .shared,
        fileManager: FileManager = .default
    ) {
        self.permissionCenter = permissionCenter
        self.sessionCoordinator = sessionCoordinator
        self.fileManager = fileManager
        recorderDelegate = VoiceConfigurationAudioRecorderDelegate(
            onFinish: { [weak self] recorder, succeeded in
                self?.recordingDidFinish(recorder, successfully: succeeded)
            },
            onEncodeError: { [weak self] recorder, error in
                self?.recordingDidFail(recorder, error: error)
            }
        )
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .requestingPermission, .recording, .importing: true
        case .idle, .finalized: false
        }
    }

    var hasFinalizedRecording: Bool {
        finalizedRecordingValue != nil
    }


    var finalizedSummary: String? {
        guard case .finalized(let source, let duration, let byteCount) = state else { return nil }
        let seconds = max(1, Int(duration.rounded(.up)))
        return "\(source.title) · \(seconds)s · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
    }

    func startRecording() async {
        guard !isRetired, !isBusy else { return }
        let token = beginReplacement()
        state = .requestingPermission

        guard await permissionCenter.authorizeContextualAccess(.microphone) else {
            guard accepts(token) else { return }
            state = .idle
            errorMessage = "Microphone access is required to record. You can also import an audio file."
            return
        }
        guard accepts(token) else { return }

        do {
            let url = fileManager.temporaryDirectory
                .appendingPathComponent("loopdy-host-voice-\(UUID().uuidString.lowercased())")
                .appendingPathExtension("m4a")
            let claim = try sessionCoordinator.acquire()
            do {
                let recorder = try AVAudioRecorder(
                    url: url,
                    settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                )
                recorder.delegate = recorderDelegate
                recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maximumDuration) else {
                    throw RecordingError.couldNotStart
                }
                guard accepts(token) else {
                    recorder.delegate = nil
                    recorder.stop()
                    claim.release()
                    try? fileManager.removeItem(at: url)
                    return
                }
                self.recorder = recorder
                sessionClaim = claim
                activeURL = url
                state = .recording(startedAt: Date())
                startSizeMonitor(token: token)
            } catch {
                claim.release()
                try? fileManager.removeItem(at: url)
                throw error
            }
        } catch {
            guard accepts(token) else { return }
            abandonActiveRecording()
            state = .idle
            publish(error, fallback: "The microphone recording could not start.")
        }
    }

    func stopRecording() {
        guard !isRetired, case .recording = state,
              let recorder, let activeURL else { return }
        let token = generation
        let duration = recorder.currentTime
        self.recorder = nil
        recorder.delegate = nil
        recorder.stop()
        completeRecording(at: activeURL, duration: duration, token: token)
    }

    func cancel() {
        guard !isRetired else { return }
        generation = UUID()
        cancelImport()
        abandonActiveRecording()
        finalizedRecordingValue = nil
        errorMessage = nil
        state = .idle
    }


    func finalizedRecording() throws -> DirectHermesVoiceRecording {
        guard !isRetired, let finalizedRecordingValue else {
            throw RecordingError.noFinalizedRecording
        }
        return finalizedRecordingValue
    }

    func importRecording(from url: URL) {
        guard !isRetired, !isBusy else { return }
        let token = beginReplacement()
        state = .importing
        importTask = Task { @MainActor [weak self] in
            await self?.performImport(from: url, token: token)
        }
    }

    private func performImport(from url: URL, token: UUID) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            if generation == token { importTask = nil }
        }

        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentTypeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let fileSize = values.fileSize, fileSize > 0 else {
                throw RecordingError.unsupportedFile
            }
            guard values.contentType?.conforms(to: .audio) == true else {
                throw RecordingError.unsupportedFile
            }
            guard fileSize <= Self.maximumBytes else {
                throw RecordingError.fileTooLarge
            }
            guard let mimeType = Self.mimeType(for: url) else {
                throw RecordingError.unsupportedFile
            }

            let asset = AVURLAsset(url: url)
            async let loadedDuration = asset.load(.duration)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            let durationValue = try await loadedDuration
            let tracks = try await audioTracks
            let duration = durationValue.seconds
            guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
                throw RecordingError.invalidDuration
            }
            guard !tracks.isEmpty else { throw RecordingError.unsupportedFile }
            try Task.checkCancellation()
            guard accepts(token) else { return }

            let data = try Data(contentsOf: url)
            guard accepts(token) else { return }
            let recording = try DirectHermesVoiceRecording(bytes: data, mimeType: mimeType)
            finalizedRecordingValue = recording
            state = .finalized(source: .importedFile, duration: duration, byteCount: data.count)
            errorMessage = nil
        } catch {
            guard accepts(token), !(error is CancellationError) else { return }
            finalizedRecordingValue = nil
            state = .idle
            publish(error, fallback: "The selected audio file could not be imported.")
        }
    }

    /// Reusable cleanup for backgrounding. A later explicit gesture may record again.
    func cancelAndCleanUp() {
        guard !isRetired else { return }
        generation = UUID()
        cancelImport()
        abandonActiveRecording()
        finalizedRecordingValue = nil
        errorMessage = nil
        state = .idle
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        generation = UUID()
        cancelImport()
        abandonActiveRecording()
        finalizedRecordingValue = nil
        errorMessage = nil
        state = .idle
    }

    private func recordingDidFinish(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder, let activeURL else { return }
        let token = generation
        let duration = recorder.currentTime
        self.recorder = nil
        recorder.delegate = nil
        if flag {
            completeRecording(at: activeURL, duration: duration, token: token)
        } else {
            abandonActiveRecording()
            state = .idle
            errorMessage = "The recording ended before a usable audio file was finalized."
        }
    }

    private func recordingDidFail(_ recorder: AVAudioRecorder, error: (any Error)?) {
        guard recorder === self.recorder else { return }
        generation = UUID()
        abandonActiveRecording()
        state = .idle
        publish(error ?? RecordingError.couldNotFinalize, fallback: "The recording could not be finalized.")
    }

    private func beginReplacement() -> UUID {
        generation = UUID()
        cancelImport()
        abandonActiveRecording()
        finalizedRecordingValue = nil
        errorMessage = nil
        return generation
    }

    private func accepts(_ token: UUID) -> Bool {
        !isRetired && generation == token && !Task.isCancelled
    }

    private func startSizeMonitor(token: UUID) {
        sizeMonitorTask?.cancel()
        sizeMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, self.accepts(token), self.isRecording,
                      let url = self.activeURL else { return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size >= Self.maximumBytes {
                    self.stopRecording()
                    return
                }
            }
        }
    }

    private func completeRecording(at url: URL, duration: TimeInterval, token: UUID) {
        sizeMonitorTask?.cancel()
        sizeMonitorTask = nil
        sessionClaim?.release()
        sessionClaim = nil
        activeURL = nil
        defer { try? fileManager.removeItem(at: url) }

        do {
            guard accepts(token) else { return }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maximumBytes else { throw RecordingError.fileTooLarge }
            guard duration > 0, duration <= Self.maximumDuration + 0.5 else {
                throw RecordingError.invalidDuration
            }
            finalizedRecordingValue = try DirectHermesVoiceRecording(
                bytes: data,
                mimeType: "audio/mp4"
            )
            state = .finalized(source: .microphone, duration: duration, byteCount: data.count)
            errorMessage = nil
        } catch {
            guard accepts(token) else { return }
            finalizedRecordingValue = nil
            state = .idle
            publish(error, fallback: "The recording could not be finalized.")
        }
    }

    private func abandonActiveRecording() {
        sizeMonitorTask?.cancel()
        sizeMonitorTask = nil
        if let recorder {
            recorder.delegate = nil
            recorder.stop()
        }
        recorder = nil
        sessionClaim?.release()
        sessionClaim = nil
        if let activeURL { try? fileManager.removeItem(at: activeURL) }
        activeURL = nil
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
    }

    private func publish(_ error: any Error, fallback: String) {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription, !description.isEmpty {
            errorMessage = description
        } else {
            errorMessage = fallback
        }
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "aac": "audio/aac"
        case "flac": "audio/flac"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "mp4": "audio/mp4"
        case "ogg", "oga": "audio/ogg"
        case "wav", "wave": "audio/wav"
        case "webm": "audio/webm"
        default: nil
        }
    }
}

@MainActor
private final class VoiceConfigurationAudioRecorderDelegate:
    NSObject, @preconcurrency AVAudioRecorderDelegate
{
    private let onFinish: @MainActor (AVAudioRecorder, Bool) -> Void
    private let onEncodeError: @MainActor (AVAudioRecorder, (any Error)?) -> Void

    init(
        onFinish: @escaping @MainActor (AVAudioRecorder, Bool) -> Void,
        onEncodeError: @escaping @MainActor (AVAudioRecorder, (any Error)?) -> Void
    ) {
        self.onFinish = onFinish
        self.onEncodeError = onEncodeError
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish(recorder, flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        onEncodeError(recorder, error)
    }
}

private enum RecordingError: Error, LocalizedError {
    case couldNotStart
    case couldNotFinalize
    case noFinalizedRecording
    case unsupportedFile
    case fileTooLarge
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "The microphone recording could not start."
        case .couldNotFinalize:
            "The recording could not be finalized."
        case .noFinalizedRecording:
            "Record or import audio before transcribing."
        case .unsupportedFile:
            "Choose a supported audio file with a readable audio track."
        case .fileTooLarge:
            "Choose audio no larger than 25 MiB."
        case .invalidDuration:
            "Choose audio between one moment and two minutes long."
        }
    }
}
