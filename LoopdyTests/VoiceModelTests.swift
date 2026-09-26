import SwiftUI
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct VoiceModelTests {
    @Test func liveVoicePreferencesPersistModeProviderAndEachProvidersVoice() {
        let suite = "loopdy.voice-preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        #expect(settings.voiceConversationMode == .codexLive)
        #expect(settings.liveVoiceProvider == .codexSubscription)
        #expect(settings.liveVoice(for: .codexSubscription) == "cove")
        #expect(settings.liveVoice(for: .apiKey) == "marin")

        settings.voiceConversationMode = .turnBased
        settings.liveVoiceProvider = .apiKey
        settings.setLiveVoice("bossa", for: .apiKey)
        settings.setLiveVoice("maple", for: .codexSubscription)

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.voiceConversationMode == .turnBased)
        #expect(restored.liveVoiceProvider == .apiKey)
        #expect(restored.liveVoice(for: .apiKey) == "bossa")
        #expect(restored.liveVoice(for: .codexSubscription) == "maple")
    }

    @Test func liveVoiceModelStartsWithTheSettingsOwnedProviderAndVoice() {
        let owner = LiveVoiceOwner(
            hostID: "fixture-host",
            authorizationID: "fixture-authorization",
            agentID: "default",
            sessionID: "fixture-session"
        )
        let client = LiveVoiceControlClient(
            owner: owner,
            operation: { _, _ in throw LiveVoiceControlError.unavailable },
            isOwnerCurrent: { $0 == owner }
        )

        let model = LiveVoiceModel(
            agentName: "Fixture",
            provider: .apiKey,
            voice: "bossa",
            client: client
        )

        #expect(model.provider == .apiKey)
        #expect(model.voice == "bossa")
    }

    @Test func voiceModeUsesFloatingHeroSurfacesAndCompactControls() {
        #expect(!VoiceViewPresentation.statusUsesFullWidthSurface)
        #expect(VoiceViewPresentation.statusVerticalPadding == 8)
        #expect(VoiceViewPresentation.controlMinimumHeight == 64)
    }

    @Test func longTranscriptScrollsWithoutMovingBottomControls() async throws {
        let rows = (0..<24).map { index in
            VoiceTranscriptRow(
                id: "voice-layout-row-\(index)",
                speaker: index.isMultiple(of: 2) ? "You" : "Avery",
                time: "9:\(String(format: "%02d", index)) AM",
                text: "This is a production-shaped voice transcript row with enough content to wrap across multiple lines on an iPhone-sized screen."
            )
        }
        let model = VoiceModel(
            conversationID: "voice-layout-session",
            client: VoiceFixtureClient(confirmationDelay: .zero),
            inputLevelSource: ControlledVoiceInputLevelSource()
        )
        let controller = UIHostingController(rootView: VoiceView(
            model: model,
            transcriptRows: rows,
            showsTranscript: true
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()

        let transcript = try #require(controller.view.descendants(of: UIScrollView.self).first)
        let before = transcript.convert(transcript.bounds, to: window)

        #expect(transcript.contentSize.height > transcript.bounds.height)
        #expect(before.maxY <= window.bounds.maxY - VoiceViewPresentation.controlMinimumHeight)

        transcript.setContentOffset(
            CGPoint(
                x: 0,
                y: transcript.contentSize.height - transcript.bounds.height
            ),
            animated: false
        )
        transcript.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let after = transcript.convert(transcript.bounds, to: window)
        #expect(transcript.contentOffset.y > 0)
        #expect(abs(before.minY - after.minY) <= 1)
        #expect(abs(before.maxY - after.maxY) <= 1)
    }

    @Test func accessibilityTranscriptRemainsScrollableAboveBottomControlsInLandscape() async throws {
        let rows = (0..<24).map { index in
            VoiceTranscriptRow(
                id: "voice-accessibility-row-\(index)",
                speaker: index.isMultiple(of: 2) ? "You" : "Avery",
                time: "Now",
                text: "A wrapping transcript row that must remain reachable in a compact landscape voice layout."
            )
        }
        let model = VoiceModel(
            conversationID: "voice-accessibility-session",
            client: VoiceFixtureClient(confirmationDelay: .zero),
            inputLevelSource: ControlledVoiceInputLevelSource()
        )
        let controller = UIHostingController(rootView: VoiceView(
            model: model,
            transcriptRows: rows
        ).environment(\.dynamicTypeSize, .accessibility3))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()

        let transcript = try #require(controller.view.descendants(of: UIScrollView.self).first)
        let transcriptFrame = transcript.convert(transcript.bounds, to: window)

        #expect(transcript.bounds.height >= VoiceViewPresentation.transcriptMinimumHeight)
        #expect(transcript.contentSize.height > transcript.bounds.height)
        #expect(transcriptFrame.maxY <= window.bounds.maxY - VoiceViewPresentation.controlMinimumHeight)
    }

    @Test func audioAndMicrophoneMuteIndependently() {
        let model = VoiceModel(conversationID: "demo", client: VoiceFixtureClient())

        model.toggleAgentAudio()

        #expect(model.isAgentAudioMuted)
        #expect(!model.isMicrophoneMuted)

        model.toggleMicrophone()

        #expect(model.isAgentAudioMuted)
        #expect(model.isMicrophoneMuted)
    }

    @Test func endingPreservesConversationIdentity() async {
        let model = VoiceModel(conversationID: "demo-finance", client: VoiceFixtureClient())

        await model.end()

        #expect(!model.isActive)
        #expect(model.conversationID == "demo-finance")
    }

    @Test func pendingEndBlocksDuplicateRequests() async {
        let client = ControlledVoiceSessionClient()
        let model = VoiceModel(conversationID: "demo", client: client)

        let firstEnd = Task { await model.end() }
        await client.waitUntilRequested()

        #expect(model.isEndPending)
        #expect(model.isActive)

        let duplicateResult = await model.end()
        #expect(!duplicateResult)

        client.succeed()
        let firstResult = await firstEnd.value

        #expect(firstResult)
        #expect(client.endRequestCount == 1)
        #expect(!model.isActive)
    }

    @Test func failedEndRemainsActiveAndCanRetry() async {
        let client = SequenceVoiceSessionClient(results: [
            .failure(.unavailable),
            .success(())
        ])
        let model = VoiceModel(conversationID: "demo", client: client)

        let failedResult = await model.end()

        #expect(!failedResult)
        #expect(model.isActive)
        #expect(!model.isEndPending)
        #expect(model.endErrorMessage == "Voice chat could not end. Try again.")

        let retryResult = await model.end()

        #expect(retryResult)
        #expect(!model.isActive)
        #expect(model.endErrorMessage == nil)
    }

    @Test func monitoringStartsOnlyForListeningAndIgnoresStaleLevelsAfterStop() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        #expect(source.startCount == 1)
        #expect(model.meterState == .monitoring)

        source.emit(1, generation: source.latestGeneration)
        #expect(model.inputLevel > 0)

        model.stopMonitoring()
        let levelAfterStop = model.inputLevel
        source.emit(1, generation: source.latestGeneration)
        #expect(source.stopCount == 1)
        #expect(model.inputLevel == levelAfterStop)
        #expect(model.meterState == .idle)
    }

    @Test func nonActiveWorkingPresentationDoesNotStartMicrophoneMetering() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            status: .working,
            isAgentRunActive: false,
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()

        #expect(source.startCount == 0)
        #expect(model.meterState == .idle)
    }

    @Test func muteStopsMonitoringAndUnmuteRestartsIt() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        model.toggleMicrophone()
        #expect(model.isMicrophoneMuted)
        #expect(source.stopCount == 1)
        #expect(model.meterState == .idle)

        model.toggleMicrophone()
        for _ in 0..<4 {
            await Task.yield()
        }
        #expect(source.startCount == 1)
        #expect(model.meterState == .idle)

        await model.startMonitoring()
        #expect(!model.isMicrophoneMuted)
        #expect(source.startCount == 2)
        #expect(model.meterState == .monitoring)
    }

    @Test func unmuteDoesNotRestartMeterWithoutActiveSceneReconciliation() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        model.toggleMicrophone()
        model.toggleMicrophone()
        for _ in 0..<4 {
            await Task.yield()
        }

        #expect(source.startCount == 1)
        #expect(model.meterState == .idle)
    }

    @Test func statusToListeningDoesNotRestartMeterWithoutActiveSceneReconciliation() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        model.selectStatus(.working)
        model.selectStatus(.listening)
        for _ in 0..<4 {
            await Task.yield()
        }

        #expect(source.startCount == 1)
        #expect(model.meterState == .idle)
    }

    @Test func reduceMotionSuppressesOrbAmplitudeWithoutStoppingSpeechRecognition() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        let firstGeneration = source.latestGeneration
        source.emit(1, generation: firstGeneration)
        #expect(model.inputLevel > 0)

        model.setReduceMotion(true)
        #expect(model.isReduceMotionEnabled)
        #expect(model.meterState == .monitoring)
        #expect(model.inputLevel == 0)
        #expect(source.stopCount == 0)

        source.emit(1, generation: firstGeneration)
        #expect(model.inputLevel == 0)

        model.setReduceMotion(false)
        source.emit(1, generation: firstGeneration)
        #expect(source.startCount == 1)
        #expect(!model.isReduceMotionEnabled)
        #expect(model.meterState == .monitoring)
        #expect(model.inputLevel > 0)
    }

    @Test func changingReduceMotionDoesNotReinstallTheMicrophoneTap() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        model.setReduceMotion(true)
        model.setReduceMotion(false)

        #expect(source.startCount == 1)
        #expect(source.stopCount == 0)
        #expect(model.meterState == .monitoring)
    }

    @Test func duplicateStartWhileMonitoringDoesNotInstallAnotherTap() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        await model.startMonitoring()

        #expect(source.startCount == 1)
        #expect(model.meterState == .monitoring)
    }

    @Test func stalePermissionCompletionCannotStopNewGeneration() async {
        let source = DeferredVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        let firstStart = Task { await model.startMonitoring() }
        await source.waitUntilStarted(count: 1)
        let firstGeneration = source.generations[0]

        model.stopMonitoring()
        let secondStart = Task { await model.startMonitoring() }
        await source.waitUntilStarted(count: 2)
        let secondGeneration = source.generations[1]

        source.complete(
            generation: firstGeneration,
            result: .failure(VoiceInputLevelError.engineFailed)
        )
        await firstStart.value
        #expect(source.stopCount == 1)

        source.complete(generation: secondGeneration, result: .success(()))
        await secondStart.value
        #expect(model.meterState == .monitoring)
    }

    @Test func interruptionPublishesUnavailableOnceAndRejectsStaleInterruption() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()
        let firstGeneration = source.latestGeneration
        source.emitUnavailable(.interrupted, generation: firstGeneration)

        #expect(model.meterState == .unavailable)
        #expect(source.stopCount == 1)

        model.setReduceMotion(false)
        await model.startMonitoring()
        let secondGeneration = source.latestGeneration
        source.emitUnavailable(.interrupted, generation: firstGeneration)

        #expect(secondGeneration != firstGeneration)
        #expect(model.meterState == .monitoring)
        #expect(source.stopCount == 1)
    }

    @Test func audioSourceDeinitRunsTeardownHookExactlyOnce() {
        var teardownCount = 0
        do {
            let source = AVAudioEngineVoiceInputLevelSource {
                teardownCount += 1
            }
            source.stop()
            source.stop()
        }

        #expect(teardownCount == 1)
    }

    @Test func denialPublishesUnavailableWithoutCrashing() async {
        let source = ControlledVoiceInputLevelSource(startError: .permissionDenied)
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(),
            inputLevelSource: source
        )

        await model.startMonitoring()

        #expect(model.meterState == .unavailable)
        #expect(model.inputLevel == 0)
        #expect(model.status == .listening)
    }

    @Test func walkieTalkieCanCaptureSteeringWhileAgentIsWorking() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "active-walkie", status: .working, mode: .walkieTalkie,
            client: CapturingVoiceSessionClient(), inputLevelSource: source
        )
        let began = await model.beginWalkieTalkieCapture()
        #expect(began)
        #expect(source.startCount == 1)
        _ = model.endWalkieTalkieCapture(submit: false)
        #expect(!model.isWalkieTalkieCapturing)
        #expect(model.meterState == .idle)
    }

    @Test func staleWalkieStartCannotStopANewerHeldCapture() async {
        let source = DeferredVoiceInputLevelSource()
        let model = VoiceModel(conversationID: "held-race", mode: .walkieTalkie,
                               client: CapturingVoiceSessionClient(), inputLevelSource: source)
        let first = Task { await model.beginWalkieTalkieCapture() }
        await source.waitUntilStarted(count: 1)
        _ = model.endWalkieTalkieCapture(submit: false)
        let second = Task { await model.beginWalkieTalkieCapture() }
        await source.waitUntilStarted(count: 2)
        source.complete(generation: source.generations[1], result: .success(()))
        #expect(await second.value)
        let stopCount = source.stopCount
        source.complete(generation: source.generations[0], result: .success(()))
        #expect(!(await first.value))
        #expect(source.stopCount == stopCount)
        #expect(model.isWalkieTalkieCapturing)
        #expect(model.meterState == .monitoring)
        _ = model.endWalkieTalkieCapture(submit: false)
    }

    @Test func walkieTalkieRecordsOnlyWhileHeldAndSubmitsOnRelease() async {
        let source = ControlledVoiceInputLevelSource()
        let client = CapturingVoiceSessionClient()
        let model = VoiceModel(
            conversationID: "walkie",
            mode: .walkieTalkie,
            client: client,
            inputLevelSource: source
        )

        await model.startMonitoring()
        #expect(source.startCount == 0)
        #expect(await model.beginWalkieTalkieCapture())
        #expect(!source.endsAfterSilence)
        let generation = source.latestGeneration
        source.emitTranscript("Hold to speak", isFinal: false, generation: generation)
        source.emitTranscript("Hold to speak now", isFinal: true, generation: generation)
        #expect(client.transcripts.isEmpty)

        #expect(model.endWalkieTalkieCapture(submit: true))
        await model.waitUntilTurnSettles()
        #expect(client.transcripts == ["Hold to speak now"])
        #expect(!model.isWalkieTalkieCapturing)
    }

    @Test func cancellingWalkieTalkieCaptureDiscardsWordsAndStaleCallbacks() async {
        let source = ControlledVoiceInputLevelSource()
        let client = CapturingVoiceSessionClient()
        let model = VoiceModel(
            conversationID: "walkie-cancel",
            mode: .walkieTalkie,
            client: client,
            inputLevelSource: source
        )

        #expect(await model.beginWalkieTalkieCapture())
        let generation = source.latestGeneration
        source.emitTranscript("Do not send", isFinal: false, generation: generation)
        #expect(!model.endWalkieTalkieCapture(submit: false))
        source.emitTranscript("Still do not send", isFinal: true, generation: generation)
        await Task.yield()

        #expect(client.transcripts.isEmpty)
        #expect(model.partialUserTranscript == nil)
        #expect(!model.isWalkieTalkieCapturing)
    }

    @Test func endingStopsMonitoringAndRejectsLaterCallbacks() async {
        let source = ControlledVoiceInputLevelSource()
        let model = VoiceModel(
            conversationID: "demo",
            client: VoiceFixtureClient(confirmationDelay: .zero),
            inputLevelSource: source
        )

        await model.startMonitoring()
        source.emit(0.8, generation: source.latestGeneration)
        let generation = source.latestGeneration
        #expect(await model.end())
        #expect(source.stopCount == 1)

        let afterEnd = model.inputLevel
        source.emit(1, generation: generation)
        #expect(model.inputLevel == afterEnd)
        #expect(model.meterState == .idle)
    }
}

private extension UIView {
    func descendants<View: UIView>(of type: View.Type) -> [View] {
        var matches = subviews.flatMap { $0.descendants(of: type) }
        if let view = self as? View {
            matches.insert(view, at: 0)
        }
        return matches
    }
}

@MainActor
private final class ControlledVoiceSessionClient: VoiceSessionClient {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var endRequestCount = 0

    func endSession(conversationID: String) async throws {
        endRequestCount += 1
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while endRequestCount == 0 {
            await Task.yield()
        }
    }

    func succeed() {
        continuation?.resume(returning: ())
        continuation = nil
    }
}

@MainActor
private final class SequenceVoiceSessionClient: VoiceSessionClient {
    enum Failure: Error {
        case unavailable
    }

    private var results: [Result<Void, Failure>]

    init(results: [Result<Void, Failure>]) {
        self.results = results
    }

    func endSession(conversationID: String) async throws {
        guard !results.isEmpty else { throw Failure.unavailable }
        try results.removeFirst().get()
    }
}

@MainActor
private final class ControlledVoiceInputLevelSource: VoiceInputLevelSource {
    enum StartError: Error {
        case permissionDenied
    }

    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var latestGeneration: UInt64 = 0
    var endsAfterSilence = true
    private let startError: StartError?

    init(startError: StartError? = nil) {
        self.startError = startError
    }

    func start(generation: UInt64) async throws {
        startCount += 1
        latestGeneration = generation
        if let startError { throw startError }
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ level: Float, generation: UInt64) {
        onLevel?(level, generation)
    }

    func emitTranscript(_ text: String, isFinal: Bool, generation: UInt64) {
        onTranscript?(VoiceRecognitionUpdate(text: text, isFinal: isFinal), generation)
    }

    func emitUnavailable(_ error: VoiceInputLevelError, generation: UInt64) {
        onUnavailable?(error, generation)
    }
}

@MainActor
private final class CapturingVoiceSessionClient: VoiceSessionClient {
    private(set) var transcripts: [String] = []

    func respond(
        to transcript: String,
        conversationID _: String,
        onDraft _: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        transcripts.append(transcript)
        return VoiceAgentReply(speaker: "Loopdy", text: "Received.", timelineItems: [])
    }

    func speak(_ text: String) async throws {}

    func endSession(conversationID _: String) async throws {}
}

@MainActor
private final class DeferredVoiceInputLevelSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    private(set) var generations: [UInt64] = []
    private(set) var stopCount = 0
    private var continuations: [UInt64: CheckedContinuation<Void, Error>] = [:]

    func start(generation: UInt64) async throws {
        generations.append(generation)
        try await withCheckedThrowingContinuation { continuation in
            continuations[generation] = continuation
        }
    }

    func stop() {
        stopCount += 1
    }

    func complete(generation: UInt64, result: Result<Void, Error>) {
        guard let continuation = continuations.removeValue(forKey: generation) else { return }
        continuation.resume(with: result)
    }

    func waitUntilStarted(count: Int) async {
        while generations.count < count {
            await Task.yield()
        }
    }
}
