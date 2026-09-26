import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyRealtimeAudioPeerTests {
    @Test func routeRecoveryRestoresCaptureOnlyWithValidInputAndPreservesMute() {
        var state = LoopdyAudioRecoveryState()
        state.routeLost()
        #expect(state.isInterrupted)
        let invalidRouteRestore = state.routeBecameAvailable(hasValidInputRoute: false)
        #expect(!invalidRouteRestore)
        #expect(state.isInterrupted)
        let validRouteRestore = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(validRouteRestore)
        #expect(!state.isInterrupted)
        #expect(state.shouldEnableCapture)

        state.setMuted(true)
        state.routeLost()
        let mutedRouteRestore = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(mutedRouteRestore)
        #expect(!state.isInterrupted)
        #expect(state.isMuted)
        #expect(!state.shouldEnableCapture)
    }

    @Test func routeLossWithAlreadyValidReplacementRestoresInOneCallback() {
        var state = LoopdyAudioRecoveryState()
        state.routeLost()
        let restored = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(restored)
        #expect(!state.isInterrupted)
    }

    @Test func interruptionRecoveryRequiresSystemResumeAndValidInput() {
        var state = LoopdyAudioRecoveryState()
        state.beginInterruption()
        let declinedResume = state.endInterruption(shouldResume: false, hasValidInputRoute: true)
        #expect(!declinedResume)
        #expect(state.isInterrupted)
        let routeAfterDeclinedResume = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(!routeAfterDeclinedResume)
        #expect(state.isInterrupted)
        let explicitResume = state.explicitResume(hasValidInputRoute: true)
        #expect(explicitResume)
        #expect(!state.isInterrupted)

        state.beginInterruption()
        let missingRouteResume = state.endInterruption(shouldResume: true, hasValidInputRoute: false)
        #expect(!missingRouteResume)
        #expect(state.isInterrupted)
        let resumedAfterRoute = state.endInterruption(shouldResume: true, hasValidInputRoute: true)
        #expect(resumedAfterRoute)
        #expect(!state.isInterrupted)
    }

    @Test func optionalAPIUsesItsOwnVoiceContract() {
        #expect(LiveVoiceProvider.codexSubscription.defaultVoice == "cove")
        #expect(LiveVoiceProvider.apiKey.defaultVoice == "marin")
        #expect(!LiveVoiceProvider.apiKey.voices.contains("cove"))
    }

    @Test func speakerPolicyAvoidsDuplicateOverrideAndRespectsExternalRoute() {
        #expect(LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: false, currentBuiltInSpeaker: false))
        #expect(!LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: false, currentBuiltInSpeaker: true))
        #expect(!LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: false))
        #expect(LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .forceSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: false))
        #expect(!LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .forceSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: true))
        #expect(!LoopdyRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .systemRoute, hasExternalRoute: false, currentBuiltInSpeaker: false))
    }

    @Test func nativeOfferIsAudioOnlyWithoutAProviderDataChannel() async throws {
        let peer = LoopdyRealtimeAudioPeer(captureEnabled: false)
        defer { peer.close() }
        let offer = try await peer.makeOffer()
        #expect(offer.contains("m=audio "))
        #expect(!offer.contains("m=video "))
        #expect(!offer.contains("m=application "))
        #expect(offer.contains("a=fingerprint:"))
        #expect(offer.contains("a=ice-ufrag:"))
        if let endpoint = ProcessInfo.processInfo.environment["LOOPDY_SUBSCRIPTION_PROBE"],
           let url = URL(string: endpoint) {
            #expect(url.host == "127.0.0.1")
            var request = URLRequest(url: url.appending(path: "offer"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": offer])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 55
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                Issue.record("Subscription call refused: \(result?["error"] as? String ?? "unknown")")
                return
            }
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let answer = try #require(object["sdp"] as? String)
            try await peer.applyAnswer(answer)
            if ProcessInfo.processInfo.environment["LOOPDY_EXPECT_AUDIO"] == "1" {
                var speak = URLRequest(url: url.appending(path: "speak"))
                speak.httpMethod = "POST"; speak.httpBody = Data("{}".utf8)
                _ = try await URLSession.shared.data(for: speak)
                var received = false
                for _ in 0..<15 {
                    try await Task.sleep(for: .seconds(1))
                    let stats = try await peer.statistics()
                    if stats.hasInboundMedia { received = true; break }
                }
                #expect(received, "Actual subscription audio must reach the native peer")
            } else {
                try await Task.sleep(for: .seconds(3))
            }
            var close = URLRequest(url: url.appending(path: "close"))
            close.httpMethod = "POST"
            close.httpBody = Data("{}".utf8)
            _ = try await URLSession.shared.data(for: close)
        }
    }
}
