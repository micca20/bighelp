import AVFoundation
import Foundation
import Speech

enum VoiceInputLevelError: Error, Equatable, Sendable {
    case permissionDenied
    case noInputAvailable
    case engineFailed
    case interrupted
    case speechPermissionDenied
    case speechUnavailable
}

enum VoiceAuthorizationBridge {
    static func value<Result: Sendable>(
        _ request: @escaping @Sendable (@escaping @Sendable (Result) -> Void) -> Void
    ) async -> Result {
        await withCheckedContinuation { continuation in
            request { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// Requires both sustained foreground audio and progressive recognized speech
/// before playback can be interrupted. Either signal alone is treated as noise.
@MainActor
final class VoiceBargeInDetector {
    private let activityThreshold: Float
    private let requiredActiveSamples: Int
    private var activeSamples = 0
    private var previousTranscript = ""
    private var spokenText = ""

    init(activityThreshold: Float = 0.14, requiredActiveSamples: Int = 8) {
        self.activityThreshold = activityThreshold
        self.requiredActiveSamples = requiredActiveSamples
    }

    func begin(spokenText: String) {
        reset()
        self.spokenText = Self.normalized(spokenText)
    }

    func receiveLevel(_ level: Float) {
        if level >= activityThreshold {
            activeSamples = min(activeSamples + 1, requiredActiveSamples * 2)
        } else {
            activeSamples = max(activeSamples - 2, 0)
        }
    }

    func receiveTranscript(_ text: String, isFinal: Bool) -> Bool {
        let candidate = Self.normalized(text)
        defer { previousTranscript = candidate }
        guard activeSamples >= requiredActiveSamples,
              Self.hasMeaningfulPhrase(candidate),
              !Self.isLikelyEcho(candidate, of: spokenText)
        else { return false }
        if isFinal { return true }
        guard !previousTranscript.isEmpty,
              candidate != previousTranscript,
              candidate.hasPrefix(previousTranscript)
        else { return false }
        return true
    }

    func reset() {
        activeSamples = 0
        previousTranscript = ""
        spokenText = ""
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func hasMeaningfulPhrase(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count >= 2 && words.joined().count >= 6
    }

    private static func isLikelyEcho(_ candidate: String, of spokenText: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if spokenText.contains(candidate) { return true }
        let spokenWords = Set(spokenText.split(separator: " "))
        let candidateWords = candidate.split(separator: " ")
        guard !candidateWords.isEmpty else { return false }
        let overlap = candidateWords.filter { spokenWords.contains($0) }.count
        return Double(overlap) / Double(candidateWords.count) >= 0.7
    }
}

/// Ends a recognized utterance after sustained quiet audio. A transcript must
/// exist before quiet can finish a turn, so room tone before the user speaks is
/// never treated as an empty utterance.
@MainActor
final class VoiceEndOfSpeechDetector {
    private let silenceDuration: Duration
    private let activityThreshold: Float
    private let onEndOfSpeech: () -> Void
    private var hasRecognizedSpeech = false
    private var accumulatedSilence: Duration = .zero

    init(
        silenceDuration: Duration = .seconds(1.5),
        activityThreshold: Float = 0.08,
        onEndOfSpeech: @escaping () -> Void
    ) {
        self.silenceDuration = silenceDuration
        self.activityThreshold = activityThreshold
        self.onEndOfSpeech = onEndOfSpeech
    }

    func receiveTranscript(_ update: VoiceRecognitionUpdate) {
        if update.isFinal {
            reset()
            return
        }

        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { return }
        hasRecognizedSpeech = true
        accumulatedSilence = .zero
    }

    func receiveLevel(_ level: Float, duration: Duration) {
        guard hasRecognizedSpeech, duration > .zero else { return }
        if level >= activityThreshold {
            accumulatedSilence = .zero
            return
        }

        accumulatedSilence += duration
        guard accumulatedSilence >= silenceDuration else { return }
        hasRecognizedSpeech = false
        accumulatedSilence = .zero
        onEndOfSpeech()
    }

    func reset() {
        hasRecognizedSpeech = false
        accumulatedSilence = .zero
    }
}

/// Serializes audio appends with recognition finalization so a tap callback
/// can never append another buffer after `endAudio()`.
private final class VoiceAudioBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        to request: SFSpeechAudioBufferRecognitionRequest
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        request.append(buffer)
        return true
    }
}

@MainActor
protocol VoiceInputLevelSource: AnyObject {
    var onLevel: ((Float, UInt64) -> Void)? { get set }
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)? { get set }
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)? { get set }

    var endsAfterSilence: Bool { get set }
    func start(generation: UInt64) async throws
    func stop()
}

extension VoiceInputLevelSource {
    var endsAfterSilence: Bool {
        get { true }
        set { }
    }
}

@MainActor
final class SilentVoiceInputLevelSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?

    func start(generation: UInt64) async throws {}

    func stop() {}
}

/// The production microphone seam. It owns its tap and reports levels on the
/// main actor; the voice model owns generation checks and lifecycle policy.
@MainActor
final class AVAudioEngineVoiceInputLevelSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?

    private let audioSession: AVAudioSession
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    nonisolated(unsafe) private let audioEngine: AVAudioEngine
    nonisolated(unsafe) private let teardownHook: (() -> Void)?
    nonisolated(unsafe) private var tapInstalled = false
    nonisolated(unsafe) private var recognitionTask: SFSpeechRecognitionTask?
    nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var sessionClaim: VoiceAudioSessionClaim?
    private var activeGeneration: UInt64 = 0
    private var isFinishingRecognition = false
    var endsAfterSilence = true
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated private let audioBufferGate = VoiceAudioBufferGate()
    private lazy var endOfSpeechDetector = VoiceEndOfSpeechDetector { [weak self] in
        self?.finishRecognitionAfterSilence()
    }

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        audioEngine: AVAudioEngine = AVAudioEngine(),
        sessionCoordinator: VoiceAudioSessionCoordinator = .shared,
        teardownHook: (() -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.sessionCoordinator = sessionCoordinator
        self.teardownHook = teardownHook
    }

    func start(generation: UInt64) async throws {
        guard !audioEngine.isRunning, !tapInstalled else { return }
        activeGeneration = generation
        isFinishingRecognition = false
        endOfSpeechDetector.reset()

        let permissionGranted = Self.hasMicrophoneAuthorization
        guard activeGeneration == generation else {
            throw VoiceInputLevelError.interrupted
        }
        guard permissionGranted else {
            stop()
            throw VoiceInputLevelError.permissionDenied
        }
        guard Self.hasSpeechAuthorization else {
            stop()
            throw VoiceInputLevelError.speechPermissionDenied
        }
        guard activeGeneration == generation else {
            throw VoiceInputLevelError.interrupted
        }

        do {
            sessionClaim = try sessionCoordinator.acquire()

            let inputNode = audioEngine.inputNode
            let format = inputNode.inputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                throw VoiceInputLevelError.noInputAvailable
            }

            guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
                  recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition
            else { throw VoiceInputLevelError.speechUnavailable }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            recognitionRequest = request

            let callbackGeneration = generation
            let tapCallback = Self.makeTapCallback(
                recognitionRequest: request,
                generation: callbackGeneration,
                source: self
            )
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tapCallback)
            tapInstalled = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let update = VoiceRecognitionUpdate(
                        text: result.bestTranscription.formattedString,
                        isFinal: result.isFinal
                    )
                    Task { @MainActor [weak self] in
                        guard let self, self.activeGeneration == callbackGeneration else { return }
                        self.receiveTranscript(update, generation: callbackGeneration)
                    }
                } else if error != nil {
                    Task { @MainActor [weak self] in
                        guard let self, self.activeGeneration == callbackGeneration else { return }
                        let callback = self.onUnavailable
                        self.stop()
                        callback?(.speechUnavailable, callbackGeneration)
                    }
                }
            }
            audioBufferGate.open()
            audioEngine.prepare()
            try audioEngine.start()
            installInterruptionObserver()
        } catch let error as VoiceInputLevelError {
            stop()
            throw error
        } catch {
            stop()
            throw VoiceInputLevelError.engineFailed
        }
    }

    func stop() {
        activeGeneration &+= 1
        endOfSpeechDetector.reset()
        teardownResources()
        onLevel = nil
        onTranscript = nil
        onUnavailable = nil
    }

    deinit {
        teardownResources()
        teardownHook?()
    }

    nonisolated private func teardownResources() {
        audioBufferGate.close()
        removeInterruptionObserver()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        sessionClaim?.release()
        sessionClaim = nil
    }

    nonisolated private static var hasMicrophoneAuthorization: Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied, .undetermined:
            false
        @unknown default:
            false
        }
    }

    nonisolated private static var hasSpeechAuthorization: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined, .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        let observerGeneration = activeGeneration
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            guard
                let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                type == .began
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGeneration == observerGeneration else { return }
                let callback = self.onUnavailable
                self.stop()
                callback?(.interrupted, observerGeneration)
            }
        }
    }

    nonisolated private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    nonisolated static func makeTapCallback(
        recognitionRequest: SFSpeechAudioBufferRecognitionRequest,
        generation: UInt64,
        source: AVAudioEngineVoiceInputLevelSource
    ) -> AVAudioNodeTapBlock {
        { [weak source] buffer, _ in
            guard let source, source.audioBufferGate.append(buffer, to: recognitionRequest) else { return }
            let level = rmsLevel(buffer)
            let duration = bufferDuration(buffer)
            Task { @MainActor [weak source] in
                source?.receiveLevel(level, duration: duration, generation: generation)
            }
        }
    }

    private func receiveLevel(_ level: Float, duration: Duration, generation: UInt64) {
        onLevel?(level, generation)
        guard activeGeneration == generation, !isFinishingRecognition, endsAfterSilence else { return }
        endOfSpeechDetector.receiveLevel(level, duration: duration)
    }

    private func receiveTranscript(_ update: VoiceRecognitionUpdate, generation: UInt64) {
        guard activeGeneration == generation else { return }
        endOfSpeechDetector.receiveTranscript(update)
        onTranscript?(update, generation)
    }

    private func finishRecognitionAfterSilence() {
        guard
            !isFinishingRecognition,
            let recognitionRequest,
            let recognitionTask
        else { return }

        isFinishingRecognition = true
        audioBufferGate.close()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        recognitionRequest.endAudio()
        recognitionTask.finish()
    }

    nonisolated private static func bufferDuration(_ buffer: AVAudioPCMBuffer) -> Duration {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return .zero }
        return .seconds(Double(buffer.frameLength) / sampleRate)
    }

    nonisolated private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard
            let channelData = buffer.floatChannelData,
            buffer.format.channelCount > 0
        else { return 0 }

        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<sampleCount {
            let sample = samples[index]
            sum += sample * sample
        }
        return min(max(sqrt(sum / Float(sampleCount)) * 3.2, 0), 1)
    }
}
